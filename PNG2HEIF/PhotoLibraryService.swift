import Foundation
import Photos
import ImageIO
import VideoToolbox
import CoreVideo
import CoreMedia
import UniformTypeIdentifiers
import UIKit
import Combine
import SQLite3

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

// MARK: - Source asset ↔ new asset pairing

/// 一次转换的"对应关系"：源图是哪张、在新库里落成哪一行、这一行的 ZKINDSUBTYPE 从几变成几。
/// 用户要求"选中的照片要和 SQL 行对应起来"，所以这里把可核对的东西都留着：
/// 源图原始文件名、新资产的 localIdentifier、数据库里的 Z_PK / 文件名，以及
/// **新资产 localIdentifier 的 UUID 与这一行 ZUUID 是否吻合** —— 不吻合就说明可能对错了行。
struct PairingEntry: Identifiable {
    let id = UUID()
    let sourceName: String
    let sourceIdentifier: String
    let newIdentifier: String?
    let zpk: Int64?
    let newFilename: String?
    let before: Int64?
    let after: Int64?
    let uuidMatched: Bool
    let note: String?
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

    // 自选转换（应用内选择照片）
    @Published var selectedLocalIdentifiers: [String] = []
    /// 源图 ↔ 新资产 的对应记录，最新在前
    @Published var pairingLog: [PairingEntry] = []
    /// 这次转换针对什么（全部扫描 / 仅选中的 N 张）—— 进度条上要显示，免得看错对象
    @Published var conversionScope = ""
    /// 运行环境自检：工作目录与 Documents 能不能写
    @Published var environmentProbe = ""
    /// 选择器回传情况（选了图却什么都没发生的时候，看这一行）
    @Published var lastPickerReport = ""
    /// 编码自检结果
    @Published var codecProbe = ""

    // 截图标记（ZASSET.ZKINDSUBTYPE）
    /// 默认关闭：打开后，转换成功的资产会被写成截图（10）。关闭时程序行为与以前完全一致。
    @Published var writeScreenshotSubtype = false
    @Published var subtypeWrittenCount = 0
    @Published var subtypeProbe = "点「刷新数据库状态」检查权限与文件"
    @Published var subtypeRows: [ScreenshotSubtype.Row] = []
    @Published var subtypeLastResult: String?

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

    // MARK: - Screenshot Subtype

    /// 刷新面板：探测数据库 + 读最近几行 + 环境自检
    /// （重启 Photos / respring 之后点一下就知道系统有没有写回）
    func refreshSubtypePanel(limit: Int = 12) {
        workerQueue.async { [weak self] in
            let probe = ScreenshotSubtype.probe()
            let environment = PhotoLibraryService.environmentReport()
            let rows = ScreenshotSubtype.recent(limit: limit)
            DispatchQueue.main.async {
                self?.subtypeProbe = probe
                self?.environmentProbe = environment
                self?.subtypeRows = rows
            }
        }
    }

    /// 面板上的单键写入 / 还原
    func setSubtype(_ value: Int64, zpk: Int64) {
        status = value == ScreenshotSubtype.screenshot ? "写入截图标记…" : "还原为普通照片…"
        workerQueue.async { [weak self] in
            let result = ScreenshotSubtype.setKindSubtype(value, zpk: zpk)
            DispatchQueue.main.async {
                switch result {
                case .success(let change):
                    self?.subtypeLastResult = "Z_PK=\(zpk)   \(change.before) → \(change.after)"
                    self?.status = change.after == value
                        ? "已写入 \(change.after)"
                        : "数据库里仍是 \(change.after)（可能被 Photos 写回）"
                case .failure(let error):
                    self?.subtypeLastResult = "Z_PK=\(zpk)   失败：\(error.localizedDescription)"
                    self?.status = "写入失败"
                }
                self?.refreshSubtypePanel()
            }
        }
    }

    /// 转换成功后调用：把刚建好的那个资产标成截图，并记录"源图 ↔ 新资产"的对应关系。
    /// 定位不到就什么都不写，绝不去改一个来路不明的行。
    private func markAsScreenshot(source: PHAsset, localIdentifier: String?) {
        let sourceName = PHAssetResource.assetResources(for: source).first?.originalFilename
            ?? source.localIdentifier
        let newUUID = localIdentifier?.split(separator: "/").first.map(String.init)

        guard let zpk = ScreenshotSubtype.findZPK(localIdentifier: localIdentifier) else {
            publishPairing(PairingEntry(sourceName: sourceName,
                                        sourceIdentifier: source.localIdentifier,
                                        newIdentifier: localIdentifier,
                                        zpk: nil, newFilename: nil, before: nil, after: nil,
                                        uuidMatched: false,
                                        note: "没在数据库里定位到新资产，未写入"))
            return
        }

        let row = ScreenshotSubtype.row(zpk: zpk)
        // 这一行的 ZUUID 应当等于新资产 localIdentifier 的 UUID；不等就说明可能对错了行
        let rowUUID = row?.uuid ?? ""
        let uuidMatched = !rowUUID.isEmpty && rowUUID == newUUID
        let note: String?
        if localIdentifier == nil {
            note = "localIdentifier 缺失，按「最新一行」兜底定位，请人工核对"
        } else if !uuidMatched {
            note = "UUID 不吻合，数据库里这一行可能不是刚建的那个资产"
        } else {
            note = nil
        }

        switch ScreenshotSubtype.setKindSubtype(ScreenshotSubtype.screenshot, zpk: zpk) {
        case .success(let change):
            DispatchQueue.main.async { [weak self] in self?.subtypeWrittenCount += 1 }
            publishPairing(PairingEntry(sourceName: sourceName,
                                        sourceIdentifier: source.localIdentifier,
                                        newIdentifier: localIdentifier,
                                        zpk: zpk,
                                        newFilename: row?.filename,
                                        before: change.before,
                                        after: change.after,
                                        uuidMatched: uuidMatched,
                                        note: note))
        case .failure(let error):
            publishPairing(PairingEntry(sourceName: sourceName,
                                        sourceIdentifier: source.localIdentifier,
                                        newIdentifier: localIdentifier,
                                        zpk: zpk,
                                        newFilename: row?.filename,
                                        before: nil, after: nil,
                                        uuidMatched: uuidMatched,
                                        note: "写入失败：\(error.localizedDescription)"))
        }
    }

    private func publishPairing(_ entry: PairingEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pairingLog.insert(entry, at: 0)
            if self.pairingLog.count > 50 {
                self.pairingLog.removeLast(self.pairingLog.count - 50)
            }
            if let note = entry.note {
                self.subtypeLastResult = "\(entry.sourceName)：\(note)"
            } else if let before = entry.before, let after = entry.after {
                self.subtypeLastResult = "\(entry.sourceName) → Z_PK=\(entry.zpk ?? -1)  \(before) → \(after)"
            }
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

    // MARK: - Work Directory

    /// 候选工作目录，按优先级排列：App 自己的临时目录优先，`/tmp/png2heif` 兜底。
    ///
    /// 只认 `FileManager.default.temporaryDirectory` 是不够的：数据容器一旦被去掉，
    /// 那个路径就不存在，表现为"每一张都转换失败"（曾经真的这样栽过一次）。
    static func workDirectoryCandidates() -> [URL] {
        [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp/png2heif")]
    }

    /// 目录建得出来、而且真能写进去，才算可用
    static func prepareDirectory(_ directory: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".probe-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe)
            try? manager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// 给界面用的文字版结论
    static func resolveWorkDirectory() -> (url: URL?, detail: String) {
        var notes: [String] = []
        for candidate in workDirectoryCandidates() {
            if prepareDirectory(candidate) {
                notes.append("\(candidate.path) 可写")
                return (candidate, notes.joined(separator: "；"))
            }
            notes.append("\(candidate.path) 不可写")
        }
        return (nil, notes.joined(separator: "；"))
    }

    /// 上次失败的原因，给 FailedItem 用 —— 以前只在控制台 print，界面只显示"转换失败"，
    /// 排查时等于没有信息
    private var lastFailureReason: String?

    static func environmentReport() -> String {
        let manager = FileManager.default
        let work = resolveWorkDirectory()
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        lines.append("App 版本：\(version)（build \(build)）")
        lines.append("工作目录：\(work.url?.path ?? "无（两个候选都写不了）")")
        lines.append(work.detail)
        if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let probe = documents.appendingPathComponent(".probe-\(UUID().uuidString)")
            let writable = (try? Data("ok".utf8).write(to: probe)) != nil
            try? manager.removeItem(at: probe)
            lines.append("Documents：\(documents.path) \(writable ? "可写" : "不可写")")
        } else {
            lines.append("Documents：不可用")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Codec Self Test

    /// 编码自检。目的：区分"编码器在这台机器上就是坏的"与"某一类图被拒"。
    /// 用**代码生成**的标准 8bit RGB 图分别试 PNG / JPEG / HEIC（三条互不相同的编码器路径），
    /// 再拿一张真实资产的 PNG 走完整阶梯，最后探一下 VideoToolbox 的 HEVC 编码器
    /// （这台机器的 CoreImage 是坏的：创建 CIContext 会直接崩，详见该方法的注释）。
    func runCodecSelfTest() {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            let report = self.codecSelfTest()
            DispatchQueue.main.async { self.codecProbe = report }
        }
    }

    private func codecSelfTest() -> String {
        var lines: [String] = []
        let resolved = PhotoLibraryService.resolveWorkDirectory()
        lines.append("工作目录：\(resolved.url?.path ?? "无")　\(resolved.detail)")
        guard let directory = resolved.url else { return lines.joined(separator: "\n") }

        if let synthetic = PhotoLibraryService.syntheticImage() {
            lines.append("测试图：\(synthetic.width)×\(synthetic.height) \(synthetic.bitsPerComponent)bit alpha=\(synthetic.alphaInfo.rawValue)")
            lines.append(PhotoLibraryService.encodeProbe(synthetic, type: .png, in: directory, label: "生成图 → PNG "))
            lines.append(PhotoLibraryService.encodeProbe(synthetic, type: .jpeg, in: directory, label: "生成图 → JPEG"))
            lines.append(PhotoLibraryService.encodeProbe(synthetic, type: .heic, in: directory, label: "生成图 → HEIC"))

            let own = HEIFWriter.encode(synthetic, quality: 0.82)
            if let data = own.data {
                lines.append("生成图 → 自建 HEIF：通过（\(data.count) 字节）")
            } else {
                lines.append("生成图 → 自建 HEIF：失败 — \(own.failure ?? "未知")")
            }
        } else {
            lines.append("测试图生成失败：CoreGraphics 位图上下文建不起来")
        }

        if let asset = assets.first(where: { PhotoLibraryService.pngResource(of: $0) != nil }),
           let resource = PhotoLibraryService.pngResource(of: asset) {
            let attempt = attemptEncode(resource: resource, directory: directory, quality: compressionQuality)
            if attempt.url != nil {
                lines.append("真实资产 \(resource.originalFilename)：HEIC 通过")
            } else {
                lines.append("真实资产 \(resource.originalFilename)：HEIC 失败 — \(attempt.failure ?? "未知")")
            }
        } else {
            lines.append("没找到可用于测试的 PNG 资产（先点「扫描图库」）")
        }

        lines.append(PhotoLibraryService.videoToolboxProbe())
        lines.append(PhotoLibraryService.pixelBufferProbe())
        return lines.joined(separator: "\n")
    }

    /// 单独探一下 CVPixelBuffer 本身：不带附加属性 vs 带 IOSurface。
    /// 这台机器图形栈是坏的，IOSurface 可能申请不到，所以两者要分开看。
    private static func pixelBufferProbe() -> String {
        var plain: CVPixelBuffer?
        let plainStatus = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                              kCVPixelFormatType_32BGRA, nil, &plain)
        var surface: CVPixelBuffer?
        let surfaceStatus = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                                kCVPixelFormatType_32BGRA,
                                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                                &surface)
        var base: UnsafeMutableRawPointer?
        if let buffer = plain {
            CVPixelBufferLockBaseAddress(buffer, [])
            base = CVPixelBufferGetBaseAddress(buffer)
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        return "CVPixelBuffer：无附加属性 CVReturn=\(plainStatus)（基地址 \(base == nil ? "拿不到" : "可写")），"
            + "带 IOSurface CVReturn=\(surfaceStatus)"
    }

    static func pngResource(of asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first(where: {
            let uti = $0.uniformTypeIdentifier.lowercased()
            return uti == "public.png" || uti.contains("png") || $0.originalFilename.lowercased().hasSuffix(".png")
        })
    }

    /// 代码生成的标准 8bit sRGB 图，不带任何来自文件的怪东西
    private static func syntheticImage() -> CGImage? {
        let size = 256
        guard let context = CGContext(data: nil,
                                      width: size,
                                      height: size,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 32, y: 32, width: 64, height: 64))
        return context.makeImage()
    }

    private static func encodeProbe(_ image: CGImage, type: UTType, in directory: URL, label: String) -> String {
        let url = directory.appendingPathComponent(UUID().uuidString + "." + (type.preferredFilenameExtension ?? "bin"))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            return "\(label)：无法创建编码器"
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        let ok = CGImageDestinationFinalize(destination)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        try? FileManager.default.removeItem(at: url)
        return "\(label)：\(ok ? "通过（\(size) 字节）" : "失败")"
    }

    // MARK: - Conversion Control

    /// 应用内选中的照片（PHPicker 回传的 assetIdentifier）
    func setSelection(_ identifiers: [String]) {
        selectedLocalIdentifiers = identifiers
        if identifiers.isEmpty {
            lastPickerReport = "选择器没有回传可用标识符（assetIdentifier 为空）—— 选中的图没能对应回图库，请重试或改用「开始转换」"
        } else {
            let first = identifiers.first ?? ""
            lastPickerReport = "选择器回传 \(identifiers.count) 个标识符，首个：\(first)"
        }
        status = identifiers.isEmpty ? "未选中照片" : "已选中 \(identifiers.count) 张"
    }

    func startConversion() {
        beginConversion(with: assets, scope: "全部扫描到的 PNG")
    }

    /// 只转换用户手动选中的那几张。
    /// 选中项按 localIdentifier 记住，这里再把它换回 PHAsset —— 顺序按用户选的顺序保留，
    /// 这样对应表里的先后和选择一致。
    func convertSelected() {
        guard !isWorking else { return }
        let identifiers = selectedLocalIdentifiers
        guard !identifiers.isEmpty else {
            status = "先用「选择照片」挑几张"
            return
        }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byIdentifier: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byIdentifier[asset.localIdentifier] = asset }

        var ordered: [PHAsset] = []
        var missing = 0
        for identifier in identifiers {
            if let asset = byIdentifier[identifier] {
                ordered.append(asset)
                continue
            }
            // 兜底：拿标识符的第一段（UUID）再匹配一次 —— PHPicker 回传的前缀未必与
            // PHAsset.localIdentifier 逐字一致
            let uuid = identifier.split(separator: "/").first.map(String.init) ?? identifier
            if let match = byIdentifier.first(where: { $0.key.hasPrefix(uuid) })?.value {
                ordered.append(match)
            } else {
                missing += 1
            }
        }
        guard !ordered.isEmpty else {
            /* 定位不到就说清楚"选了几张、查到几张、首个标识符长什么样" ——
               之前只写一句"已经不在图库里了"，等于没信息 */
            let sample = identifiers.first ?? ""
            lastPickerReport = "选中 \(identifiers.count) 张，按 localIdentifier 在图库里只查到 \(byIdentifier.count) 张，无法定位。首个标识符：\(sample)"
            status = "选中的照片在图库里查不到"
            return
        }
        if missing > 0 {
            lastPickerReport = "选中 \(identifiers.count) 张，其中 \(missing) 张查不到，转换剩下的 \(ordered.count) 张"
            status = lastPickerReport
        }
        beginConversion(with: ordered, scope: "仅选中的 \(ordered.count) 张")
    }

    private func beginConversion(with work: [PHAsset], scope: String) {
        guard !isWorking, !work.isEmpty else { return }

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
        conversionScope = scope
        status = "开始转换（\(scope)）…"

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
                        error: lastFailureReason ?? "转换或写入失败",
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
                        error: lastFailureReason ?? "转换或写入文件失败",
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

    /// 铺一层白底、重画成 8bit sRGB 并去掉 alpha 通道。
    /// HEIF 里没有 alpha；而且 16bit / 索引 / 非标准色彩空间的 PNG 也可能被编码器拒绝，
    /// 重画一遍能把这些一次性归到标准形态。
    private static func flattenedForHEIC(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// 依次在两个候选目录里尝试（容器临时目录优先，/tmp 兜底）。
    /// 一个目录失败就换下一个；两个都失败时把**两边的原因**都报出来。
    private func encodeHEIF(from asset: PHAsset) -> (url: URL?, pngSize: Int64) {
        lastFailureReason = nil
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            let uti = $0.uniformTypeIdentifier.lowercased()
            return uti == "public.png" || uti.contains("png") || $0.originalFilename.lowercased().hasSuffix(".png")
        }) else {
            lastFailureReason = "这张资产里没有 PNG 资源"
            return (nil, 0)
        }

        let pngSize = Int64(resource.value(forKey: "fileSize") as? Int64 ?? 0)
        var reasons: [String] = []

        for directory in PhotoLibraryService.workDirectoryCandidates() {
            guard PhotoLibraryService.prepareDirectory(directory) else {
                reasons.append("\(directory.path) 不可写")
                continue
            }
            let attempt = attemptEncode(resource: resource,
                                       directory: directory,
                                       quality: compressionQuality)
            if let url = attempt.url { return (url, pngSize) }
            reasons.append("\(directory.path)：\(attempt.failure ?? "未知原因")")
        }

        lastFailureReason = reasons.joined(separator: "；")
        return (nil, 0)
    }

    /// 一次完整的「导出 PNG → 解码 → 编码 HEIC」，针对一个具体目录
    private func attemptEncode(resource: PHAssetResource,
                               directory: URL,
                               quality: Float) -> (url: URL?, failure: String?) {
        let inputURL = directory.appendingPathComponent(UUID().uuidString + ".png")

        let exportOpts = PHAssetResourceRequestOptions()
        exportOpts.isNetworkAccessAllowed = true

        let semaphore = DispatchSemaphore(value: 0)
        var outputURL: URL?
        var failure: String?

        PHAssetResourceManager.default().writeData(for: resource, toFile: inputURL, options: exportOpts) { error in
            defer {
                try? FileManager.default.removeItem(at: inputURL)
            }
            if let error = error {
                failure = "导出 PNG 失败：\(error.localizedDescription)"
                semaphore.signal()
                return
            }

            guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                failure = "解码 PNG 失败（可能还没从 iCloud 下载完，或文件已损坏）"
                semaphore.signal()
                return
            }

            var reasons: [String] = []
            let spaceName: String = {
                guard let space = cgImage.colorSpace, let name = space.name else { return "?" }
                return name as String
            }()
            let shape = "\(cgImage.width)×\(cgImage.height) \(cgImage.bitsPerComponent)bit/\(cgImage.bitsPerPixel)bpp alpha=\(cgImage.alphaInfo.rawValue) cs=\(spaceName)"

            /* 只走 ImageIO。**绝不碰 CoreImage**：这台机器上 `CIContext(options:)` 会在
               CI::GLContext::GLContext 里空指针崩溃（2026-09-23 12:20 的崩溃日志为证），
               之前那条 CoreImage 兜底就是这么把 App 打死的。
               每一步用新的输出文件名 —— 失败过的 URL 会让下一个 destination 创建失败。 */
            if let url = PhotoLibraryService.writeHEIC(cgImage, in: directory, quality: quality) {
                outputURL = url
                semaphore.signal()
                return
            }
            reasons.append("原图直接编码失败（\(shape)）")

            if let flattened = PhotoLibraryService.flattenedForHEIC(cgImage) {
                if let url = PhotoLibraryService.writeHEIC(flattened, in: directory, quality: quality) {
                    outputURL = url
                    semaphore.signal()
                    return
                }
                reasons.append("重画成 8bit sRGB 去掉 alpha 后编码仍失败")
            } else {
                reasons.append("无法重画（CGContext 位图上下文创建失败）")
            }

            /* 第三条路：自己来。自检显示这台设备的 ImageIO 编不出 HEIC（连生成的干净图也失败）
               而 VideoToolbox 可用，所以用 VT 编 HEVC + 手工封装 HEIF 容器。
               仍然不碰 CoreImage。 */
            let own = HEIFWriter.encode(cgImage, quality: quality)
            if let data = own.data {
                let targetURL = directory.appendingPathComponent(UUID().uuidString + ".heic")
                do {
                    try data.write(to: targetURL)
                    outputURL = targetURL
                    semaphore.signal()
                    return
                } catch {
                    reasons.append("自建 HEIF 写文件失败：\(error.localizedDescription)")
                }
            } else {
                reasons.append("自建 HEIF（VideoToolbox）失败：\(own.failure ?? "未知")")
            }

            failure = "HEIC 编码失败：" + reasons.joined(separator: "；") + "（目录 \(directory.path)）"
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 120)

        if let outputURL = outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
            return (outputURL, nil)
        }
        return (nil, failure ?? "编码超时（超过 120 秒）")
    }

    /// 用 ImageIO 把一张图编成 HEIC 写到指定目录，成功返回文件 URL。
    /// 每次都用新的输出文件名，绝不复用失败过的路径。
    private static func writeHEIC(_ image: CGImage, in directory: URL, quality: Float) -> URL? {
        let outputURL = directory.appendingPathComponent(UUID().uuidString + ".heic")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }

        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return outputURL
    }

    /// VideoToolbox 的 HEVC 编码器能不能用。
    /// 这是"绕开 ImageIO，自己用 VT 编 HEVC 再手工封装 HEIF"这条路的前提判断 ——
    /// VideoToolbox 不经过 CoreImage，而 CoreImage 在这台机器上是坏的。
    private static func videoToolboxProbe() -> String {
        let callback: VTCompressionOutputCallback = { _, _, _, _, _ in }
        var session: VTCompressionSession?
        let created = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                 width: 64,
                                                 height: 64,
                                                 codecType: kCMVideoCodecType_HEVC,
                                                 encoderSpecification: nil,
                                                 imageBufferAttributes: nil,
                                                 compressedDataAllocator: nil,
                                                 outputCallback: callback,
                                                 refcon: nil,
                                                 compressionSessionOut: &session)
        guard created == noErr, let session = session else {
            return "VideoToolbox HEVC：创建会话失败（OSStatus \(created)）"
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        VTCompressionSessionInvalidate(session)
        if prepared == noErr {
            return "VideoToolbox HEVC：可用（会话创建 + Prepare 都成功）"
        }
        return "VideoToolbox HEVC：Prepare 失败（OSStatus \(prepared)）"
    }

    // MARK: - Private: Convert One → Photos

    private func convertOneToPhotos(asset: PHAsset, album: PHAssetCollection?) -> Bool {
        guard let heifURL = encodeHEIF(from: asset).url else { return false }

        defer {
            try? FileManager.default.removeItem(at: heifURL)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var convertSuccess = false
        var createdLocalIdentifier: String?

        let loc = asset.location
        let fav = asset.isFavorite
        let shouldDelete = self.deleteOriginals
        let shouldMarkScreenshot = self.writeScreenshotSubtype
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
            createdLocalIdentifier = req.placeholderForCreatedAsset?.localIdentifier

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

                if shouldMarkScreenshot {
                    self.markAsScreenshot(source: asset, localIdentifier: createdLocalIdentifier)
                }

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
            lastFailureReason = "复制到所选文件夹失败：\(error.localizedDescription)（文件夹授权可能已失效，重新选一次）"
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

// MARK: - Screenshot subtype (Photos.sqlite)

/// 读取 / 写入 `ZASSET.ZKINDSUBTYPE`。
///
/// 为什么需要它：公开 PhotoKit 不允许把新建的资产标记成"截图"，所以旧版只能自建一个普通相簿
/// （`HEIF截图`）来管理。而 Photos 显示时真正看的是这一列：
///
///   0  = 普通照片
///   2  = Live Photo
///   10 = SpringBoard 截图（写进去相册立刻按截图显示，改回 0 就不再是截图）
///
/// 这条结论由 PhotosDatabaseInspector 项目在真机上验证过：把某个资产的这一列改成 10，系统相册
/// 立刻当作截图；改回 0 又变回普通照片。映射本身出自社区取证查询库
/// （pecca86/Photos.Sqlite_Queries），与设备上的实际行吻合。
///
/// 纪律：一条语句、一行、绑定参数；不做 DDL、不改 journal_mode、不 checkpoint、不 VACUUM；
/// 写之前先读旧值以便还原。Photos 守护进程随时可能在写，冲突会返回 SQLITE_BUSY —— 原样报错，
/// 不盲目重试。
enum ScreenshotSubtype {

    static let databasePath = "/var/mobile/Media/PhotoData/Photos.sqlite"
    static let screenshot: Int64 = 10
    static let stillPhoto: Int64 = 0

    /// SQLITE_TRANSIENT：让 SQLite 把参数值拷进语句，Swift 没有导出这个常量
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row: Identifiable {
        let zpk: Int64
        let filename: String
        let uuid: String
        let kindSubtype: Int64
        let cloudKindSubtype: Int64
        let addedAt: String

        var id: Int64 { zpk }
        var isScreenshot: Bool { kindSubtype == screenshot }
    }

    enum Failure: LocalizedError {
        case message(String)

        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    // MARK: - Connection

    private static func open(_ flags: Int32) -> (OpaquePointer?, String?) {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(databasePath, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            if let handle = handle { sqlite3_close(handle) }
            return (nil, "打开数据库失败 rc=\(rc)：\(detail)")
        }
        sqlite3_busy_timeout(db, 3000)
        return (db, nil)
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: raw)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return formatter
    }()

    /// Core Data 的时间戳是"2001-01-01 起的秒数"
    static func formatAddedDate(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return dateFormatter.string(from: Date(timeIntervalSinceReferenceDate: value))
    }

    // MARK: - Read

    /// 探测：文件在不在、-wal/-shm 多大、能不能读到 ZASSET。
    /// 权限不够时这里会直接说出来，比自己猜快。
    static func probe() -> String {
        var lines: [String] = [databasePath]
        let manager = FileManager.default
        guard manager.fileExists(atPath: databasePath) else {
            lines.append("文件不存在")
            return lines.joined(separator: "\n")
        }
        for suffix in ["", "-wal", "-shm"] {
            let label = suffix.isEmpty ? "main" : suffix
            if let attrs = try? manager.attributesOfItem(atPath: databasePath + suffix),
               let size = attrs[.size] as? NSNumber {
                lines.append("\(label) \(size.int64Value) 字节")
            } else {
                lines.append("\(label) 不存在")
            }
        }

        let (db, error) = open(SQLITE_OPEN_READONLY)
        guard let db = db else {
            lines.append(error ?? "打开失败")
            return lines.joined(separator: "\n")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZASSET", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            lines.append("ZASSET 行数 \(sqlite3_column_int64(stmt, 0))")
        } else {
            lines.append("读 ZASSET 失败：\(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
        return lines.joined(separator: "\n")
    }

    /// 最近 N 行：用来验证写入结果，也用来在 respring 之后看系统有没有把值写回去。
    static func recent(limit: Int) -> [Row] {
        let (db, _) = open(SQLITE_OPEN_READONLY)
        guard let db = db else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT a.Z_PK, IFNULL(a.ZFILENAME,''), IFNULL(a.ZUUID,''), IFNULL(a.ZKINDSUBTYPE,-1),
               IFNULL(d.ZCLOUDKINDSUBTYPE,-1), IFNULL(a.ZADDEDDATE,0)
        FROM ZASSET a
        LEFT JOIN ZADDITIONALASSETATTRIBUTES d ON d.Z_PK = a.ZADDITIONALASSETATTRIBUTES
        ORDER BY a.Z_PK DESC
        LIMIT ?1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Row(zpk: sqlite3_column_int64(stmt, 0),
                            filename: text(stmt, 1),
                            uuid: text(stmt, 2),
                            kindSubtype: sqlite3_column_int64(stmt, 3),
                            cloudKindSubtype: sqlite3_column_int64(stmt, 4),
                            addedAt: formatAddedDate(sqlite3_column_double(stmt, 5))))
        }
        return rows
    }

    /// 单行读取。定位之后要核对"这一行就是刚建的那个资产"，所以需要拿到它的 ZUUID / 文件名。
    static func row(zpk: Int64) -> Row? {
        let (db, _) = open(SQLITE_OPEN_READONLY)
        guard let db = db else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT a.Z_PK, IFNULL(a.ZFILENAME,''), IFNULL(a.ZUUID,''), IFNULL(a.ZKINDSUBTYPE,-1),
               IFNULL(d.ZCLOUDKINDSUBTYPE,-1), IFNULL(a.ZADDEDDATE,0)
        FROM ZASSET a
        LEFT JOIN ZADDITIONALASSETATTRIBUTES d ON d.Z_PK = a.ZADDITIONALASSETATTRIBUTES
        WHERE a.Z_PK = ?1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, zpk)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Row(zpk: sqlite3_column_int64(stmt, 0),
                   filename: text(stmt, 1),
                   uuid: text(stmt, 2),
                   kindSubtype: sqlite3_column_int64(stmt, 3),
                   cloudKindSubtype: sqlite3_column_int64(stmt, 4),
                   addedAt: formatAddedDate(sqlite3_column_double(stmt, 5)))
    }

    private static func scalarInt64(_ sql: String, text value: String? = nil) -> Int64? {
        let (db, _) = open(SQLITE_OPEN_READONLY)
        guard let db = db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        if let value = value { sqlite3_bind_text(stmt, 1, value, -1, transient) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func readKindSubtype(_ db: OpaquePointer?, zpk: Int64) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZKINDSUBTYPE FROM ZASSET WHERE Z_PK = ?1", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, zpk)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// 用 PhotoKit 的 localIdentifier（形如 "UUID/L0/001"）定位刚建好的那一行。
    /// 找不到就退回"最新一行、且是 5 分钟内添加的"；再不然返回 nil —— 宁可不写，
    /// 也不去改一个来路不明的行。
    static func findZPK(localIdentifier: String?) -> Int64? {
        if let localIdentifier = localIdentifier, !localIdentifier.isEmpty {
            let uuid = localIdentifier.split(separator: "/").first.map(String.init) ?? localIdentifier
            if let pk = scalarInt64("SELECT Z_PK FROM ZASSET WHERE ZUUID = ?1 LIMIT 1", text: uuid) {
                return pk
            }
        }

        let (db, _) = open(SQLITE_OPEN_READONLY)
        guard let db = db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_PK, IFNULL(ZADDEDDATE,0) FROM ZASSET ORDER BY Z_PK DESC LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let pk = sqlite3_column_int64(stmt, 0)
        let age = Date().timeIntervalSinceReferenceDate - sqlite3_column_double(stmt, 1)
        return (age >= 0 && age < 300) ? pk : nil
    }

    // MARK: - Write（本 App 唯一的写操作）

    /// 写一列、一行，返回 (旧值, 新值)。先读旧值是为了能还原。
    static func setKindSubtype(_ value: Int64, zpk: Int64) -> Result<(before: Int64, after: Int64), Failure> {
        let (db, error) = open(SQLITE_OPEN_READWRITE)
        guard let db = db else {
            return .failure(.message(error ?? "打开数据库失败"))
        }
        defer { sqlite3_close(db) }

        guard let before = readKindSubtype(db, zpk: zpk) else {
            return .failure(.message("ZASSET 里没有 Z_PK=\(zpk) 这一行"))
        }
        if before == value {
            return .success((before, before))
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE \"ZASSET\" SET ZKINDSUBTYPE = ?1 WHERE Z_PK = ?2", -1, &stmt, nil) == SQLITE_OK else {
            return .failure(.message("准备更新失败：\(String(cString: sqlite3_errmsg(db)))"))
        }
        sqlite3_bind_int64(stmt, 1, value)
        sqlite3_bind_int64(stmt, 2, zpk)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        guard rc == SQLITE_DONE else {
            return .failure(.message("更新失败 rc=\(rc)：\(String(cString: sqlite3_errmsg(db)))"))
        }

        // 回读：报告里要给数据库现在真正持有的值，而不是我们请求的值
        let after = readKindSubtype(db, zpk: zpk) ?? before
        return .success((before, after))
    }
}

// MARK: - HEIF writer: VideoToolbox + a hand-built container

/// 为什么需要自己写容器：这台设备上 **ImageIO 的 HEIC 编码器不可用** ——
/// 代码生成的 8bit sRGB 图编 PNG / JPEG 都成功，编 HEIC 却失败；
/// 而 **VideoToolbox 的 HEVC 编码器可用**（都是自检实测）。
/// 所以：用 VT 编出 HEVC 码流，再按 ISO/IEC 23008-12 拼一个最小 HEIF 容器。
///
/// **全程不碰 CoreImage**：这台机器上创建 `CIContext` 会在 `CI::GLContext` 里空指针崩溃
/// （2026-09-23 的崩溃日志为证），ImageIO 的 HEIC 路径很可能也是栽在这上面。
///
/// 盒子布局先在本地用 ffmpeg 验证过（`build/.tools/heif_proto.py`）：同样结构写出的 .heic
/// 能被 ffprobe 识别（hevc 64×64）、能被 ffmpeg 完整解码回 PNG，然后才移植到这里。
enum HEIFWriter {

    /// 编码 + 封装。成功返回文件内容，失败返回人话原因。
    static func encode(_ image: CGImage, quality: Float) -> (data: Data?, failure: String?) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return (nil, "尺寸无效（\(width)×\(height)）") }

        let pixels = makePixelBuffer(from: image)
        guard let pixelBuffer = pixels.buffer else {
            return (nil, "无法把图转成 CVPixelBuffer —— \(pixels.failure ?? "原因未知")")
        }

        let encoded = encodeHEVC(pixelBuffer, quality: quality)
        guard let stream = encoded.stream else {
            return (nil, encoded.reason ?? "VideoToolbox 编码失败")
        }
        guard !stream.config.isEmpty else { return (nil, "编码器没给出 hvcC 配置") }
        return (buildContainer(width: width, height: height,
                               itemData: stream.data, hvcC: stream.config), nil)
    }

    // MARK: - CGImage -> CVPixelBuffer

    /// 多组合尝试，并把**每一步的 CVReturn** 报出来。
    /// 先试不带附加属性的普通缓冲：这台机器的图形栈是坏的（CoreImage 建 GL 上下文会崩），
    /// 申请 IOSurface 有失败的风险，所以不能一上来就依赖它。
    private static func makePixelBuffer(from image: CGImage) -> (buffer: CVPixelBuffer?, failure: String?) {
        let width = image.width
        let height = image.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let combinations: [(label: String,
                            format: OSType,
                            attributes: [CFString: Any]?,
                            alpha: CGImageAlphaInfo,
                            byteOrder: CGBitmapInfo)] = [
            ("BGRA 无附加属性", kCVPixelFormatType_32BGRA, nil, .noneSkipFirst, .byteOrder32Little),
            ("BGRA + IOSurface", kCVPixelFormatType_32BGRA,
             [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary], .noneSkipFirst, .byteOrder32Little),
            ("ARGB 无附加属性", kCVPixelFormatType_32ARGB, nil, .noneSkipFirst, .byteOrder32Big),
            ("ARGB + IOSurface", kCVPixelFormatType_32ARGB,
             [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary], .noneSkipFirst, .byteOrder32Big)
        ]

        var reasons: [String] = []
        for combination in combinations {
            var buffer: CVPixelBuffer?
            let attributesDictionary: CFDictionary? = combination.attributes.map { $0 as CFDictionary }
            let created = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                              combination.format, attributesDictionary, &buffer)
            guard created == kCVReturnSuccess, let pixelBuffer = buffer else {
                reasons.append("\(combination.label)：CVPixelBufferCreate 失败（CVReturn \(created)）")
                continue
            }

            let locked = CVPixelBufferLockBaseAddress(pixelBuffer, [])
            guard locked == kCVReturnSuccess else {
                reasons.append("\(combination.label)：LockBaseAddress 失败（CVReturn \(locked)）")
                continue
            }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                reasons.append("\(combination.label)：拿不到基地址")
                continue
            }
            guard let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                          space: srgb,
                                          bitmapInfo: combination.alpha.rawValue | combination.byteOrder.rawValue) else {
                reasons.append("\(combination.label)：CGContext 创建失败")
                continue
            }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return (pixelBuffer, nil)
        }
        return (nil, reasons.joined(separator: "；"))
    }

    // MARK: - VideoToolbox

    /// 回调里要收集结果，而 C 函数指针捕获不了上下文，所以用 refcon 传一个盒子过去
    private final class Sink {
        var status: OSStatus = noErr
        var sample: CMSampleBuffer?
    }

    private static func encodeHEVC(_ pixelBuffer: CVPixelBuffer,
                                   quality: Float) -> (stream: (data: Data, config: Data)?, reason: String?) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

        let sink = Sink()
        let refcon = Unmanaged.passUnretained(sink).toOpaque()
        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard let refcon = refcon else { return }
            let sink = Unmanaged<Sink>.fromOpaque(refcon).takeUnretainedValue()
            sink.status = status
            if status == noErr { sink.sample = sampleBuffer }
        }

        var session: VTCompressionSession?
        let created = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                 width: width,
                                                 height: height,
                                                 codecType: kCMVideoCodecType_HEVC,
                                                 encoderSpecification: nil,
                                                 imageBufferAttributes: nil,
                                                 compressedDataAllocator: nil,
                                                 outputCallback: callback,
                                                 refcon: refcon,
                                                 compressionSessionOut: &session)
        guard created == noErr, let session = session else {
            return (nil, "VideoToolbox 创建会话失败（OSStatus \(created)）")
        }
        defer { VTCompressionSessionInvalidate(session) }

        // 单帧、不许重排序，容器才好写；质量直接给 VT
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality,
                             value: NSNumber(value: quality))

        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else {
            return (nil, "VideoToolbox Prepare 失败（OSStatus \(prepared)）")
        }

        let encoded = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: CMTime(value: 0, timescale: 1),
                                                     duration: .invalid,
                                                     frameProperties: nil,
                                                     sourceFrameRefcon: nil,
                                                     infoFlagsOut: nil)
        guard encoded == noErr else {
            return (nil, "VideoToolbox 提交帧失败（OSStatus \(encoded)）")
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        guard sink.status == noErr, let sample = sink.sample else {
            return (nil, "VideoToolbox 没有输出帧（OSStatus \(sink.status)）")
        }
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let atoms = CMFormatDescriptionGetExtension(
                  format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
              ) as? [String: Any],
              let config = atoms["hvcC"] as? Data else {
            return (nil, "拿不到 hvcC 配置（编码器没附带 sample description）")
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            return (nil, "编码结果为空")
        }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let read = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                               totalLengthOut: &length, dataPointerOut: &pointer)
        guard read == kCMBlockBufferNoErr, let start = pointer, length > 0 else {
            return (nil, "读不出编码数据（OSStatus \(read)）")
        }
        return ((data: Data(bytes: start, count: length), config: config), nil)
    }

    // MARK: - Container (same layout as the ffmpeg-verified prototype)

    private static func u8(_ value: UInt8) -> Data { Data([value]) }
    private static func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    private static func box(_ type: String, _ payload: Data) -> Data {
        var data = u32(UInt32(payload.count + 8))
        data.append(type.data(using: .ascii) ?? Data())
        data.append(payload)
        return data
    }

    private static func fullBox(_ type: String, _ payload: Data) -> Data {
        box(type, u8(0) + Data([0, 0, 0]) + payload)
    }

    static func buildContainer(width: Int, height: Int, itemData: Data, hvcC: Data) -> Data {
        let ftyp = box("ftyp", "heic".data(using: .ascii)! + u32(0) + "mif1".data(using: .ascii)!
            + "heic".data(using: .ascii)!)

        let ispe = fullBox("ispe", u32(UInt32(width)) + u32(UInt32(height)))
        let hvcCBox = box("hvcC", hvcC)
        // nclx：BT.709 primaries / sRGB transfer / BT.709 matrix / full range
        let colr = box("colr", "nclx".data(using: .ascii)! + u16(1) + u16(13) + u16(1) + u8(0x80))
        let pixi = fullBox("pixi", u8(3) + u8(8) + u8(8) + u8(8))
        let ipco = box("ipco", ispe + hvcCBox + colr + pixi)
        let ipma = fullBox("ipma", u32(1) + u16(1) + u8(4) + Data([1, 2, 3, 4]))
        let iprp = box("iprp", ipco + ipma)

        let infe = fullBox("infe", u16(1) + u16(0) + "hvc1".data(using: .ascii)! + u8(0))
        let iinf = fullBox("iinf", u16(1) + infe)
        let pitm = fullBox("pitm", u16(1))
        let hdlr = fullBox("hdlr", u32(0) + "pict".data(using: .ascii)! + Data(repeating: 0, count: 12) + u8(0))

        func iloc(offset: UInt32) -> Data {
            // offset_size=4, length_size=4 | base_offset_size=4, reserved=0
            fullBox("iloc", Data([0x44, 0x40]) + u16(1) + u16(1) + u16(0) + u32(0)
                + u16(1) + u32(offset) + u32(UInt32(itemData.count)))
        }

        func assemble(offset: UInt32) -> Data {
            let meta = fullBox("meta", hdlr + pitm + iloc(offset: offset) + iinf + iprp)
            return ftyp + meta
        }

        // iloc 里是文件绝对偏移，所以先把 meta 量出来再定值（字段定长，长度不会变）
        let itemOffset = UInt32(assemble(offset: 0).count + 8)   // mdat 头 8 字节
        return assemble(offset: itemOffset) + box("mdat", itemData)
    }
}
