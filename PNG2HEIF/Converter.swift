import Foundation
import Photos
import ImageIO
import VideoToolbox
import CoreVideo
import CoreMedia
import UniformTypeIdentifiers
import UIKit

final class ConverterModel: ObservableObject {
    @Published var pngCount = 0
    @Published var pngBytes: Int64 = 0
    @Published var running = false
    @Published var progress: Double = 0
    @Published var processed = 0
    @Published var total = 0
    @Published var status = ""

    @Published var onlyPNG = true
    @Published var keepCreationDate = true
    @Published var deleteOriginals = true
    @Published var addToAlbum = true

    private var assets: [PHAsset] = []

    func refresh() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            return
        }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let result = PHAsset.fetchAssets(with: opts)
        var list: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                list.append(asset)
            }
        }
        assets = list

        DispatchQueue.global(qos: .utility).async {
            var count = 0
            var bytes: Int64 = 0
            for asset in list {
                if let r = self.photoResource(for: asset),
                   r.uniformTypeIdentifier.lowercased().contains("png") {
                    count += 1
                    bytes += Int64(r.value(forKey: "fileSize") as? Int64 ?? 0)
                }
            }
            DispatchQueue.main.async {
                self.pngCount = count
                self.pngBytes = bytes
            }
        }
    }

    func start() {
        guard !running else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            status = "请先允许照片访问。"
            return
        }

        let candidates = assets.filter { asset in
            guard let r = photoResource(for: asset) else { return false }
            return !onlyPNG || r.uniformTypeIdentifier.lowercased().contains("png")
        }

        total = candidates.count
        processed = 0
        progress = 0
        running = true
        status = "准备转换…"

        Task.detached { [weak self] in
            guard let self else { return }
            var successAssets: [PHAsset] = []

            for asset in candidates {
                do {
                    let tempPNG = try await self.exportResource(asset)
                    let tempHEIC = try self.encodeHEIF(from: tempPNG, creationDate: self.keepCreationDate ? asset.creationDate : nil)
                    try await self.importHEIF(tempHEIC, sourceAsset: asset)
                    successAssets.append(asset)

                    try? FileManager.default.removeItem(at: tempPNG)
                    try? FileManager.default.removeItem(at: tempHEIC)

                    await MainActor.run {
                        self.processed += 1
                        self.progress = Double(self.processed) / Double(max(self.total, 1))
                        self.status = "已转换 \(self.processed) / \(self.total)"
                    }
                } catch {
                    await MainActor.run {
                        self.processed += 1
                        self.progress = Double(self.processed) / Double(max(self.total, 1))
                        self.status = "第 \(self.processed) 张失败：\(error.localizedDescription)"
                    }
                }
            }

            if self.deleteOriginals && !successAssets.isEmpty {
                do {
                    try await self.deleteAssets(successAssets)
                } catch {
                    await MainActor.run {
                        self.status = "转换完成，但删除原 PNG 失败：\(error.localizedDescription)"
                    }
                }
            }

            await MainActor.run {
                self.running = false
                if self.status.hasPrefix("第 ") == false && self.status.hasPrefix("转换完成") == false {
                    self.status = "完成：\(self.processed) 张。"
                } else if self.deleteOriginals && !successAssets.isEmpty && !self.status.contains("失败") {
                    self.status = "完成：转换 \(successAssets.count) 张并删除原 PNG。"
                }
                self.refresh()
            }
        }
    }

    private func photoResource(for asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first(where: {
            $0.type == .photo || $0.type == .fullSizePhoto
        }) ?? PHAssetResource.assetResources(for: asset).first
    }

    private func exportResource(_ asset: PHAsset) async throws -> URL {
        guard let resource = photoResource(for: asset) else { throw ConverterError.noResource }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")

        try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return url
    }

    private func encodeHEIF(from input: URL, creationDate: Date?) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConverterError.decodeFailed
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw ConverterError.destinationFailed
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if let date = creationDate {
            properties[kCGImagePropertyExifDictionary] = {
                var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
                let formatter = ISO8601DateFormatter()
                exif[kCGImagePropertyExifDateTimeOriginal] = formatter.string(from: date)
                exif[kCGImagePropertyExifDateTimeDigitized] = formatter.string(from: date)
                return exif
            }()
        }
        properties[kCGImageDestinationMergeMetadata] = true

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConverterError.encodeFailed
        }
        return output
    }

    private func importHEIF(_ url: URL, sourceAsset: PHAsset) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                guard let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) else {
                    return
                }
                if self.keepCreationDate {
                    request.creationDate = sourceAsset.creationDate
                }
                if let location = sourceAsset.location {
                    request.location = location
                }
                if sourceAsset.isFavorite {
                    request.favorite = true
                }

                if self.addToAlbum, let album = self.fetchOrCreateAlbum() {
                    let albumRequest = PHAssetCollectionChangeRequest(for: album)
                    if let placeholder = request.placeholderForCreatedAsset {
                        albumRequest?.addAssets([placeholder] as NSArray)
                    }
                }
            }) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: ConverterError.photosWriteFailed) }
            }
        }
    }

    private func fetchOrCreateAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", "HEIF截图")
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject {
            return existing
        }

        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChangesAndWait {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "HEIF截图")
            placeholder = request.placeholderForCreatedAsset
        }
        guard let id = placeholder?.localIdentifier else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func deleteAssets(_ assets: [PHAsset]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: ConverterError.deleteFailed) }
            }
        }
    }
}

enum ConverterError: LocalizedError {
    case noResource, decodeFailed, destinationFailed, encodeFailed
    case photosWriteFailed, deleteFailed

    var errorDescription: String? {
        switch self {
        case .noResource: return "找不到照片资源"
        case .decodeFailed: return "无法读取 PNG"
        case .destinationFailed: return "无法创建 HEIF 编码器"
        case .encodeFailed: return "HEIF 编码失败"
        case .photosWriteFailed: return "写入照片库失败"
        case .deleteFailed: return "删除原 PNG 失败"
        }
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

        guard let pixelBuffer = makePixelBuffer(from: image) else {
            return (nil, "无法把图转成 CVPixelBuffer")
        }

        switch encodeHEVC(pixelBuffer, quality: quality) {
        case .failure(let reason):
            return (nil, reason)
        case .success(let stream):
            guard !stream.config.isEmpty else { return (nil, "编码器没给出 hvcC 配置") }
            return (buildContainer(width: width, height: height,
                                   itemData: stream.data, hvcC: stream.config), nil)
        }
    }

    // MARK: - CGImage -> CVPixelBuffer

    private static func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    // MARK: - VideoToolbox

    /// 回调里要收集结果，而 C 函数指针捕获不了上下文，所以用 refcon 传一个盒子过去
    private final class Sink {
        var status: OSStatus = noErr
        var sample: CMSampleBuffer?
    }

    private static func encodeHEVC(_ pixelBuffer: CVPixelBuffer,
                                   quality: Float) -> Result<(data: Data, config: Data), String> {
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
            return .failure("VideoToolbox 创建会话失败（OSStatus \(created)）")
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
            return .failure("VideoToolbox Prepare 失败（OSStatus \(prepared)）")
        }

        let encoded = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: CMTime(value: 0, timescale: 1),
                                                     duration: .invalid,
                                                     frameProperties: nil,
                                                     sourceFrameRefcon: nil,
                                                     infoFlagsOut: nil)
        guard encoded == noErr else {
            return .failure("VideoToolbox 提交帧失败（OSStatus \(encoded)）")
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        guard sink.status == noErr, let sample = sink.sample else {
            return .failure("VideoToolbox 没有输出帧（OSStatus \(sink.status)）")
        }
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let atoms = CMFormatDescriptionGetExtension(
                  format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
              ) as? [String: Any],
              let config = atoms["hvcC"] as? Data else {
            return .failure("拿不到 hvcC 配置（编码器没附带 sample description）")
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            return .failure("编码结果为空")
        }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let read = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                               totalLengthOut: &length, dataPointerOut: &pointer)
        guard read == kCMBlockBufferNoErr, let start = pointer, length > 0 else {
            return .failure("读不出编码数据（OSStatus \(read)）")
        }
        return .success((Data(bytes: start, count: length), config))
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
