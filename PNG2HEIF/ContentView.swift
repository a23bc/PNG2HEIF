import SwiftUI
import Photos
import UniformTypeIdentifiers

// MARK: - Folder Picker (UIDocumentPicker → SwiftUI)

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [], asCopy: true)
        // 让用户选择文件夹
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        // 请求访问权限
        picker.accessibilityElementsHidden = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate, UINavigationControllerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // 用户选的是文件夹，获取 security-scoped 权限
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var service = PhotoLibraryService()
    @State private var showFolderPicker = false

    var body: some View {
        NavigationView {
            Form {
                // MARK: - 统计概览
                Section {
                    HStack {
                        Text("PNG 截图")
                        Spacer()
                        Text("\(service.pngCount) 张")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("原始占用")
                        Spacer()
                        Text(service.pngSizeText)
                            .foregroundColor(.secondary)
                    }
                    if service.pngCount > 0 {
                        HStack {
                            Text("预计转换后")
                            Spacer()
                            Text("~\(service.estimatedSizeText)")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("预计节省")
                            Spacer()
                            Text(service.savedSizeText)
                                .foregroundColor(.green)
                        }
                    }
                } header: {
                    Text("照片图库")
                }

                // MARK: - 导出位置
                Section {
                    Picker("导出到", selection: $service.exportMode) {
                        ForEach(ExportMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .onChange(of: service.exportMode) { _ in
                        // 切换模式时重置文件夹选择
                        if service.exportMode != .folder {
                            service.exportFolderURL = nil
                            service.exportFolderName = nil
                        }
                    }

                    // 指定相簿 → 显示相簿列表
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

                    // 新建相簿 → 输入名称
                    if service.exportMode == .newAlbum {
                        HStack {
                            TextField("相簿名称", text: $service.newAlbumName)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }

                    // 文件夹 → 选择按钮
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
                    Toggle("保留原始日期", isOn: $service.keepCreationDate)

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
                            Text("0.82 接近 iOS 快捷指令效果，截图推荐 0.75-0.85")
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
                        }
                    } header: {
                        Text("处理进度")
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
                    // 持久化访问权限
                    url.startAccessingSecurityScopedResource()
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