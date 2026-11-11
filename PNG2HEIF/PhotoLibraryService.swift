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
            var seamlessNote: String?
            if uuidMatched {
                seamlessNote = applySeamlessReplacement(source: source, zpk: zpk)
            }
            let finalRow = ScreenshotSubtype.row(zpk: zpk)
            let combined = [note, seamlessNote].compactMap { $0 }.joined(separator: "；")
            publishPairing(PairingEntry(sourceName: sourceName,
                                        sourceIdentifier: source.localIdentifier,
                                        newIdentifier: localIdentifier,
                                        zpk: zpk,
                                        newFilename: finalRow?.filename ?? row?.filename,
                                        before: change.before,
                                        after: change.after,
                                        uuidMatched: uuidMatched,
                                        note: combined.isEmpty ? nil : combined))
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

    /// 无缝替换：把托管文件名改回源图名字（DCIM 物理改名 + ZFILENAME），并带上源图 ZSORTTOKEN
    /// 让排序回到原位置。只作用于已 UUID 确认的新资产行；目标重名或物理改名失败就保留
    /// Photos 命名，绝不覆盖已有文件；写库失败则回滚改名。
    private func applySeamlessReplacement(source: PHAsset, zpk: Int64) -> String {
        guard let info = ScreenshotSubtype.replacementInfo(zpk: zpk), !info.directory.isEmpty else {
            return "无缝替换：读不到新行/目录"
        }
        guard let sourceZpk = ScreenshotSubtype.findZPK(localIdentifier: source.localIdentifier),
              let sourceInfo = ScreenshotSubtype.replacementInfo(zpk: sourceZpk) else {
            return "无缝替换：定位不到源图行"
        }
        let desired = source.originalFilenameForConversion
        let root = "/var/mobile/Media/"
        let currentPath = root + info.directory + "/" + info.filename
        let desiredPath = root + info.directory + "/" + desired
        var renamed = false
        if info.filename != desired {
            guard !FileManager.default.fileExists(atPath: desiredPath) else {
                return "无缝替换：\(desired) 已存在，保留 Photos 命名"
            }
            do {
                try FileManager.default.moveItem(atPath: currentPath, toPath: desiredPath)
                renamed = true
            } catch {
                return "无缝替换：物理改名失败（\(error.localizedDescription)），保留 Photos 命名"
            }
        }
        let target = renamed ? desired : info.filename
        switch ScreenshotSubtype.applySeamless(zpk: zpk, filename: target, sortToken: sourceInfo.sortToken) {
        case .success(let after):
            return "无缝替换：文件名 \(after.filename)、排序已带原图 token"
        case .failure(let error):
            if renamed {
                try? FileManager.default.moveItem(atPath: desiredPath, toPath: currentPath)
            }
            return "无缝替换：写库失败（\(error.localizedDescription)）" + (renamed ? "，已回滚改名" : "")
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

    /// 本机 ImageIO 的 HEIC 编码是否已被证明不可用。
    /// 自检实测：连代码生成的 8bit sRGB 图都编不出 HEIC（PNG/JPEG 正常），所以这是**设备级**结论，
    /// 一旦确认就跳过，省掉每张图两次注定失败的编码。
    private static var imageIOHEICUnusable = false

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
        // 让每张自检截图自证身份：版本号+剥离开关就在输出第一行，
        // 不再依赖可能被通知挡住、或读盘不读进程的表头。
        let selfBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("自检 build \(selfBuild) · 剥离in-band=\(HEIFWriter.Variant.appleLike.stripNonVCL)")
        let resolved = PhotoLibraryService.resolveWorkDirectory()
        lines.append("工作目录：\(resolved.url?.path ?? "无")　\(resolved.detail)")
        guard let directory = resolved.url else { return lines.joined(separator: "\n") }

        if let synthetic = PhotoLibraryService.syntheticImage() {
            lines.append("测试图：\(synthetic.width)×\(synthetic.height) \(synthetic.bitsPerComponent)bit alpha=\(synthetic.alphaInfo.rawValue)")
            lines.append(PhotoLibraryService.encodeProbe(synthetic, type: .png, in: directory, label: "生成图 → PNG "))
            lines.append(PhotoLibraryService.encodeProbe(synthetic, type: .jpeg, in: directory, label: "生成图 → JPEG"))
            lines.append(PhotoLibraryService.encodeProbe(synthetic, type: .heic, in: directory, label: "生成图 → HEIC"))

            /* 一次编码、多种容器写法逐个回读 —— 让设备自己找出"Apple 认哪一种"。
               自检实测：默认写法 ImageIO 读不回来，而系统 HEIC 读得回来，
               所以问题在容器细节上，不在编码器。 */
            lines.append("容器变体回读（ImageIO 能否读回）：")
            var readableVariant: String?
            for variant in HEIFWriter.Variant.candidates {
                let built = HEIFWriter.encode(synthetic, quality: 0.82, variant: variant)
                guard let data = built.data else {
                    lines.append("  ✗ \(variant.label)：构建失败（\(built.failure ?? "未知")）")
                    continue
                }
                let url = directory.appendingPathComponent(UUID().uuidString + ".heic")
                guard (try? data.write(to: url)) != nil else {
                    lines.append("  ✗ \(variant.label)：写文件失败")
                    continue
                }
                var shape = ""
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    shape = "（\(decoded.width)×\(decoded.height)）"
                }
                if !shape.isEmpty, readableVariant == nil { readableVariant = variant.label }
                lines.append("  \(shape.isEmpty ? "✗" : "✓") \(variant.label)\(shape)")
                if variant.label == HEIFWriter.Variant.candidates[0].label {
                    lines.append(HEIFWriter.describeContainer(data))
                }
                try? FileManager.default.removeItem(at: url)
            }
            if let readableVariant = readableVariant {
                lines.append("第一个能被读回的变体：\(readableVariant)")
            } else {
                lines.append("所有变体都读不回来 —— 不是这几个开关的差别")
            }
            lines.append(HEIFWriter.appleTileControl(in: directory))
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
        lines.append(PhotoLibraryService.heicDecodeControl(in: directory))
        return lines.joined(separator: "\n")
    }

    /// 对照：图库里已有的 HEIC（Live Photo / 之前转出来的）能不能解码。
    /// 用来区分两种情形：**我们的容器写坏了** 还是 **这台机器的 HEIC 解码本身就坏**。
    private static func heicDecodeControl(in directory: URL) -> String {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var found: PHAssetResource?
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, stop in
            if let resource = PHAssetResource.assetResources(for: asset).first(where: {
                $0.uniformTypeIdentifier.lowercased().contains("heic")
            }) {
                found = resource
                stop.pointee = true
            }
        }
        guard found != nil else { return "对照：图库里没找到 HEIC 资产" }

        var lines: [String] = []
        var checked = 0
        var inspected = 0
        let options2 = PHFetchOptions()
        options2.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        PHAsset.fetchAssets(with: options2).enumerateObjects { asset, _, _ in
            guard checked < 5, inspected < 300 else { return }
            inspected += 1
            guard let resource = PHAssetResource.assetResources(for: asset).first(where: {
                $0.uniformTypeIdentifier.lowercased().contains("heic")
            }) else { return }
            checked += 1
            let url = directory.appendingPathComponent(UUID().uuidString + ".heic")
            let semaphore = DispatchSemaphore(value: 0)
            var exported = false
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: nil) { error in
                exported = (error == nil)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 60)
            defer { try? FileManager.default.removeItem(at: url) }
            guard exported, let data = try? Data(contentsOf: url) else {
                lines.append("  \(resource.originalFilename)：导出失败")
                return
            }
            let shape = PhotoLibraryService.itemSummary(data)
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            let verdict = decoded.map { "解码通过（\($0.width)×\($0.height)）" } ?? "解码失败"
            lines.append("  \(resource.originalFilename) \(data.count)B \(shape)：\(verdict)")
        }
        return "对照（最近 \(checked) 个 HEIC）：\n" + lines.joined(separator: "\n")
    }

    /// 数一数文件里各类 item —— 用来区分"单 item"和"网格(grid)"结构
    static func itemSummary(_ data: Data) -> String {
        var counts: [String: Int] = [:]
        let needle = Data("infe".utf8)
        var searchStart = data.startIndex
        while let found = data.range(of: needle, in: searchStart..<data.endIndex) {
            let typeStart = found.lowerBound + 16          // size(4)+'infe'(4)+ver/flag(4)+item_ID(2)+protection(2)
            if typeStart + 4 <= data.count,
               let type = String(bytes: data[typeStart..<(typeStart + 4)], encoding: .ascii),
               type.range(of: "^[a-zA-Z0-9 ]{4}$", options: .regularExpression) != nil {
                counts[type, default: 0] += 1
            }
            searchStart = found.upperBound
        }
        if counts.isEmpty { return "结构未知" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.value)×\($0.key)" }.joined(separator: "+")
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

    /// 铺一层白底、重画成 8bit 并去掉 alpha 通道。
    /// HEIF 里没有 alpha；而且 16bit / 索引 / 非标准色彩空间的 PNG 也可能被编码器拒绝，
    /// 重画一遍能把这些一次性归到标准形态。源是 Display P3 就保留 P3（广色域截图不掉色），
    /// 其余归到 sRGB；像素缓冲与 colr 必须跟这里选的空间一致。
    private static func flattenedForHEIC(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let space: CGColorSpace
        if let source = image.colorSpace, source.name == CGColorSpace.displayP3 {
            space = source
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
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

            /* ImageIO 这条路：一旦确认不可用就跳过，别为每张图白跑两次注定失败的编码。
               判据是设备级的（自检里连代码生成的干净图都编不出 HEIC），不是单张文件的问题。 */
            if PhotoLibraryService.imageIOHEICUnusable {
                reasons.append("跳过 ImageIO（这台设备已确认编不出 HEIC）")
            } else {
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
                PhotoLibraryService.imageIOHEICUnusable = true
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
        let created = asset.creationDate
        let shouldDelete = self.deleteOriginals
        let shouldMarkScreenshot = self.writeScreenshotSubtype
        // 在 performChanges 之前取好文件名：change 块里不适合再访问图库
        let outputFilename = asset.originalFilenameForConversion
        let heifData = try? Data(contentsOf: heifURL)

        guard let heifData = heifData else {
            lastFailureReason = "读不出刚生成的 HEIF 文件：\(heifURL.path)"
            return false
        }

        /* 先带显式类型导入；被拒就退回"不指定 options"再试一次。
           自建容器不是 Apple 产的，两种方式哪种被 PhotoKit 接受，实测说了算 ——
           两次都失败时把两边的错误都带出来。 */
        var importError: String?
        for attempt in [true, false] {
            var identifier: String?
            var failure: String?
            let attemptSemaphore = DispatchSemaphore(value: 0)

            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                if let loc = loc { req.location = loc }
                req.isFavorite = fav
                // 带上原图创建时间，否则排序落到导入时刻、进错 moment
                if let created = created { req.creationDate = created }
                if attempt {
                    let resourceOptions = PHAssetResourceCreationOptions()
                    resourceOptions.uniformTypeIdentifier = "public.heic"
                    resourceOptions.originalFilename = outputFilename
                    req.addResource(with: .photo, data: heifData, options: resourceOptions)
                } else {
                    req.addResource(with: .photo, data: heifData, options: nil)
                }
                identifier = req.placeholderForCreatedAsset?.localIdentifier

                if let album = album, let placeholder = req.placeholderForCreatedAsset {
                    let albumChange = PHAssetCollectionChangeRequest(for: album)
                    albumChange?.addAssets([placeholder] as NSArray)
                }
            }) { changed, error in
                if changed && error == nil {
                    createdLocalIdentifier = identifier
                } else {
                    if let error = error as NSError? {
                        failure = "\(error.domain) \(error.code)：\(error.localizedDescription)"
                    } else {
                        failure = "没有错误对象，changed=\(changed)"
                    }
                }
                attemptSemaphore.signal()
            }

            _ = attemptSemaphore.wait(timeout: .now() + 120)
            if createdLocalIdentifier != nil { break }
            importError = (attempt ? "显式 public.heic：" : "不指定类型：") + (failure ?? "未知原因")
        }

        guard let newIdentifier = createdLocalIdentifier else {
            lastFailureReason = "导入照片库失败（\(importError ?? "未知原因")）"
            return false
        }
        convertSuccess = true

        if shouldMarkScreenshot {
            markAsScreenshot(source: asset, localIdentifier: newIdentifier)
        }

        if shouldDelete {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }) { deleted, error in
                if !deleted {
                    self.lastFailureReason = "导入成功，但删除原 PNG 失败："
                        + (error.map { $0.localizedDescription } ?? "未知原因")
                    convertSuccess = false
                }
                semaphore.signal()
            }
        } else {
            semaphore.signal()
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
            // 导入瞬间 Photos 的 WAL 可能还没落盘，重试几轮；仍查不到就返回 nil。
            // 有标识符时绝不退回"最新一行"——那会抓到上一个资产、把标记写错行。
            for _ in 0..<8 {
                if let pk = scalarInt64("SELECT Z_PK FROM ZASSET WHERE ZUUID = ?1 LIMIT 1", text: uuid) {
                    return pk
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return nil
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

    /// 无缝替换要用的三个字段：托管文件名、所在目录（相对 /var/mobile/Media）、排序 token。
    static func replacementInfo(zpk: Int64) -> (filename: String, directory: String, sortToken: Double)? {
        let (db, _) = open(SQLITE_OPEN_READONLY)
        guard let db = db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT IFNULL(ZFILENAME,''), IFNULL(ZDIRECTORY,''), IFNULL(ZSORTTOKEN,0) FROM ZASSET WHERE Z_PK = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, zpk)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (text(stmt, 0), text(stmt, 1), sqlite3_column_double(stmt, 2))
    }

    /// 一条 UPDATE 同时写文件名与排序 token（仍是一行），回读数据库真实值。
    static func applySeamless(zpk: Int64, filename: String,
                              sortToken: Double) -> Result<(filename: String, sortToken: Double), Failure> {
        let (db, error) = open(SQLITE_OPEN_READWRITE)
        guard let db = db else { return .failure(.message(error ?? "打开数据库失败")) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "UPDATE ZASSET SET ZFILENAME = ?1, ZSORTTOKEN = ?2 WHERE Z_PK = ?3"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failure(.message(String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, filename, -1, transient)
        sqlite3_bind_double(stmt, 2, sortToken)
        sqlite3_bind_int64(stmt, 3, zpk)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            return .failure(.message("更新失败：\(String(cString: sqlite3_errmsg(db)))"))
        }
        guard let after = replacementInfo(zpk: zpk) else {
            return .failure(.message("回读失败"))
        }
        return .success((after.filename, after.sortToken))
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
    static func encode(_ image: CGImage, quality: Float,
                       variant: Variant = .defaultVariant) -> (data: Data?, failure: String?) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return (nil, "尺寸无效（\(width)×\(height)）") }

        let pixels = makePixelBuffer(from: image)
        guard let pixelBuffer = pixels.buffer else {
            return (nil, "无法把图转成 CVPixelBuffer —— \(pixels.failure ?? "原因未知")")
        }

        let encoded = encodeHEVC(pixelBuffer, quality: quality, variant: variant)
        guard let stream = encoded.stream else {
            return (nil, encoded.reason ?? "VideoToolbox 编码失败")
        }
        guard !stream.config.isEmpty else { return (nil, "编码器没给出 hvcC 配置") }
        // Display P3 的 nclx primaries=12（SMPTE EG 432），sRGB/BT.709 用 1；transfer 都是 sRGB(13)
        let primaries: UInt16 = (image.colorSpace?.name == CGColorSpace.displayP3) ? 12 : 1
        return (buildContainer(width: width, height: height,
                               itemData: stream.data, hvcC: stream.config, variant: variant,
                               primaries: primaries), nil)
    }

    // MARK: - CGImage -> CVPixelBuffer

    /// 多组合尝试，并把**每一步的 CVReturn** 报出来。
    /// 先试不带附加属性的普通缓冲：这台机器的图形栈是坏的（CoreImage 建 GL 上下文会崩），
    /// 申请 IOSurface 有失败的风险，所以不能一上来就依赖它。
    private static func makePixelBuffer(from image: CGImage) -> (buffer: CVPixelBuffer?, failure: String?) {
        let width = image.width
        let height = image.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // 只保留 Display P3；灰度/索引/怪空间一律归 sRGB，否则 BGRA 位图上下文建不起来
        let space: CGColorSpace
        if let cs = image.colorSpace, cs.name == CGColorSpace.displayP3 { space = cs } else { space = srgb }

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
            // 告诉 VT 这块 RGB 缓冲的色彩空间，否则它按 sRGB/BT.709 转 YUV，P3 就丢了
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, space,
                                  .shouldPropagate)

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
                                          space: space,
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
                                   quality: Float,
                                   variant: Variant) -> (stream: (data: Data, config: Data)?, reason: String?) {
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
                                                     frameProperties: variant.forceKeyFrame
                                                         ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                                                         : nil,
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

    /// 容器写法的变体。默认那套是本机 ImageIO **解不开**的版本（自检实测 7 个组合全 ✗），
    /// 所以把开关都做成参数，让设备自己去试。
    ///
    /// 参照物：用户从设备导出的系统 HEIC（IMG_5690.HEIC，相机拍的 4032×3024）实测结构为
    ///   meta 子盒顺序 hdlr, dinf, pitm, iinf, iref, iprp, idat, iloc（**iloc 在最后**）
    ///   ipma 里 ispe / colr / hvcC **三者都标 essential**
    ///   hvcC 的 general_profile_idc = **3（Main Still Picture）**，而 VideoToolbox 给的是 Main
    ///   ftyp 兼容品牌 mif1, MiPr, miaf, MiHB, heic（五个）
    struct Variant {
        let label: String
        let ispeEssential: Bool
        let colrEssential: Bool
        let itemType: String
        let includeColr: Bool
        let includePixi: Bool
        let lengthPrefixed: Bool
        let includeDinf: Bool
        let ilocLast: Bool
        let markMainStill: Bool
        let appleBrands: Bool
        // 编码侧开关：容器试了一圈都无效，所以把嫌疑转向码流本身
        let forceKeyFrame: Bool
        // hvc1 的 item 里只许有 VCL 切片 NAL；参数集只能放在 hvcC。
        // Apple 自己的 HEIC 每个 item 就是一个长度前缀 IDR，ffmpeg 容忍 in-band
        // 参数集而 Apple 解码器不容忍 —— 这是 6 个容器变体全 ✗ 后唯一没试过的轴。
        var stripNonVCL: Bool = true

        /// 旧布局（只标 hvcC essential）—— 留作对照，自检里也保留
        static let legacyVariant = Variant(label: "旧布局（只标 hvcC essential，对照）",
                                           ispeEssential: false, colrEssential: false,
                                           itemType: "hvc1", includeColr: true, includePixi: true,
                                           lengthPrefixed: true, includeDinf: false, ilocLast: false,
                                           markMainStill: false, appleBrands: false, forceKeyFrame: true,
                                           stripNonVCL: false)

        /// 转换路径默认就用 Apple 式：既然实测是本机 ImageIO 解不开旧布局，
        /// 那就没有再拿旧布局去导入的道理
        static let defaultVariant = Variant(label: "Apple 式全套（dinf + iloc 后置 + ispe/colr/hvcC essential + MSP + 五个品牌）", ispeEssential: true, colrEssential: true,
                                            itemType: "hvc1", includeColr: true, includePixi: true,
                                            lengthPrefixed: true, includeDinf: true, ilocLast: true,
                                            markMainStill: true, appleBrands: true, forceKeyFrame: true)

        /// 照 Apple 那个文件的结构全套照做
        static let appleLike = Variant(label: "Apple 式全套（dinf + iloc 后置 + ispe/colr/hvcC essential + MSP + 五个品牌）",
                                       ispeEssential: true, colrEssential: true,
                                       itemType: "hvc1", includeColr: true, includePixi: true,
                                       lengthPrefixed: true, includeDinf: true, ilocLast: true,
                                       markMainStill: true, appleBrands: true, forceKeyFrame: true)

        /// 自检里逐个回读的组合：先试最可能的，再拆开单项定位
        static let candidates: [Variant] = [
            appleLike,
            Variant(label: "只把 hvcC 标成 MSP（Main Still Picture）", ispeEssential: false, colrEssential: false,
                    itemType: "hvc1", includeColr: true, includePixi: true, lengthPrefixed: true,
                    includeDinf: false, ilocLast: false, markMainStill: true, appleBrands: false, forceKeyFrame: true),
            Variant(label: "Apple 式布局，但不动 profile", ispeEssential: true, colrEssential: true,
                    itemType: "hvc1", includeColr: true, includePixi: true, lengthPrefixed: true,
                    includeDinf: true, ilocLast: true, markMainStill: false, appleBrands: true, forceKeyFrame: true),
            Variant(label: "只补 dinf + iloc 后置", ispeEssential: false, colrEssential: false,
                    itemType: "hvc1", includeColr: true, includePixi: true, lengthPrefixed: true,
                    includeDinf: true, ilocLast: true, markMainStill: false, appleBrands: false, forceKeyFrame: true),
            Variant(label: "只把 ispe + colr 也标 essential", ispeEssential: true, colrEssential: true,
                    itemType: "hvc1", includeColr: true, includePixi: true, lengthPrefixed: true,
                    includeDinf: false, ilocLast: false, markMainStill: false, appleBrands: false, forceKeyFrame: true),
            legacyVariant
        ]
    }


    /// 把容器/码流的要点打印出来 —— hvcC 里的参数集、码流第一个 NAL 的类型，
    /// 这些是 VideoToolbox 现场产生、我在这台机器上看不到的东西
    static func describeContainer(_ data: Data) -> String {
        var lines: [String] = []
        if let marker = data.range(of: Data("hvcC".utf8)), marker.upperBound + 24 <= data.count {
            let start = marker.upperBound
            let head = data[start..<min(start + 16, data.count)]
            lines.append("     hvcC 头: " + head.map { String(format: "%02x", $0) }.joined(separator: " "))
            let numArrays = Int(data[start + 22])
            var cursor = start + 23
            var described: [String] = []
            for _ in 0..<numArrays {
                guard cursor + 3 <= data.count else { break }
                let nalType = Int(data[cursor]) & 0x3F
                let count = Int(data[cursor + 1]) << 8 | Int(data[cursor + 2])
                cursor += 3
                var bytes = 0
                for _ in 0..<count {
                    guard cursor + 2 <= data.count else { break }
                    let length = Int(data[cursor]) << 8 | Int(data[cursor + 1])
                    bytes += length
                    cursor += 2 + length
                }
                described.append("NAL\(nalType)×\(count)(\(bytes)B)")
            }
            lines.append("     hvcC 参数集: " + described.joined(separator: ", "))
        } else {
            lines.append("     找不到 hvcC")
        }
        if let marker = data.range(of: Data("mdat".utf8)), marker.upperBound + 6 <= data.count {
            // 走完 mdat 里的所有 NAL —— 只有 SEI 没有 IDR 的话，文件根本解不了
            var cursor = marker.upperBound
            var nals: [String] = []
            while cursor + 5 <= data.count, nals.count < 8 {
                let length = Int(data[cursor]) << 24 | Int(data[cursor + 1]) << 16
                    | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
                guard length > 0, cursor + 4 + length <= data.count else { break }
                let nalType = (Int(data[cursor + 4]) >> 1) & 0x3F
                nals.append("类型\(nalType)(\(length)B)")
                cursor += 4 + length
            }
            lines.append("     mdat 里的 NAL: " + nals.joined(separator: ", ")
                + "（19/20=IDR、32=VPS、33=SPS、34=PPS、39=SEI）")
        }
        return lines.joined(separator: "\n")
    }

    /// 把码流从"4 字节长度前缀"转成裸 NAL 串（变体用）
    private static func stripLengthPrefixes(_ data: Data) -> Data {
        var out = Data()
        var offset = 0
        while offset + 4 <= data.count {
            let length = (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            let start = offset + 4
            guard length > 0, start + length <= data.count else { break }
            out.append(data[start..<(start + length)])
            offset = start + length
        }
        return out.isEmpty ? data : out
    }

    /// 只保留 VCL 切片 NAL（类型 < 32），丢掉 in-band 的 VPS/SPS/PPS/SEI，保留 4 字节长度前缀。
    /// 与本地 heif_proto.py 的 strip_non_vcl 同一套逻辑，已用 ffmpeg 验证剥离后仍可解码。
    private static func keepOnlyVCL(_ data: Data) -> Data {
        var out = Data()
        var offset = 0
        while offset + 4 <= data.count {
            let length = (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            let start = offset + 4
            guard length > 0, start + length <= data.count else { break }
            let nalType = (Int(data[start]) >> 1) & 0x3F
            if nalType < 32 { out.append(data[offset..<(start + length)]) }
            offset = start + length
        }
        return out.isEmpty ? data : out
    }

    // 二分对照：Apple 自己相机文件里一个能解码的瓦片码流 + Apple 的 hvcC，
    // 放进**我们的**容器写法。真机若解码失败 ⇒ 容器写法有缺陷；若通过 ⇒ 问题在 VT 码流/hvcC。
    static let appleTileB64 = "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"
    static let appleHvcCB64 = "AQNwAAAAsAAAAAAAWvAA/P34+AAACwOgAAEAF0ABDAH//wNwAAADALAAAAMAAAMAWnAkoQABACJCAQEDcAAAAwCwAAADAAADAFqgBAIAgFiHuRZVNwwBBgCAogABAAlEAcBhcshAUyQ="

    static func appleTileControl(in directory: URL) -> String {
        guard let tile = Data(base64Encoded: appleTileB64),
              let hvcc = Data(base64Encoded: appleHvcCB64) else { return "Apple瓦片对照：base64 解不开" }
        let data = buildContainer(width: 512, height: 512, itemData: tile, hvcC: hvcc, variant: .defaultVariant)
        let url = directory.appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return "Apple瓦片对照：写文件失败" }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        return "Apple码流+我们容器：" + (decoded.map { "解码通过（\($0.width)×\($0.height)）" } ?? "解码失败")
    }

    /// hvcC 第 1 个字节（configurationVersion 之后）是 general_profile_space(2) | tier(1) | profile_idc(5)。
    /// 单帧静止图本来就符合 Main Still Picture 的语义，所以把 idc 标成 3 是如实声明 ——
    /// Apple 自己的 HEIC 也是 idc=3，而 VideoToolbox 给的是 Main(1)。
    private static func markMainStillPicture(_ config: Data) -> Data {
        guard config.count > 2 else { return config }
        var patched = config
        let index = patched.startIndex + 1
        patched[index] = (patched[index] & 0xE0) | 0x03
        return patched
    }

    static func buildContainer(width: Int, height: Int, itemData: Data, hvcC: Data,
                               variant: Variant = .defaultVariant, primaries: UInt16 = 1) -> Data {
        // Apple 的 ftyp：major heic，兼容品牌五个（旧布局只用两个）——
        // 拆成循环写，Swift 的类型检查器会被一长串 `Data + Data` 拖垮（CI 实测）
        let compatibleBrands: [String] = variant.appleBrands
            ? ["mif1", "MiPr", "miaf", "MiHB", "heic"]
            : ["mif1", "heic"]
        var brandBytes = u32(0)
        for brand in compatibleBrands {
            if let encoded = brand.data(using: .ascii) { brandBytes.append(encoded) }
        }
        let ftyp = box("ftyp", "heic".data(using: .ascii)! + brandBytes)

        let ispe = fullBox("ispe", u32(UInt32(width)) + u32(UInt32(height)))
        let config = variant.markMainStill ? markMainStillPicture(hvcC) : hvcC
        let hvcCBox = box("hvcC", config)
        // nclx：primaries 由源色彩空间定（P3=12 / BT.709=1）/ sRGB transfer / BT.709 matrix / full range
        let colr = box("colr", "nclx".data(using: .ascii)! + u16(primaries) + u16(13) + u16(1) + u8(0x80))
        let pixi = fullBox("pixi", u8(3) + u8(8) + u8(8) + u8(8))

        var properties: [Data] = [ispe, hvcCBox]
        let ispeIndex: UInt8 = 1
        let hvcCIndex: UInt8 = 2
        var others: [(UInt8, Bool)] = []      // (index, essential)
        if variant.includeColr {
            properties.append(colr)
            others.append((UInt8(properties.count), variant.colrEssential))
        }
        if variant.includePixi {
            properties.append(pixi)
            others.append((UInt8(properties.count), false))
        }

        var associations: [UInt8] = []
        associations.append(variant.ispeEssential ? (0x80 | ispeIndex) : ispeIndex)
        associations.append(0x80 | hvcCIndex)
        for (index, essential) in others {
            associations.append(essential ? (0x80 | index) : index)
        }

        let ipco = box("ipco", properties.reduce(Data(), +))
        let ipma = fullBox("ipma", u32(1) + u16(1) + u8(UInt8(associations.count)) + Data(associations))
        let iprp = box("iprp", ipco + ipma)

        // infe 带 4 字符 item_type 必须 version 2；fullBox 固定 version 0 会把 hvc1 当成 item_name，item 不被识别为 HEVC
        let infe = box("infe", u8(2) + Data([0, 0, 0]) + u16(1) + u16(0) + variant.itemType.data(using: .ascii)! + u8(0))
        let iinf = fullBox("iinf", u16(1) + infe)
        let pitm = fullBox("pitm", u16(1))
        let hdlr = fullBox("hdlr", u32(0) + "pict".data(using: .ascii)! + Data(repeating: 0, count: 12) + u8(0))
        // Apple 的 dinf → dref → url（flags=1 表示数据就在本文件里），逐字节照抄
        let dinf = Data([0x00, 0x00, 0x00, 0x24, 0x64, 0x69, 0x6E, 0x66, 0x00, 0x00, 0x00, 0x1C,
                         0x64, 0x72, 0x65, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
                         0x00, 0x00, 0x00, 0x0C, 0x75, 0x72, 0x6C, 0x20, 0x00, 0x00, 0x00, 0x01])

        let cleaned = variant.stripNonVCL ? keepOnlyVCL(itemData) : itemData
        let payload = variant.lengthPrefixed ? cleaned : stripLengthPrefixes(cleaned)

        func iloc(offset: UInt32) -> Data {
            fullBox("iloc", Data([0x44, 0x40]) + u16(1) + u16(1) + u16(0) + u32(0)
                + u16(1) + u32(offset) + u32(UInt32(payload.count)))
        }

        func assemble(offset: UInt32) -> Data {
            var children = hdlr
            if variant.includeDinf { children.append(dinf) }
            children.append(pitm)
            if !variant.ilocLast { children.append(iloc(offset: offset)) }
            children.append(iinf)
            children.append(iprp)
            if variant.ilocLast { children.append(iloc(offset: offset)) }
            return ftyp + fullBox("meta", children)
        }

        // iloc 里是文件绝对偏移，所以先把 meta 量出来再定值（字段定长，长度不会变）
        let itemOffset = UInt32(assemble(offset: 0).count + 8)   // mdat 头 8 字节
        return assemble(offset: itemOffset) + box("mdat", payload)
    }
}

// MARK: - Naming

extension PHAsset {
    /// 源 PNG 的文件名，扩展名换成 .HEIC —— 导入时告诉 PhotoKit 该叫什么名字。
    /// 转换后的文件名会进 Photos.sqlite 的 ZFILENAME，「源图 ↔ 新资产」表靠它核对。
    var originalFilenameForConversion: String {
        let original = PHAssetResource.assetResources(for: self).first?.originalFilename ?? ""
        let base = (original as NSString).deletingPathExtension
        return (base.isEmpty ? UUID().uuidString : base) + ".HEIC"
    }
}
