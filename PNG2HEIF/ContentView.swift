import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var service = PhotoLibraryService()

    var body: some View {
        NavigationView {
            Form {
                Section("照片图库") {
                    HStack {
                        Text("PNG 截图")
                        Spacer()
                        Text("\(service.pngCount)")
                    }
                    HStack {
                        Text("PNG 占用空间")
                        Spacer()
                        Text(service.pngSizeText)
                    }
                }

                Section("选项") {
                    Toggle("转换成功后删除 PNG", isOn: $service.deleteOriginals)
                        .disabled(service.isWorking)

                    Toggle("只处理 PNG", isOn: $service.onlyPNG)
                        .disabled(service.isWorking)
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
                            service.stop()
                        } label: {
                            Label("停止转换", systemImage: "stop.circle")
                        }
                    } else {
                        Button {
                            service.startConversion()
                        } label: {
                            Label("开始转换", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(service.pngCount == 0)
                    }
                }

                if service.isWorking || service.total > 0 {
                    Section("处理进度") {
                        ProgressView(value: service.progress)

                        HStack {
                            Text("\(service.processed) / \(service.total)")
                            Spacer()
                            Text("\(Int(service.progress * 100))%")
                        }
                        .font(.footnote)

                        Text(service.status)
                            .font(.footnote)
                    }
                }

                Section("状态") {
                    Text(service.status)
                        .font(.footnote)
                }
            }
            .navigationTitle("PNG → HEIF")
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
    }
}

final class AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}
