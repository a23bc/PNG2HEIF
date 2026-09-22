import SwiftUI
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - In-app photo picker

/// 应用内选图。用 PHPicker（在进程内运行，不需要额外授权弹窗）。
/// configuration 带 `photoLibrary: .shared()` 才会有 `assetIdentifier` ——
/// 靠它把选中的图对应回 PHAsset，后面才能按 localIdentifier 在 Photos.sqlite 里找到对应的行。
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: ([String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0                                    // 0 = 不限张数
        configuration.preferredAssetRepresentationMode = .current           // 不要重新编码
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([String]) -> Void
        init(onPick: @escaping ([String]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            // 没有 assetIdentifier 的那些（例如从 iCloud 分享进来的）会被丢掉，
            // 这里如实报数量，别让人以为全都选上了。
            let identifiers = results.compactMap { $0.assetIdentifier }
            onPick(identifiers)
        }
    }
}

// MARK: - Folder Picker

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: false — 我们要拿到真实目录路径，不要副本
        // 用「打开文件夹」模式，而不是 forExporting（那个会显示「移动」按钮）
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate, UINavigationControllerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // 持有 security-scoped 权限，交给调用方管理生命周期
            _ = url.startAccessingSecurityScopedResource()
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var service = PhotoLibraryService()
    @AppStorage("deleteOriginals") private var deleteOriginals = false
    @AppStorage("writeScreenshotSubtype") private var writeScreenshotSubtype = false
    @State private var showFolderPicker = false
    @State private var showPhotoPicker = false
    @State private var showClearConfirm = false
    @State private var copyNote: String?

    /// 一键复制的诊断信息：把面板上看到的东西攒成一段文本
    private func diagnosticsText() -> String {
        var lines: [String] = []
        lines.append("== 照片库数据库 ==")
        lines.append(service.subtypeProbe)
        if !service.environmentProbe.isEmpty {
            lines.append("")
            lines.append("== 运行环境 ==")
            lines.append(service.environmentProbe)
        }
        lines.append("")
        lines.append("== 选择器 ==")
        lines.append(service.lastPickerReport.isEmpty ? "(未使用)" : service.lastPickerReport)
        lines.append("")
        lines.append("== 最近几行 ==")
        for row in service.subtypeRows.prefix(12) {
            lines.append("Z_PK=\(row.zpk) kind=\(row.kindSubtype) cloud=\(row.cloudKindSubtype) \(row.filename) \(row.addedAt)")
        }
        if let last = service.subtypeLastResult {
            lines.append("")
            lines.append("== 最近一次写入 ==")
            lines.append(last)
        }
        return lines.joined(separator: "\n")
    }

    /// 对应表里一行的说明文字
    private func pairingDetail(_ entry: PairingEntry) -> String {
        if let note = entry.note { return note }
        let zpk = entry.zpk.map { "Z_PK=\($0)" } ?? "Z_PK=?"
        let name = entry.newFilename.map { "  \($0)" } ?? ""
        let kinds = "kind \(entry.before ?? -1) → \(entry.after ?? -1)"
        let uuid = entry.uuidMatched ? "UUID 吻合" : "UUID 不吻合"
        return "\(zpk)\(name)   \(kinds)   \(uuid)"
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    var body: some View {
        NavigationView {
            Form {
                // MARK: - 扫描结果
                Section {
                    HStack {
                        Text("待转换 PNG")
                        Spacer()
                        Text("\(service.pngCount) 张")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    if service.skippedCount > 0 {
                        HStack {
                            Text("已跳过（历史记录）")
                            Spacer()
                            Text("\(service.skippedCount) 张")
                                .foregroundColor(.orange)
                                .monospacedDigit()
                        }
                    }
                    if service.historyCount > 0 {
                        HStack {
                            Text("累计已转换")
                            Spacer()
                            Text("\(service.historyCount) 张")
                                .foregroundColor(.green)
                                .monospacedDigit()
                        }
                    }
                    if service.totalSizeSaved > 0 {
                        HStack {
                            Text("已节省空间")
                            Spacer()
                            Text(service.savedSizeText)
                                .foregroundColor(.green)
                                .fontWeight(.medium)
                        }
                    }
                } header: {
                    Text("照片图库")
                } footer: {
                    if service.historyCount > 0 {
                        Button("清除转换记录（重新扫描全部 PNG）") {
                            showClearConfirm = true
                        }
                        .foregroundColor(.red)
                        .font(.footnote)
                    }
                }
                .alert("确认清除", isPresented: $showClearConfirm) {
                    Button("取消", role: .cancel) {}
                    Button("清除", role: .destructive) {
                        service.clearHistory()
                    }
                } message: {
                    Text("将清除所有转换记录，下次扫描会重新发现所有 PNG 截图。已转换的文件不会被撤回。")
                }

                // MARK: - 导出位置
                Section {
                    Picker("导出到", selection: $service.exportMode) {
                        ForEach(ExportMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .onChange(of: service.exportMode) { _ in
                        if service.exportMode != .folder {
                            service.exportFolderURL = nil
                            service.exportFolderName = nil
                        }
                    }

                    if service.exportMode == .album {
                        if service.userAlbums.isEmpty {
                            Text("没有用户相簿")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Picker("选择相簿", selection: $service.selectedAlbumID) {
                                Text("请选择").tag(String?.none)
                                ForEach(service.userAlbums) { album in
                                    HStack {
                                        Text(album.title)
                                        Spacer()
                                        Text("\(album.count) 张")
                                            .foregroundColor(.secondary)
                                        Text(Image(systemName: "chevron.right"))
                                            .foregroundColor(.secondary)
                                    }
                                    .tag(Optional(album.id))
                                }
                            }
                        }
                    }

                    if service.exportMode == .newAlbum {
                        TextField("相簿名称", text: $service.newAlbumName)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onSubmit { hideKeyboard() }
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("完成") { hideKeyboard() }
                                }
                            }
                    }

                    if service.exportMode == .folder {
                        Button {
                            showFolderPicker = true
                        } label: {
                            HStack {
                                Label("选择文件夹", systemImage: "folder.badge.plus")
                                Spacer()
                                if let name = service.exportFolderName {
                                    Text(name)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Text(Image(systemName: "chevron.right"))
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("未选择")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if let name = service.exportFolderName {
                            Text("HEIF 文件将保存到：\(name)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("导出位置")
                } footer: {
                    switch service.exportMode {
                    case .library:
                        Text("直接保存到照片图库，不放入任何相簿")
                    case .album:
                        Text("保存到已有相簿中")
                    case .newAlbum:
                        Text("自动创建新相簿并保存")
                    case .folder:
                        Text("导出为 HEIF 文件到「文件」App 中的指定文件夹，不经过照片图库")
                    }
                }

                // MARK: - 转换选项
                Section {
                    Toggle("转换成功后删除 PNG", isOn: $deleteOriginals)
                        .onChange(of: deleteOriginals) { newValue in
                            service.deleteOriginals = newValue
                        }

                    Toggle("转换后写入截图标记（ZKINDSUBTYPE=10）", isOn: $writeScreenshotSubtype)
                        .onChange(of: writeScreenshotSubtype) { newValue in
                            service.writeScreenshotSubtype = newValue
                        }

                    if #available(iOS 15, *) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("压缩质量")
                                Spacer()
                                Text("\(Int(service.compressionQuality * 100))%")
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            HStack {
                                Text("更小")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Slider(value: $service.compressionQuality, in: 0.5...1.0, step: 0.01)
                                Text("更清晰")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("0.82 接近 iOS 原生转换效果，截图推荐 0.75-0.85")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("选项")
                }

                // MARK: - 操作按钮
                Section {
                    Button {
                        service.scan()
                    } label: {
                        Label("扫描图库", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(service.isWorking)

                    if !service.isWorking {
                        Button {
                            service.startConversion()
                        } label: {
                            Label("开始转换", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(service.pngCount == 0)
                        .tint(.blue)
                    } else {
                        Button(role: .destructive) {
                            service.stopConversion()
                        } label: {
                            Label("停止转换", systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.red)
                    }
                }

                // MARK: - 进度
                if service.isWorking {
                    Section {
                        VStack(spacing: 8) {
                            ProgressView(value: service.progress)
                                .tint(.blue)
                            HStack {
                                Text("\(service.processed) / \(service.total)")
                                    .font(.subheadline)
                                    .monospacedDigit()
                                Spacer()
                                Text("\(Int(service.progress * 100))%")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                    .foregroundColor(.blue)
                            }
                            if service.totalSizeSaved > 0 {
                                Text("已节省 \(service.savedSizeText)")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    } header: {
                        Text(service.conversionScope.isEmpty
                             ? "处理进度"
                             : "处理进度（\(service.conversionScope)）")
                    }
                }

                // MARK: - 失败列表
                if !service.failedItems.isEmpty && !service.isWorking {
                    Section {
                        ForEach(service.failedItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                        .font(.caption)
                                    Text(item.fileName)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                Text(item.error)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Text("失败列表")
                            Spacer()
                            Text("\(service.failedItems.count) 张")
                                .foregroundColor(.red)
                                .fontWeight(.medium)
                        }
                    } footer: {
                        Text("这些图片转换失败，可能是因为文件损坏或 iCloud 下载超时。重新扫描后可再次尝试转换。")
                    }
                }

                // MARK: - 自选转换
                Section {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("在图库里选择照片", systemImage: "photo.on.rectangle.angled")
                    }

                    HStack {
                        Text("已选")
                        Spacer()
                        Text("\(service.selectedLocalIdentifiers.count) 张")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    if !service.lastPickerReport.isEmpty {
                        Text(service.lastPickerReport)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }

                    if !service.selectedLocalIdentifiers.isEmpty {
                        Button {
                            service.convertSelected()
                        } label: {
                            Label("只转换选中的 \(service.selectedLocalIdentifiers.count) 张",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(service.isWorking
                                  || (service.exportMode == .folder && service.exportFolderURL == nil))
                        .tint(.blue)

                        Button("清空选择") {
                            service.setSelection([])
                        }
                        .font(.footnote)
                        .foregroundColor(.red)
                    }
                } header: {
                    Text("自选转换")
                } footer: {
                    Text("用系统选择器在应用内挑图，只转换选中的这些，不走「扫描全部 PNG」。选中项按 localIdentifier 记住；转换后会拿「新建资产的 localIdentifier」反查 Photos.sqlite，把写入的那一行和源图对应起来 —— 对应关系与 UUID 是否吻合会显示在下面的表里。")
                }

                // MARK: - 截图标记（ZASSET.ZKINDSUBTYPE）
                Section {
                    Text(service.subtypeProbe)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if !service.environmentProbe.isEmpty {
                        Text(service.environmentProbe)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    /* 不给文本"可选中"：长按会拉起系统编辑菜单，而在这台机器上那条路径会崩
                       （PhotosDatabaseInspector 里定位过的 CoreImage/CI::GLContext 崩溃，栈里只有 main）。
                       要复制就给按钮，直接写剪贴板，不经过任何菜单界面。 */
                    Button {
                        UIPasteboard.general.string = diagnosticsText()
                        copyNote = "已复制到剪贴板"
                    } label: {
                        Label("复制以上信息", systemImage: "doc.on.doc")
                    }

                    if let copyNote = copyNote {
                        Text(copyNote)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }

                    Button {
                        service.refreshSubtypePanel()
                    } label: {
                        Label("刷新数据库状态", systemImage: "arrow.clockwise")
                    }

                    if let last = service.subtypeLastResult {
                        Text(last)
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if !service.subtypeRows.isEmpty {
                        ForEach(service.subtypeRows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(row.isScreenshot ? "截图" : "照片")
                                        .font(.caption2)
                                        .foregroundColor(row.isScreenshot ? .green : .secondary)
                                    Text("kind=\(row.kindSubtype)")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                    Text("cloud=\(row.cloudKindSubtype)")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                    Text("Z_PK=\(row.zpk)")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                Text("\(row.filename)   \(row.addedAt)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 14) {
                                    Button("设为截图 10") { service.setSubtype(10, zpk: row.zpk) }
                                        .font(.caption2)
                                        .buttonStyle(.borderless)
                                    Button("还原 0") { service.setSubtype(0, zpk: row.zpk) }
                                        .font(.caption2)
                                        .buttonStyle(.borderless)
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("截图标记（数据库）")
                } footer: {
                    Text("Photos 的公开 API 不能设置截图类型，所以这里直接写 Photos.sqlite 的 ZASSET.ZKINDSUBTYPE：10 = 截图，0 = 普通照片。开关打开时，每张转换成功的资产会立刻写成 10。respring 或重启 Photos 之后点上面的刷新，看值有没有被系统写回。")
                }

                // MARK: - 源图 ↔ 新资产（对应表）
                if !service.pairingLog.isEmpty {
                    Section {
                        ForEach(service.pairingLog) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.sourceName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(pairingDetail(entry))
                                    .font(.caption2)
                                    .foregroundColor(entry.note == nil ? .secondary : .orange)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("源图 ↔ 新资产（对应表）")
                    } footer: {
                        Text("每转换一张就记一条。UUID 吻合说明本地定位到的数据库行就是刚建的那个资产；不吻合或走了兜底定位的会标橙，先人工核对再相信写入结果。")
                    }
                }

                // MARK: - 状态
                Section {
                    Text(service.status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                } header: {
                    Text("状态")
                }
            }
            .navigationTitle("PNG \u{2192} HEIF")
            .onAppear {
                service.deleteOriginals = deleteOriginals
                service.writeScreenshotSubtype = writeScreenshotSubtype
                service.requestAuthorizationAndScan()
                service.refreshSubtypePanel()
            }
            .alert(item: $service.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("好"))
                )
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    service.exportFolderURL = url
                    service.exportFolderName = url.lastPathComponent
                    // security-scoped 权限已在 Coordinator 中启动，此处不再重复调用
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { identifiers in
                    service.setSelection(identifiers)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - AlertItem

final class AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}