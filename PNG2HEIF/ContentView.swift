import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var service = PhotoLibraryService()

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
                    // 扫描按钮（始终可用）
                    Button {
                        service.scan()
                    } label: {
                        Label("扫描图库", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(service.isWorking)

                    // 开始 / 停止按钮
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