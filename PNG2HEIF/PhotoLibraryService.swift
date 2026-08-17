import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit
import Combine

// MARK: - Export Mode

enum ExportMode: Int, CaseIterable, Identifiable {
    case library = 0
    case album = 1
    case newAlbum = 2
    case folder = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .library:  return "照片图库"
        case .album:    return "指定相簿"
        case .newAlbum: return "新建相簿"
        case .folder:   return "文件夹"
        }
    }

    var icon: String {
        switch self {
        case .library:  return "photo.on.rectangle.angled"
        case .album:    return "rectangle.stack"
        case .newAlbum: return "rectangle.stack.badge.plus"
        case .folder:   return "folder"
        }
    }
}

// MARK: - Album Model

struct AlbumItem: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    var assetCollection: PHAssetCollection?

    init(_ collection: PHAssetCollection) {
        self.id = collection.localIdentifier
        self.title = collection.localizedTitle ?? "未命名相簿"
        self.count = collection.estimatedAssetCount
        self.assetCollection = collection
    }
}

// MARK: - Failure Record

struct FailedItem: Identifiable {
    let id = UUID()
    let assetLocalID: String
    let fileName: String
    let error: String
    let timestamp: Date
}

// MARK: - Conversion Database

/// 简易文件持久化数据库，记录已转换的 asset localIdentifier。
/// 存储在 app sandbox Documents/png2heif_db.json 中。
final class ConversionDB {
    static let shared = ConversionDB()

    private let fileURL: URL
    private var convertedIDs: Set<String> = []
    private let queue = DispatchQueue(label: "png2heif.db", qos: .utility)

    private init() {
        let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.png2heif"
        ) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("png2heif_converted.json")
        self.load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let ids = try? JSONDecoder().decode([String].self, from: data) {
            convertedIDs = Set(ids)
        }
    }

    private func save() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let ids = Array(self.convertedIDs)
            if let data = try? JSONEncoder().encode(ids) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    func contains(_ assetLocalID: String) -> Bool {
        return convertedIDs.contains(assetLocalID)
    }

    func insert(_ assetLocalID: String) {
        convertedIDs.insert(assetLocalID)
        save()
    }

    func remove(_ assetLocalID: String) {
        convertedIDs.remove(assetLocalID)
        save()
    }

    func count() -> Int {
        return convertedIDs.count
    }

    func clearAll() {
        convertedIDs.removeAll()
        save()
    }
}

// MARK: - PhotoLibraryService

final class PhotoLibraryService: ObservableObject {
    // MARK: - Published State

    @Published var pngCount = 0
    @Published var totalSizeSaved: Int64 = 0  // 实时累计节省空间
    @Published var processed = 0
    @Published var total = 0
    @Published var skippedCount = 0
    @Published var progress: Double = 0
    @Published var status = "等待扫描"
    @Published var isWorking = false
    @Published var isScanning = false
    @Published var deleteOriginals = true
    @Published var compressionQuality: Float = 0.82
    @Published var alert: AlertItem?

    // 导出位置
    @Published var exportMode: ExportMode = .library
    @Published var userAlbums: [AlbumItem] = []
    @Published var selectedAlbumID: String?
    @Published var newAlbumName: String = "HEIF截图"
    @Published var exportFolderURL: URL?
    @Published var exportFolderName: String?

    // 失败列表
    @Published var failedItems: [FailedItem] = []
    @Published var showFailedList = false

    // 已转换记录数
    @Published var historyCount = 0

    // MARK: - Private

    private var assets: [PHAsset] = []
    private var shouldStop = false
    private let workerQueue = DispatchQueue(label: "PNG2HEIF.worker", qos: .userInitiated)

    // MARK: - Computed

    var savedSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalSizeSaved, countStyle: .file)
    }

    var selectedAlbumTitle: String? {
        guard let id = selectedAlbumID else { return nil }
        return userAlbums.first(where: { $0.id == id })?.title
    }

    // MARK: - Album Management

    func loadAlbums() {
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var albums: [AlbumItem] = []
        fetch.enumerateObjects { collection, _, _ in
            albums.append(AlbumItem(collection))
        }
        albums.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in
            self?.userAlbums = albums
        }
    }

    // MARK: - Authorization & Scan

    func requestAuthorizationAndScan() {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                DispatchQueue.main.async {
                    guard status == .authorized || status == .limited else {
                        self?.status = "没有照片图库访问权限"
                        return
                    }
                    self?.scan()
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard status == .authorized else {
                        self?.status = "没有照片图库访问权限"
                        return
                    }
                    self?.scan()
                }
            }
        }
    }

    /// 轻量扫描：只找 PNG，不做预估转换，极快完成
    func scan() {
        guard !isWorking else { return }
        isScanning = true
        status = "扫描中…"

        workerQueue.async { [weak self] in
            guard let self = self else { return }

            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: true)
            ]
            let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)

            var found: [PHAsset] = []
            var skipped = 0
            let db = ConversionDB.shared

            result.enumerateObjects { asset, _, _ in
                guard self.isPNG(asset: asset) else { return }
                // 跳过已转换的
                if db.contains(asset.localIdentifier) {
                    skipped += 1
                    return
                }
                found.append(asset)
            }

            self.loadAlbums()

            DispatchQueue.main.async {
                self.assets = found
                self.pngCount = found.count
                self.skippedCount = skipped
                self.total = found.count
                self.processed = 0
                self.progress = 0
                self.totalSizeSaved = 0
                self.historyCount = db.count()
                self.failedItems = []
                self.isScanning = false
                if skipped > 0 {
                    self.status = "找到 \(found.count) 张待转换 PNG（已跳过 \(skipped) 张已转换）"
                } else {
                    self.status = "找到 \(found.count) 张 PNG 截图"
                }
            }
        }
    }

    // MARK: - Conversion Control

    func startConversion() {
        guard !isWorking, !assets.isEmpty else { return }

        if exportMode == .folder, exportFolderURL == nil {
            status = "请先选择导出文件夹"
            return
        }
        if exportMode == .album, selectedAlbumID == nil {
            status = "请先选择一个相簿"
            return
        }
        if exportMode == .newAlbum, newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty {
            status = "请输入新相簿名称"
            return
        }

        let work = assets
        let mode = exportMode
        let albumID = selectedAlbumID
        let albumName = newAlbumName.trimmingCharacters(in: .whitespaces)
        let folderURL = exportFolderURL

        isWorking = true
        shouldStop = false
        processed = 0
        total = work.count
        progress = 0
        totalSizeSaved = 0
        failedItems = []
        status = "开始转换…"

        if mode == .folder {
            workerQueue.async { [weak self] in
                guard let self = self, let dir = folderURL else { return }
                self.convertToFolder(assets: work, dir: dir)
            }
        } else {
            workerQueue.async { [weak self] in
                guard let self = self else { return }
                self.resolveAlbum(mode: mode, albumID: albumID, albumName: albumName) { album in
                    if mode == .library {
                        self.runConversion(assets: work, album: nil)
                    } else if let album = album {
                        self.runConversion(assets: work, album: album)
                    } else {
                        self.finish(message: "无法创建或访问相簿")
                    }
                }
            }
        }
    }

    func stopConversion() {
        shouldStop = true
        DispatchQueue.main.async { [weak self] in
            self?.status = "正在停止…"
        }
    }

    // MARK: - Private: Resolve Album

    private func resolveAlbum(mode: ExportMode, albumID: String?, albumName: String,
                              completion: @escaping (PHAssetCollection?) -> Void) {
        switch mode {
        case .library:
            completion(nil)
            return
        case .album:
            if let id = albumID {
                let r = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [id], options: nil
                )
                completion(r.firstObject)
            } else {
                completion(nil)
            }
            return
        case .newAlbum:
            ensureAlbum(named: albumName, completion: completion)
            return
        case .folder:
            completion(nil)
            return
        }
    }

    // MARK: - Private: Run Conversion (Photos Mode)

    private func runConversion(assets work: [PHAsset], album: PHAssetCollection?) {
        var successCount = 0
        var failCount = 0
        var savedBytes: Int64 = 0
        var fails: [FailedItem] = []
        let db = ConversionDB.shared

        for asset in work {
            if shouldStop { break }

            autoreleasepool {
                let pngSize = self.estimatedPNGSize(asset: asset)
                let ok = self.convertOneToPhotos(asset: asset, album: album)
                if ok {
                    successCount += 1
                    savedBytes += pngSize
                    db.insert(asset.localIdentifier)
                } else {
                    failCount += 1
                    let resources = PHAssetResource.assetResources(for: asset)
                    let fileName = resources.first?.originalFilename ?? "未知"
                    fails.append(FailedItem(
                        assetLocalID: asset.localIdentifier,
                        fileName: fileName,
                        error: "转换或写入失败",
                        timestamp: Date()
                    ))
                }

                let currentProcessed = successCount + failCount
                let currentProgress = Double(currentProcessed) / Double(max(work.count, 1))

                DispatchQueue.main.async {
                    self.processed = currentProcessed
                    self.progress = currentProgress
                    self.totalSizeSaved = savedBytes
                    self.failedItems = fails
                    let pct = Int(currentProgress * 100)
                    self.status = "已转换 \(currentProcessed) / \(work.count)（\(pct)%）"
                }
            }
        }

        if shouldStop {
            let skipped = work.count - successCount - failCount
            finish(message: "已停止：成功 \(successCount) 张，失败 \(failCount) 张，跳过 \(skipped) 张")
        } else {
            let failMsg = failCount > 0 ? "，失败 \(failCount) 张" : ""
            finish(message: "完成：成功 \(successCount) 张\(failMsg)，共节省 \(ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file))")
        }
    }

    // MARK: - Private: Folder Export

    private func convertToFolder(assets work: [PHAsset], dir: URL) {
        var successCount = 0
        var failCount = 0
        var savedBytes: Int64 = 0
        var fails: [FailedItem] = []
        let db = ConversionDB.shared

        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        for asset in work {
            if shouldStop { break }

            autoreleasepool {
                let pngSize = self.estimatedPNGSize(asset: asset)
                let ok = self.convertOneToFolder(asset: asset, dir: dir)
                if ok {
                    successCount += 1
                    savedBytes += pngSize
                    db.insert(asset.localIdentifier)
                } else {
                    failCount += 1
                    let resources = PHAssetResource.assetResources(for: asset)
                    let fileName = resources.first?.originalFilename ?? "未知"
                    fails.append(FailedItem(
                        assetLocalID: asset.localIdentifier,
                        fileName: fileName,
                        error: "转换或写入文件失败",
                        timestamp: Date()
                    ))
                }

                let currentProcessed = successCount + failCount
                let currentProgress = Double(currentProcessed) / Double(max(work.count, 1))

                DispatchQueue.main.async {
                    self.processed = currentProcessed
                    self.progress = currentProgress
                    self.totalSizeSaved = savedBytes
                    self.failedItems = fails
                    let pct = Int(currentProgress * 100)
                    self.status = "已导出 \(currentProcessed) / \(work.count)（\(pct)%）"
                }
            }
        }

        if shouldStop {
            let skipped = work.count - successCount - failCount
            finish(message: "已停止：导出 \(successCount) 张，失败 \(failCount) 张，跳过 \(skipped) 张")
        } else {
            let failMsg = failCount > 0 ? "，失败 \(failCount) 张" : ""
            finish(message: "导出完成：成功 \(successCount) 张\(failMsg)，保存至 \(dir.lastPathComponent)")
        }
    }

    // MARK: - Private: Asset Inspection

    private func isPNG(asset: PHAsset) -> Bool {
        // 只处理 iOS 截图
        guard asset.mediaSubtypes.contains(.photoScreenshot) else { return false }
        // 确认是 PNG 格式
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.contains {
            let uti = $0.uniformTypeIdentifier.lowercased()
            let filename = $0.originalFilename.lowercased()
            return uti == "public.png" || uti.contains("png") || filename.hasSuffix(".png")
        }
    }

    private func estimatedPNGSize(asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        return Int64(resources.first?.value(forKey: "fileSize") as? Int64 ?? 0)
    }

    // MARK: - Private: Encode HEIF

    private func encodeHEIF(from asset: PHAsset) -> (url: URL?, pngSize: Int64) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            let uti = $0.uniformTypeIdentifier.lowercased()
            return uti == "public.png" || uti.contains("png") || $0.originalFilename.lowercased().hasSuffix(".png")
        }) else { return (nil, 0) }

        let pngSize = Int64(resource.value(forKey: "fileSize") as? Int64 ?? 0)

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".heic")

        let exportOpts = PHAssetResourceRequestOptions()
        exportOpts.isNetworkAccessAllowed = true

        let semaphore = DispatchSemaphore(value: 0)
        var encodeOK = false
        let quality = self.compressionQuality

        PHAssetResourceManager.default().writeData(for: resource, toFile: inputURL, options: exportOpts) { error in
            defer {
                try? FileManager.default.removeItem(at: inputURL)
            }
            if let error = error {
                print("[PNG2HEIF] writeData 失败: \(error.localizedDescription)")
                semaphore.signal()
                return
            }

            guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("[PNG2HEIF] 解码 PNG 失败")
                semaphore.signal()
                return
            }

            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.heic.identifier as CFString, 1, nil
            ) else {
                print("[PNG2HEIF] 创建 HEIC destination 失败")
                semaphore.signal()
                return
            }

            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, cgImage, props as CFDictionary)

            guard CGImageDestinationFinalize(destination) else {
                print("[PNG2HEIF] HEIC 编码失败")
                semaphore.signal()
                return
            }

            encodeOK = true
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 120)

        if encodeOK {
            return (outputURL, pngSize)
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            return (nil, 0)
        }
    }

    // MARK: - Private: Convert One → Photos

    private func convertOneToPhotos(asset: PHAsset, album: PHAssetCollection?) -> Bool {
        guard let heifURL = encodeHEIF(from: asset).url else { return false }

        defer {
            try? FileManager.default.removeItem(at: heifURL)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var convertSuccess = false

        let loc = asset.location
        let fav = asset.isFavorite
        let shouldDelete = self.deleteOriginals
        let heifData = try? Data(contentsOf: heifURL)

        guard let heifData = heifData else {
            print("[PNG2HEIF] 读取 HEIF Data 失败")
            return false
        }

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            if let loc = loc { req.location = loc }
            req.isFavorite = fav
            req.addResource(with: .photo, data: heifData, options: nil)

            if let album = album {
                let placeholder = req.placeholderForCreatedAsset
                if let placeholder = placeholder {
                    let albumChange = PHAssetCollectionChangeRequest(for: album)
                    albumChange?.addAssets([placeholder] as NSArray)
                }
            }
        }) { changed, error in
            if changed && error == nil {
                convertSuccess = true

                if shouldDelete {
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                    }) { deleted, _ in
                        convertSuccess = convertSuccess && deleted
                        semaphore.signal()
                    }
                } else {
                    semaphore.signal()
                }
            } else {
                if let error = error {
                    print("[PNG2HEIF] 导入照片库失败: \(error.localizedDescription)")
                }
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 120)
        return convertSuccess
    }

    // MARK: - Private: Convert One → Folder

    private func convertOneToFolder(asset: PHAsset, dir: URL) -> Bool {
        guard let heifURL = encodeHEIF(from: asset).url else { return false }

        defer {
            try? FileManager.default.removeItem(at: heifURL)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let originalName = resources.first?.originalFilename ?? ""
        let baseName = (originalName as NSString).deletingPathExtension
        let safeName = baseName.isEmpty ? UUID().uuidString : baseName
        let destURL = dir.appendingPathComponent(safeName + ".heic")
        let finalURL = FileManager.default.uniqueFileName(for: destURL)

        do {
            try FileManager.default.copyItem(at: heifURL, to: finalURL)
        } catch {
            print("[PNG2HEIF] 复制到文件夹失败: \(error.localizedDescription)")
            return false
        }

        if self.deleteOriginals {
            let semaphore = DispatchSemaphore(value: 0)
            var deleted = false
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }) { ok, _ in
                deleted = ok
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 30)
            return deleted
        }

        return true
    }

    // MARK: - Private: Album

    private func ensureAlbum(named name: String, completion: @escaping (PHAssetCollection?) -> Void) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", name)

        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        )

        if let found = fetch.firstObject {
            completion(found)
            return
        }

        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        }) { success, _ in
            guard success, let id = placeholder?.localIdentifier else {
                completion(nil)
                return
            }
            let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
            completion(result.firstObject)
        }
    }

    // MARK: - Private: Finish

    private func finish(message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let hasFailures = !self.failedItems.isEmpty
            self.isWorking = false
            self.shouldStop = false
            self.status = message
            self.historyCount = ConversionDB.shared.count()
            // 转换结束后重新扫描，刷新待转换列表
            self.scan()
            self.alert = AlertItem(title: hasFailures ? "转换完成（有失败）" : "转换完成", message: message)
        }
    }

    // MARK: - Clear History

    func clearHistory() {
        ConversionDB.shared.clearAll()
        historyCount = 0
        skippedCount = 0
        scan()
    }
}

// MARK: - Helpers

extension FileManager {
    func uniqueFileName(for url: URL) -> URL {
        if !fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let name = url.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let newName = "\(name) \(counter)"
            let newURL = url.deletingLastPathComponent().appendingPathComponent(newName).appendingPathExtension(ext)
            if !fileExists(atPath: newURL.path) { return newURL }
            counter += 1
        }
    }
}