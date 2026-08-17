import Foundation
import Photos
import ImageIO
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