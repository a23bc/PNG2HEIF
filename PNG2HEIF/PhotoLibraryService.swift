import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit
import Combine

final class PhotoLibraryService: ObservableObject {
    @Published var pngCount = 0
    @Published var pngSize: Int64 = 0
    @Published var processed = 0
    @Published var total = 0
    @Published var progress = 0.0
    @Published var status = "等待扫描"
    @Published var isWorking = false
    @Published var deleteOriginals = false
    @Published var onlyPNG = true
    @Published var alert: AlertItem?

    private var assets: [PHAsset] = []
    private let workerQueue = DispatchQueue(label: "PNG2HEIF.worker", qos: .userInitiated)

    /// 用于取消转换的标志
    private var shouldStop = false

    var pngSizeText: String {
        ByteCountFormatter.string(fromByteCount: pngSize, countStyle: .file)
    }

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

            let options = PHFetchOptions()
            options.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: true)
            ]

            // 只获取图片资产；随后通过资源类型/UTI 判断 PNG。
            let result = PHAsset.fetchAssets(with: .image, options: options)

            var found: [PHAsset] = []
            var totalSize: Int64 = 0

            result.enumerateObjects { asset, _, _ in
                guard self.isPNG(asset: asset) else { return }
                found.append(asset)
                totalSize += self.estimatedPNGSize(asset: asset)
            }

            DispatchQueue.main.async {
                self.assets = found
                self.pngCount = found.count
                self.pngSize = totalSize
                self.total = found.count
                self.processed = 0
                self.progress = 0
                self.status = "找到 \(found.count) 张 PNG"
            }
        }
    }

    /// 停止当前转换任务
    func stopConversion() {
        shouldStop = true
        DispatchQueue.main.async { [weak self] in
            self?.status = "正在停止…"
        }
    }

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

                var success = 0
                var failures = 0

                for asset in work {
                    // 每张图转换前检查是否已请求停止
                    if self.shouldStop {
                        break
                    }

                    autoreleasepool {
                        let ok = self.convert(asset: asset, to: album)
                        if ok { success += 1 } else { failures += 1 }

                        DispatchQueue.main.async {
                            self.processed += 1
                            self.progress = Double(self.processed) / Double(max(self.total, 1))
                            self.status = "已处理 \(self.processed) / \(self.total)"
                        }
                    }
                }

                if self.shouldStop {
                    self.finish(message: "已停止：成功 \(success) 张，失败 \(failures) 张，跳过 \(work.count - success - failures) 张。")
                } else {
                    self.finish(message: "完成：成功 \(success) 张，失败 \(failures) 张。")
                }
            }
        }
    }

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

    private func convert(asset: PHAsset, to album: PHAssetCollection) -> Bool {
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

        // ✅ 修复：设置 isNetworkAccessAllowed = true，
        //    确保 iCloud 未下载到本地的图片也能正常导出。
        let exportOptions = PHAssetResourceRequestOptions()
        exportOptions.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: inputURL, options: exportOptions) { [weak self] error in
            if let error = error {
                print("[PNG2HEIF] writeData 失败: \(error.localizedDescription)")
                semaphore.signal()
                return
            }

            guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("[PNG2HEIF] 解码 PNG 失败")
                semaphore.signal()
                return
            }

            let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else {
                print("[PNG2HEIF] 创建 HEIC destination 失败")
                semaphore.signal()
                return
            }

            var properties = metadata ?? [:]
            // HEIF 使用无损质量参数以尽量避免截图文字/图形出现明显损失。
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0

            CGImageDestinationAddImage(destination, image, properties as CFDictionary)

            guard CGImageDestinationFinalize(destination) else {
                print("[PNG2HEIF] HEIC 编码失败")
                semaphore.signal()
                return
            }

            PHPhotoLibrary.shared().performChanges({
                guard let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: outputURL) else {
                    return
                }

                if let date = asset.creationDate {
                    request.creationDate = date
                }
                if let location = asset.location {
                    request.location = location
                }
                request.isFavorite = asset.isFavorite

                let placeholder = request.placeholderForCreatedAsset
                if let placeholder = placeholder {
                    let albumChange = PHAssetCollectionChangeRequest(for: album)
                    albumChange?.addAssets([placeholder] as NSArray)
                }
            }) { [weak self] changed, error in
                if changed && error == nil {
                    convertSuccess = true

                    if self?.deleteOriginals == true {
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

        // ✅ 修复：使用 .distantFuture 超时，防止信号量永久阻塞。
        //    正常情况下 completion 一定会回调；超时只是兜底安全网。
        let timeoutResult = semaphore.wait(timeout: .now() + 120)
        if timeoutResult == .timedOut {
            print("[PNG2HEIF] 单张转换超时，跳过")
            return false
        }

        return convertSuccess
    }

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
