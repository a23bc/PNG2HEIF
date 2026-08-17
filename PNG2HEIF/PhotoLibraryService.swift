import Foundation
import Photos
import ImageIO
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
    private let queue = DispatchQueue(label: "PNG2HEIF.serial", qos: .userInitiated)
    private var stopRequested = false

    var pngSizeText: String {
        ByteCountFormatter.string(fromByteCount: pngSize, countStyle: .file)
    }

    func requestAuthorizationAndScan() {
        let handler: (PHAuthorizationStatus) -> Void = { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    self?.status = "没有照片图库访问权限"
                    return
                }
                self?.scan()
            }
        }

        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: handler)
        } else {
            PHPhotoLibrary.requestAuthorization(handler)
        }
    }

    func scan() {
        guard !isWorking else { return }

        queue.async { [weak self] in
            guard let self = self else { return }

            let options = PHFetchOptions()
            options.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: true)
            ]

            let result = PHAsset.fetchAssets(with: .image, options: options)
            var found: [PHAsset] = []
            var size: Int64 = 0

            result.enumerateObjects { asset, _, _ in
                if self.isPNG(asset: asset) {
                    found.append(asset)
                    size += self.estimatedSize(asset: asset)
                }
            }

            DispatchQueue.main.async {
                self.assets = found
                self.pngCount = found.count
                self.pngSize = size
                self.total = found.count
                self.processed = 0
                self.progress = 0
                self.status = "找到 \(found.count) 张 PNG"
            }
        }
    }

    func startConversion() {
        guard !isWorking, !assets.isEmpty else { return }

        let work = assets
        stopRequested = false

        DispatchQueue.main.async {
            self.isWorking = true
            self.processed = 0
            self.total = work.count
            self.progress = 0
            self.status = "正在准备 HEIF截图 相簿…"
        }

        ensureAlbum(named: "HEIF截图") { [weak self] album in
            guard let self = self else { return }

            guard let album = album else {
                self.finish("无法创建或访问 HEIF截图 相簿", showAlert: true)
                return
            }

            self.queue.async {
                var success = 0
                var failures = 0

                for (index, asset) in work.enumerated() {
                    if self.stopRequested {
                        break
                    }

                    DispatchQueue.main.async {
                        self.status = "正在转换 \(index + 1) / \(work.count)"
                    }

                    let ok = self.convertOne(asset: asset, album: album)

                    if ok {
                        success += 1
                    } else {
                        failures += 1
                    }

                    DispatchQueue.main.async {
                        self.processed = index + 1
                        self.progress = Double(index + 1) / Double(max(work.count, 1))
                    }
                }

                let stopped = self.stopRequested
                let message: String
                if stopped {
                    message = "已停止：完成 \(success) 张，失败 \(failures) 张，剩余未处理。"
                } else {
                    message = "完成：成功 \(success) 张，失败 \(failures) 张。"
                }

                self.finish(message, showAlert: true)
            }
        }
    }

    func stop() {
        guard isWorking else { return }
        stopRequested = true
        DispatchQueue.main.async {
            self.status = "正在停止，当前图片处理完成后停止…"
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

    private func estimatedSize(asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let value = resources.first?.value(forKey: "fileSize") else { return 0 }
        if let number = value as? NSNumber { return number.int64Value }
        return 0
    }

    private func convertOne(asset: PHAsset, album: PHAssetCollection) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            let uti = $0.uniformTypeIdentifier.lowercased()
            let filename = $0.originalFilename.lowercased()
            return uti == "public.png" || uti.contains("png") || filename.hasSuffix(".png")
        }) else {
            return false
        }

        let dir = FileManager.default.temporaryDirectory
        let inputURL = dir.appendingPathComponent(UUID().uuidString + ".png")
        let outputURL = dir.appendingPathComponent(UUID().uuidString + ".heic")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        if !writeResource(resource, to: inputURL) {
            return false
        }

        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                "public.heic" as CFString,
                1,
                nil
              ) else {
            return false
        }

        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return false
        }

        // Don't delete the original until Photos confirms the new asset exists.
        return saveHEIFAndOptionallyDelete(
            outputURL: outputURL,
            sourceAsset: asset,
            album: album
        )
    }

    private func writeResource(_ resource: PHAssetResource, to url: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
            ok = (error == nil)
            semaphore.signal()
        }

        // The resource operation itself is asynchronous. We wait only for this
        // single file, then return to the serial conversion queue.
        semaphore.wait()
        return ok
    }

    private func saveHEIFAndOptionallyDelete(
        outputURL: URL,
        sourceAsset: PHAsset,
        album: PHAssetCollection
    ) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var created = false
        var deletionFinished = false

        PHPhotoLibrary.shared().performChanges({
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: outputURL) else {
                return
            }

            request.creationDate = sourceAsset.creationDate
            request.location = sourceAsset.location
            request.isFavorite = sourceAsset.isFavorite

            if let placeholder = request.placeholderForCreatedAsset {
                let albumRequest = PHAssetCollectionChangeRequest(for: album)
                albumRequest?.addAssets([placeholder] as NSArray)
            }
        }) { [weak self] success, error in
            guard success, error == nil else {
                semaphore.signal()
                return
            }

            created = true

            guard self?.deleteOriginals == true else {
                deletionFinished = true
                semaphore.signal()
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([sourceAsset] as NSArray)
            }) { deleted, _ in
                deletionFinished = deleted
                semaphore.signal()
            }
        }

        semaphore.wait()
        return created && deletionFinished || (created && deleteOriginals == false)
    }

    private func ensureAlbum(named name: String, completion: @escaping (PHAssetCollection?) -> Void) {
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )

        var existing: PHAssetCollection?
        fetch.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == name {
                existing = collection
                stop.pointee = true
            }
        }

        if let existing = existing {
            completion(existing)
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

            let result = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id],
                options: nil
            )
            completion(result.firstObject)
        }
    }

    private func finish(_ message: String, showAlert: Bool) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.status = message
            if showAlert {
                self.alert = AlertItem(title: "PNG → HEIF", message: message)
            }
            self.scan()
        }
    }
}
