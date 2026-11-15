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

/// 三个标签页：转换 / 数据库 / 诊断。把原来堆在一个 Form 里的十来个 Section 按职责分开，
/// 每页只保留相关控件；所有绑定与动作不变。
struct ContentView: View {
    @StateObject private var service = PhotoLibraryService.shared
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
        if !service.codecProbe.isEmpty {
            lines.append("")
            lines.append("== 编码自检 ==")
            lines.append(service.codecProbe)
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
        TabView {
            convertTab
                .tabItem { Label("转换", systemImage: "arrow.triangle.2.circlepath") }
            databaseTab
                .tabItem { Label("数据库", systemImage: "tablecells") }
            diagnosticsTab
                .tabItem { Label("诊断", systemImage: "waveform.path.ecg") }
        }
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
        .alert("确认清除", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { service.clearHistory() }
        } message: {
            Text("将清除所有转换记录，下次扫描会重新发现所有 PNG 截图。已转换的文件不会被撤回。")
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                service.exportFolderURL = url
                service.exportFolderName = url.lastPathComponent
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { identifiers in
                service.setSelection(identifiers)
            }
        }
    }

    // MARK: - Tab 1: 转换

    private var convertTab: some View {
        NavigationView {
            Form {
                Section {
                    statRow("待转换 PNG", "\(service.pngCount) 张", .secondary)
                    if service.skippedCount > 0 {
                        statRow("已跳过（历史）", "\(service.skippedCount) 张", .orange)
                    }
                    if service.historyCount > 0 {
                        statRow("累计已转换", "\(service.historyCount) 张", .green)
                    }
                    if service.totalSizeSaved > 0 {
                        statRow("已节省空间", service.savedSizeText, .green)
                    }
                } header: {
                    Text("概览")
                } footer: {
                    if service.historyCount > 0 {
                        Button("清除转换记录") { showClearConfirm = true }
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        service.scan()
                    } label: {
                        Label("扫描图库", systemImage: "magnifyingglass")
                    }
                    .disabled(service.isWorking)

                    if service.isWorking {
                        Button(role: .destructive) {
                            service.stopConversion()
                        } label: {
                            Label("停止转换", systemImage: "stop.circle.fill")
                        }
                        .tint(.red)
                        ProgressView(value: service.progress)
                        HStack {
                            Text("\(service.processed) / \(service.total)")
                                .monospacedDigit()
                            Spacer()
                            Text(service.conversionScope)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .font(.caption)
                    } else {
                        Button {
                            service.startConversion()
                        } label: {
                            Label("开始转换", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(service.pngCount == 0)
                        .tint(.blue)

                        Button {
                            _ = service.convertNewScreenshots(trigger: "手动")
                        } label: {
                            Label("转换新截图（自动入口）", systemImage: "camera.viewfinder")
                        }
                    }
                } header: {
                    Text("操作")
                }

                Section {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("在图库里选择照片", systemImage: "photo.on.rectangle.angled")
                    }
                    statRow("已选", "\(service.selectedLocalIdentifiers.count) 张", .secondary)
                    if !service.selectedLocalIdentifiers.isEmpty {
                        Button {
                            service.convertSelected()
                        } label: {
                            Label("只转换选中的 \(service.selectedLocalIdentifiers.count) 张",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(service.isWorking
                                  || (service.exportMode == .folder && service.exportFolderURL == nil))
                        .tint(.blue)
                        Button("清空选择") { service.setSelection([]) }
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                    if !service.lastPickerReport.isEmpty {
                        Text(service.lastPickerReport)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                } header: {
                    Text("自选转换")
                }

                exportSection
                optionsSection

                if !service.failedItems.isEmpty && !service.isWorking {
                    Section {
                        ForEach(service.failedItems) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.fileName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(item.error)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        HStack {
                            Text("失败列表")
                            Spacer()
                            Text("\(service.failedItems.count) 张").foregroundColor(.red)
                        }
                    }
                }

                Section {
                    Text(service.status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("状态")
                }
            }
            .navigationTitle("PNG → HEIF")
        }
        .navigationViewStyle(.stack)
    }

    private func statRow(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(color)
                .monospacedDigit()
        }
    }

    private var exportSection: some View {
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
                    Text("没有用户相簿").foregroundColor(.secondary).font(.subheadline)
                } else {
                    Picker("选择相簿", selection: $service.selectedAlbumID) {
                        Text("请选择").tag(String?.none)
                        ForEach(service.userAlbums) { album in
                            Text("\(album.title)（\(album.count)）").tag(Optional(album.id))
                        }
                    }
                }
            }
            if service.exportMode == .newAlbum {
                TextField("相簿名称", text: $service.newAlbumName)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit { hideKeyboard() }
            }
            if service.exportMode == .folder {
                Button {
                    showFolderPicker = true
                } label: {
                    HStack {
                        Label("选择文件夹", systemImage: "folder.badge.plus")
                        Spacer()
                        Text(service.exportFolderName ?? "未选择")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } header: {
            Text("导出位置")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("转换后删除原 PNG", isOn: $deleteOriginals)
                .onChange(of: deleteOriginals) { service.deleteOriginals = $0 }
            Toggle("写入截图标记 + 无缝替换", isOn: $writeScreenshotSubtype)
                .onChange(of: writeScreenshotSubtype) { service.writeScreenshotSubtype = $0 }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("压缩质量")
                    Spacer()
                    Text("\(Int(service.compressionQuality * 100))%")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $service.compressionQuality, in: 0.5...1.0, step: 0.01)
            }
        } header: {
            Text("选项")
        } footer: {
            Text("截图标记=ZKINDSUBTYPE 10；无缝替换=同名+同排序+原时间+P3。质量 0.75–0.85 适合截图。")
        }
    }

    // MARK: - Tab 2: 数据库

    private var databaseTab: some View {
        NavigationView {
            Form {
                Section {
                    Text(service.subtypeProbe)
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
                } header: {
                    Text("截图标记（ZKINDSUBTYPE）")
                } footer: {
                    Text("10=截图，0=普通照片。respring 后点刷新看是否被系统写回。")
                }

                if !service.subtypeRows.isEmpty {
                    Section {
                        ForEach(service.subtypeRows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(row.isScreenshot ? "截图" : "照片")
                                        .font(.caption2)
                                        .foregroundColor(row.isScreenshot ? .green : .secondary)
                                    Text("kind=\(row.kindSubtype) cloud=\(row.cloudKindSubtype) Z_PK=\(row.zpk)")
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
                        }
                    } header: {
                        Text("最近行")
                    }
                }

                if !service.pairingLog.isEmpty {
                    Section {
                        ForEach(service.pairingLog) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.sourceName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(pairingDetail(entry))
                                    .font(.caption2)
                                    .foregroundColor(entry.note == nil ? .secondary : .orange)
                                    .lineLimit(2)
                            }
                        }
                    } header: {
                        Text("源图 ↔ 新资产")
                    } footer: {
                        Text("UUID 不吻合或走兜底定位的标橙，先人工核对再相信写入结果。")
                    }
                }
            }
            .navigationTitle("数据库")
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Tab 3: 诊断

    private var diagnosticsTab: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        service.refreshSubtypePanel()
                    } label: {
                        Label("刷新环境信息", systemImage: "arrow.clockwise")
                    }
                    if !service.environmentProbe.isEmpty {
                        Text(service.environmentProbe)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("运行环境")
                }

                Section {
                    Button {
                        service.runCodecSelfTest()
                    } label: {
                        Label("编码自检（PNG / JPEG / HEIC）", systemImage: "waveform.path.ecg")
                    }
                    if !service.codecProbe.isEmpty {
                        Text(service.codecProbe)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("编码自检")
                }

                Section {
                    Button {
                        UIPasteboard.general.string = diagnosticsText()
                        copyNote = "已复制到剪贴板"
                    } label: {
                        Label("复制全部诊断信息", systemImage: "doc.on.doc")
                    }
                    if let copyNote = copyNote {
                        Text(copyNote)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                } header: {
                    Text("导出诊断")
                } footer: {
                    Text("把环境/自检/最近行/对应表攒成一段文本，便于反馈问题。")
                }
            }
            .navigationTitle("诊断")
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