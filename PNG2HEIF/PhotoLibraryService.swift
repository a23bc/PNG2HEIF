import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit
import Combine

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

    // MARK: - Private

    private var assets: [PHAsset] = []
    private var shouldStop = false
    private let workerQueue = DispatchQueue(label: "PNG2HEIF.worker", qos: .userInitiated)
    /// 样本转换得到的压缩比（HEIF 大小 / PNG 大小），用于估算总体积
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

            // 在后台线程计算总大小（需要读取每个 asset 的 resource fileSize）
            for asset in found {
                totalSize += self.estimatedPNGSize(asset: asset)
            }

            // 样本转换：取中间那张做一次实际编码，得到真实压缩比
            let ratio = self.computeSampleRatio(assets: found)

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

        let work = assets
        isWorking = true
        shouldStop = false
        processed = 0
        total = work.count
        progress = 0
        status = "开始转换…"

        workerQueue.async { [weak self] in
            guard let self = self else { return }

            self.ensureAlbum(named: "HEIF截图") { album in
                guard let album = album else {
                    self.finish(message: "无法创建或访问 HEIF截图 相簿")
                    return
                }

                var successCount = 0
                var failCount = 0

                for asset in work {
                    if self.shouldStop { break }

                    autoreleasepool {
                        let ok = self.convertOne(asset: asset, to: album)
                        if ok {
                            successCount += 1
                        } else {
                            failCount += 1
                        }

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
                    self.finish(
                        message: "已停止：成功 \(successCount) 张，失败 \(failCount) 张，跳过 \(skipped) 张。"
                    )
                } else {
                    self.finish(
                        message: "完成：成功 \(successCount) 张，失败 \(failCount) 张。"
                    )
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

    /// 取一张有代表性的样本做实际 PNG→HEIF 编码，返回压缩比
    private func computeSampleRatio(assets: [PHAsset]) -> Float {
        // 优先取中间位置的图（避免第一张太小或最后一张太特殊）
        let index = min(max(assets.count / 2, 0), assets.count - 1)
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
                outputURL as CFURL,
                UTType.heic.identifier as CFString,
                1, nil
            ) else {
                semaphore.signal()
                return
            }

            let props: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality
            ]
            CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
            CGImageDestinationFinalize(dest)

            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
               let size = attrs[.size] as? Int64 {
                heifSize = size
            }
            semaphore.signal()
        }

        semaphore.wait(timeout: .now() + 30)
        let ratio = Float(heifSize) / Float(pngSize)
        // 限制在合理范围
        return (0.01...1.0).clamp(ratio)
    }

    // MARK: - Private: Single Asset Conversion

    private func convertOne(asset: PHAsset, to album: PHAssetCollection) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var convertSuccess = false

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            let uti = $0.uniformTypeIdentifier.lowercased()
            return uti == "public.png" || uti.contains("png") || $0.originalFilename.lowercased().hasSuffix(".png")
        }) else {
            return false
        }

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".heic")

        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        // ✅ 关键修复：允许从 iCloud 下载
        let exportOptions = PHAssetResourceRequestOptions()
        exportOptions.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: inputURL, options: exportOptions) { [weak self] error in
            if let error = error {
                print("[PNG2HEIF] writeData 失败: \(error.localizedDescription)")
                semaphore.signal()
                return
            }

            // ---- 读取原始图片 ----
            guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("[PNG2HEIF] 解码 PNG 失败")
                semaphore.signal()
                return
            }

            // ---- 提取原始元数据 ----
            var metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

            // ---- 编码 HEIF ----
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.heic.identifier as CFString,
                1, nil
            ) else {
                print("[PNG2HEIF] 创建 HEIC destination 失败")
                semaphore.signal()
                return
            }

            // ✅ 质量控制：默认 0.82，与 iOS 快捷指令的输出体积接近
            //    截图以文字/线条为主，0.82 几乎无损但体积远小于 1.0
            metadata[kCGImageDestinationLossyCompressionQuality] = self?.compressionQuality ?? 0.82

            // ✅✅ 关键修复：将原始日期写入 HEIF 文件的 EXIF 元数据
            //    仅设 request.creationDate 不够——Photos 导入文件时会读取文件内嵌的
            //    EXIF DateTimeOriginal，如果缺失就用「当前时间」，导致出现在最新位置。
            //    必须在编码前把日期写进文件本身。
            if self?.keepCreationDate == true, let originalDate = asset.creationDate {
                let exifFormatter = DateFormatter()
                exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                let dateString = exifFormatter.string(from: originalDate)

                var exif = (metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
                exif[kCGImagePropertyExifDateTimeOriginal] = dateString
                exif[kCGImagePropertyExifDateTimeDigitized] = dateString
                metadata[kCGImagePropertyExifDictionary] = exif

                // 也写入 TIFF 字典（部分读取器会从这里取日期）
                var tiff = (metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
                tiff[kCGImagePropertyTIFFDateTime] = dateString
                metadata[kCGImagePropertyTIFFDictionary] = tiff
            }

            CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)

            guard CGImageDestinationFinalize(destination) else {
                print("[PNG2HEIF] HEIC 编码失败")
                semaphore.signal()
                return
            }

            // ✅✅ 三重保险：给文件本身也打上正确的时间戳
            //    Photos 导入时可能会读取文件系统时间作为 fallback
            if self?.keepCreationDate == true, let originalDate = asset.creationDate {
                try? FileManager.default.setAttributes([
                    .creationDate: originalDate,
                    .modificationDate: originalDate
                ], ofItemAtPath: outputURL.path)
            }

            // ---- 写入照片库 ----
            // ✅✅ 关键改动：用 PHAssetCreationRequest 替代 creationRequestForAssetFromImage
            //    后者创建的资产，Photos 内部会忽略 request.creationDate，
            //    改用导入时间或文件系统时间作为「最近项目」排序依据。
            //    PHAssetCreationRequest.forAsset() 对 creationDate 的控制更直接。
            let originalDate = asset.creationDate
            let shouldKeepDate = self?.keepCreationDate ?? true
            let loc = asset.location
            let fav = asset.isFavorite
            let shouldDelete = self?.deleteOriginals ?? false
            let heifData = try? Data(contentsOf: outputURL)

            guard let heifData = heifData else {
                print("[PNG2HEIF] 读取 HEIF Data 失败")
                semaphore.signal()
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()

                // ① 设置 creationDate
                if shouldKeepDate, let date = originalDate {
                    creationRequest.creationDate = date
                }
                // 保留位置
                if let loc = loc {
                    creationRequest.location = loc
                }
                // 保留收藏
                creationRequest.isFavorite = fav

                // ② 以 resource 方式写入文件数据（而非 fromFileURL）
                let resOpts = PHAssetResourceCreationOptions()
                resOpts.isOriginal = true
                creationRequest.addResource(with: .photo, data: heifData, options: resOpts)

                // 加入相簿
                let placeholder = creationRequest.placeholderForCreatedAsset
                if let placeholder = placeholder {
                    let albumChange = PHAssetCollectionChangeRequest(for: album)
                    albumChange?.addAssets([placeholder] as NSArray)
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
        }

        // ✅ 超时保护：防止任何异常导致线程永久阻塞
        let timeoutResult = semaphore.wait(timeout: .now() + 120)
        if timeoutResult == .timedOut {
            print("[PNG2HEIF] 单张转换超时，跳过")
            return false
        }

        return convertSuccess
    }

    // MARK: - Private: Album

    private func ensureAlbum(named name: String, completion: @escaping (PHAssetCollection?) -> Void) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", name)

        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: options
        )

        if let found = fetch.firstObject {
            completion(found)
            return
        }

        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        }) { [weak self] success, _ in
            guard success, let id = placeholder?.localIdentifier else {
                completion(nil)
                return
            }
            let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
            completion(result.firstObject)
            self?.status = "已准备 HEIF截图 相簿"
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

// MARK: - Float Clamp Extension

extension ClosedRange where Bound: Comparable {
    func clamp(_ value: Bound) -> Bound {
        return min(max(value, lowerBound), upperBound)
    }
}