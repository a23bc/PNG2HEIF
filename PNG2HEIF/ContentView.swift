import SwiftUI
import Photos
import UniformTypeIdentifiers

// MARK: - Folder Picker

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: false — 我们要拿到真实目录路径，不要副本
        let picker = UIDocumentPickerViewController(forExporting: [], asCopy: false)
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
    @State private var showFolderPicker = false
    @State private var showClearConfirm = false

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
                    Toggle("转换成功后删除 PNG", isOn: $service.deleteOriginals)

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
                        Text("处理进度")
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
                service.requestAuthorizationAndScan()
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