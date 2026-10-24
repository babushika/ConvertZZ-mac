import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ConvertZZCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            optionsForm
            logList
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 620)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                )
            VStack(spacing: 8) {
                if model.isWorking {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
                Text(model.statusText).font(.headline)
                Text(model.options.direction == .toTraditional ? "簡體 → 繁體" : "繁體 → 簡體")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 160)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadURLs(from: providers)
            return true
        }
        .onTapGesture { chooseFiles() }
        .help("拖放檔案或資料夾，或點一下選擇")
    }

    private var optionsForm: some View {
        Form {
            Picker("轉換方向", selection: $model.options.direction) {
                Text("簡體 → 繁體").tag(ConversionDirection.toTraditional)
                Text("繁體 → 簡體").tag(ConversionDirection.toSimplified)
            }
            .pickerStyle(.segmented)

            HStack {
                Picker("來源編碼", selection: $model.options.inputEncoding) {
                    ForEach(InputEncoding.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("輸出編碼", selection: $model.options.outputEncoding) {
                    ForEach(OutputEncoding.allCases) { Text($0.displayName).tag($0) }
                }
            }

            HStack(spacing: 16) {
                Toggle("轉換文字內容", isOn: $model.options.convertContent)
                Toggle("轉換檔名", isOn: $model.options.convertFileNames)
                Toggle("轉換 MP3 標籤", isOn: $model.options.convertID3)
            }

            Picker("輸出方式", selection: $model.options.overwrite) {
                Text("輸出到「\(FileProcessor.outputFolderName)」資料夾").tag(false)
                Text("直接覆蓋原檔").tag(true)
            }

            TextField("文字檔副檔名", text: $model.options.textExtensions)
                .font(.system(.body, design: .monospaced))
        }
        .disabled(model.isWorking)
    }

    private var logList: some View {
        List(model.logs) { entry in
            HStack(alignment: .top) {
                Image(systemName: icon(for: entry.kind))
                    .foregroundStyle(color(for: entry.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text((entry.path as NSString).lastPathComponent).lineLimit(1)
                    Text(entry.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .help(entry.path)
        }
        .frame(minHeight: 200)
    }

    private func icon(for kind: ProcessLog.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .unchanged: return "minus.circle"
        case .skipped: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func color(for kind: ProcessLog.Kind) -> Color {
        switch kind {
        case .success: return .green
        case .unchanged: return .secondary
        case .skipped: return .orange
        case .failure: return .red
        }
    }

    private func loadURLs(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.process(urls)
        }
    }

    private func chooseFiles() {
        guard !model.isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            model.process(panel.urls)
        }
    }
}
