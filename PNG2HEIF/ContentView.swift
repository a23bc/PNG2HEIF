import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var model = ConverterModel()

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("PNG 截图")) {
                    HStack {
                        Text("可转换")
                        Spacer()
                        Text("\(model.pngCount)")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("估算 PNG 占用")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: model.pngBytes, countStyle: .file))
                            .monospacedDigit()
                    }
                }

                Section(header: Text("选项")) {
                    Toggle("只转换 PNG", isOn: $model.onlyPNG)
                    Toggle("保留原始日期", isOn: $model.keepCreationDate)
                    Toggle("转换成功后删除 PNG", isOn: $model.deleteOriginals)
                    Toggle("加入“HEIF截图”相簿", isOn: $model.addToAlbum)
                }

                Section {
                    Button(model.running ? "转换中…" : "开始转换") {
                        model.start()
                    }
                    .disabled(model.running || model.pngCount == 0)
                }

                if model.running {
                    Section {
                        ProgressView(value: model.progress)
                        Text("\(model.processed) / \(model.total)")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                if !model.status.isEmpty {
                    Section(header: Text("状态")) {
                        Text(model.status)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("PNG → HEIF")
        }
        .onAppear { model.refresh() }
    }
}