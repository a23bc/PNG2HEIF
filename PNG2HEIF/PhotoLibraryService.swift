import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit
import Combine

// MARK: - Export Mode

enum ExportMode: Int, CaseIterable, Identifiable {
    case library = 0   // 直接存到照片图库（最近项目）
    case album = 1     // 存到已有相簿
    case newAlbum = 2  // 新建相簿并存入
    case folder = 3    // 导出到文件夹（Files）

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
    let id: String       // localIdentifier
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

// MARK: - PhotoLibraryService

final class PhotoLibraryService: ObservableObject {
    // MARK: - Published State

    @Published var pngCount = 0
    @Published var pngSize: Int64 = 0
    @Published var estimatedHEIFSize: Int64 = 0
    @Published var processed = 0
    @Published var total = 0
    @Published var progress: Double = 0
    @Published var status = "等待扫描"
    @Published var isWorking = false
    @Published var deleteOriginals = true
    @Published var onlyPNG = true
    @Published var keepCreationDate = true
    @Published var compressionQuality: Float = 0.82
    @Published var alert: AlertItem?

    // 导出位置
    @Published var exportMode: ExportMode = .library
    @Published var userAlbums: [AlbumItem] = []
    @Published var selectedAlbumID: String?
    @Published var newAlbumName: String = "HEIF截图"
    @Published var exportFolderURL: URL?
    @Published var exportFolderName: String?

    // MARK: - Private

    private var assets: [PHAsset] = []
    private var shouldStop = false
    private let workerQueue = DispatchQueue(label: "PNG2HEIF.worker", qos: .userInitiated)
    private var sampleRatio: Float = 0.15

    // MARK: - Computed

    var pngSizeText: String {
        ByteCountFormatter.string(fromByteCount: pngSize, countStyle: .file)
    }

    var estimatedSizeText: String {
        ByteCountFormatter.string(fromByteCount: estimatedHEIFSize, countStyle: .file)
    }

    var savedSizeText: String {
        let saved = pngSize - estimatedHEIFSize
        return ByteCountFormatter.string(fromByteCount: max(saved, 0), countStyle: .file)
    }

    var selectedAlbumTitle: String? {
        guard let id = selectedAlbumID else { return nil }
        return userAlbums.first(where: { $0.id == id })?.title
    }

    // MARK: - Album Management

    /// 加载用户相簿列表（在 scan 时自动调用）
    func loadAlbums() {
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumUserCreated,
            options: nil
        )
        var albums: [AlbumItem] = []
        fetch.enumerateObjects { collection, _, _ in
            albums.append(AlbumItem(collection))
        }
        // 按名称排序
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

    func scan() {
        guard !isWorking else { return }

        workerQueue.async { [weak self] in
            guard let self = self else { return }

            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: true)
            ]
            let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)

            var found: [PHAsset] = []
            var totalSize: Int64 = 0

            result.enumerateObjects { asset, _, _ in
                guard self.isPNG(asset: asset) else { return }
                found.append(asset)
            }

            for asset in found {
                totalSize += self.estimatedPNGSize(asset: asset)
            }

            let ratio = self.computeSampleRatio(assets: found)
            self.loadAlbums()

            DispatchQueue.main.async {
                self.assets = found
                self.pngCount = found.count
                self.pngSize = totalSize
                self.sampleRatio = ratio
                self.estimatedHEIFSize = Int64(Float(totalSize) * ratio)
                self.total = found.count
                self.processed = 0
                self.progress = 0
                self.status = "找到 \(found.count) 张 PNG"
            }
        }
    }

    // MARK: - Conversion Control

    func startConversion() {
        guard !isWorking, !assets.isEmpty else { return }

        // 文件夹模式需要先选择目录
        if exportMode == .folder, exportFolderURL == nil {
            status = "请先选择导出文件夹"
            return
        }
        // 相簿模式需要选择相簿
        if exportMode == .album, selectedAlbumID == nil {
            status = "请先选择一个相簿"
            return
        }
        // 新建相簿模式需要填写名称
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
        status = "开始转换…"

        if mode == .folder {
            // 文件夹导出：不需要 Photos 写入权限，直接写文件
            workerQueue.async { [weak self] in
                guard let self = self, let dir = folderURL else { return }
                self.convertToFolder(assets: work, dir: dir)
            }
        } else {
            // Photos 导出：需要相簿
            workerQueue.async { [weak self] in
                guard let self = self else { return }
                self.resolveAlbum(mode: mode, albumID: albumID, albumName: albumName) { album in
                    if mode == .library {
                        // 直接存图库，不需要相簿
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

    /// 根据导出模式获取目标相簿
    private func resolveAlbum(mode: ExportMode, albumID: String?, albumName: String,
                              completion: @escaping (PHAssetCollection?) -> Void) {
        switch mode {
        case .library:
            completion(nil)
            return

        case .album:
            if let id = albumID {
                let result = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [id], options: nil
                )
                completion(result.firstObject)
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

        for asset in work {
            if self.shouldStop { break }

            autoreleasepool {
                let ok = self.convertOneToPhotos(asset: asset, album: album)
                if ok { successCount += 1 } else { failCount += 1 }

                DispatchQueue.main.async {
                    self.processed += 1
                    self.progress = Double(self.processed) / Double(max(self.total, 1))
                    let pct = Int(self.progress * 100)
                    self.status = "已转换 \(self.processed) / \(self.total)（\(pct)%）"
                }
            }
        }

        if self.shouldStop {
            let skipped = work.count - successCount - failCount
            self.finish(message: "已停止：成功 \(successCount) 张，失败 \(failCount) 张，跳过 \(skipped) 张。")
        } else {
            self.finish(message: "完成：成功 \(successCount) 张，失败 \(failCount) 张。")
        }
    }

    // MARK: - Private: Folder Export

    private func convertToFolder(assets work: [PHAsset], dir: URL) {
        var successCount = 0
        var failCount = 0

        // 确保目录可写
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        for asset in work {
            if self.shouldStop { break }

            autoreleasepool {
                let ok = self.convertOneToFolder(asset: asset, dir: dir)
                if ok { successCount += 1 } else { failCount += 1 }

                DispatchQueue.main.async {
                    self.processed += 1
                    self.progress = Double(self.processed) / Double(max(self.total, 1))
                    let pct = Int(self.progress * 100)
                    self.status = "已导出 \(self.processed) / \(self.total)（\(pct)%）"
                }
            }
        }

        if self.shouldStop {
            let skipped = work.count - successCount - failCount
            self.finish(message: "已停止：导出 \(successCount) 张，失败 \(failCount) 张，跳过 \(skipped) 张。")
        } else {
            self.finish(message: "导出完成：成功 \(successCount) 张，失败 \(failCount) 张。保存至 \(dir.lastPathComponent)")
        }
    }

    // MARK: - Private: Asset Inspection

    private func isPNG(asset: PHAsset) -> Bool {
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

    // MARK: - Private: Sample Ratio

    private func computeSampleRatio(assets: [PHAsset]) -> Float {
        let index = Swift.min(Swift.max(assets.count / 2, 0), assets.count - 1)
        guard !assets.isEmpty else { return 0.15 }
        let sampleAsset = assets[index]

        let resource = PHAssetResource.assetResources(for: sampleAsset).first(where: {
            let uti = $0.uniformTypeIdentifier.lowercased()
            return uti == "public.png" || uti.contains("png")
        })

        guard let resource = resource else { return 0.15 }

        let pngSize = Int64(resource.value(forKey: "fileSize") as? Int64 ?? 0)
        guard pngSize > 0 else { return 0.15 }

        let semaphore = DispatchSemaphore(value: 0)
        var heifSize: Int64 = 0

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".heic")

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: inputURL, options: opts) { _ in
            defer {
                try? FileManager.default.removeItem(at: inputURL)
                try? FileManager.default.removeItem(at: outputURL)
            }
            guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                semaphore.signal()
                return
            }
            let quality = self.compressionQuality
            guard let dest = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.heic.identifier as CFString, 1, nil
            ) else {
                semaphore.signal()
                return
            }
            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
            CGImageDestinationFinalize(dest)

            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
               let size = attrs[.size] as? Int64 {
                heifSize = size
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 30)
        let ratio = Float(heifSize) / Float(pngSize)
        return clampFloat(ratio, 0.01...1.0)
    }

    // MARK: - Private: Encode HEIF (shared)

    /// 导出 PNG → 编码 HEIF，返回临时 HEIF 文件 URL。失败返回 nil。
    private func encodeHEIF(from asset: PHAsset) -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            let uti = $0.uniformTypeIdentifier.lowercased()
            return uti == "public.png" || uti.contains("png") || $0.originalFilename.lowercased().hasSuffix(".png")
        }) else { return nil }

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".heic")

        let exportOpts = PHAssetResourceRequestOptions()
        exportOpts.isNetworkAccessAllowed = true

        let semaphore = DispatchSemaphore(value: 0)
        var encodeOK = false

        PHAssetResourceManager.default().writeData(for: resource, toFile: inputURL, options: exportOpts) { [weak self] error in
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

            var metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.heic.identifier as CFString, 1, nil
            ) else {
                print("[PNG2HEIF] 创建 HEIC destination 失败")
                semaphore.signal()
                return
            }

            metadata[kCGImageDestinationLossyCompressionQuality] = self?.compressionQuality ?? 0.82

            // 写入 EXIF 日期
            if self?.keepCreationDate == true, let originalDate = asset.creationDate {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
                let ds = fmt.string(from: originalDate)

                var exif = (metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
                exif[kCGImagePropertyExifDateTimeOriginal] = ds
                exif[kCGImagePropertyExifDateTimeDigitized] = ds
                metadata[kCGImagePropertyExifDictionary] = exif

                var tiff = (metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
                tiff[kCGImagePropertyTIFFDateTime] = ds
                metadata[kCGImagePropertyTIFFDictionary] = tiff

                try? FileManager.default.setAttributes([
                    .creationDate: originalDate, .modificationDate: originalDate
                ], ofItemAtPath: outputURL.path)
            }

            CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)

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
            return outputURL
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    // MARK: - Private: Convert One → Photos

    private func convertOneToPhotos(asset: PHAsset, album: PHAssetCollection?) -> Bool {
        guard let heifURL = encodeHEIF(from: asset) else { return false }

        defer {
            try? FileManager.default.removeItem(at: heifURL)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var convertSuccess = false

        let originalDate = asset.creationDate
        let shouldKeepDate = self.keepCreationDate
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

            if shouldKeepDate, let date = originalDate {
                req.creationDate = date
            }
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
        }) { [weak self] changed, error in
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
        guard let heifURL = encodeHEIF(from: asset) else { return false }

        defer {
            try? FileManager.default.removeItem(at: heifURL)
        }

        // 用原始文件名（改扩展名）或 asset 本地 ID
        let resources = PHAssetResource.assetResources(for: asset)
        let originalName = resources.first?.originalFilename ?? ""
        let baseName = (originalName as NSString).deletingPathExtension
        let safeName = baseName.isEmpty ? UUID().uuidString : baseName
        let destURL = dir.appendingPathComponent(safeName + ".heic")

        // 避免文件名重复
        let finalURL = FileManager.default.uniqueFileName(for: destURL)

        do {
            try FileManager.default.copyItem(at: heifURL, to: finalURL)
        } catch {
            print("[PNG2HEIF] 复制到文件夹失败: \(error.localizedDescription)")
            return false
        }

        // 如果需要删除原图
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
            self.isWorking = false
            self.shouldStop = false
            self.status = message
            self.scan()
            self.alert = AlertItem(title: "转换完成", message: message)
        }
    }
}

// MARK: - Helpers

private func clampFloat(_ value: Float, _ range: ClosedRange<Float>) -> Float {
    return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
}

extension FileManager {
    /// 如果文件已存在，自动加序号避免覆盖：photo.heic → photo 2.heic
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
