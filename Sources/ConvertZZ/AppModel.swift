import Foundation
import ConvertZZCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var options: ConversionOptions {
        didSet { saveOptions() }
    }
    @Published var logs: [ProcessLog] = []
    @Published var isWorking = false
    @Published var statusText = "把檔案或資料夾拖進來"

    private var converter: ChineseConverter?
    private static let optionsKey = "ConversionOptions"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.optionsKey),
           let saved = try? JSONDecoder().decode(ConversionOptions.self, from: data) {
            options = saved
        } else {
            options = ConversionOptions()
        }
    }

    private func saveOptions() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: Self.optionsKey)
        }
    }

    nonisolated static func dictionaryURL() -> URL? {
        if let url = Bundle.main.url(forResource: "Dictionary", withExtension: "csv") { return url }
        // 以 `swift run` 執行時，從原始碼目錄找
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Resources/Dictionary.csv")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func process(_ urls: [URL]) {
        guard !urls.isEmpty, !isWorking else { return }
        isWorking = true
        statusText = "轉換中…"
        logs.removeAll()
        let options = self.options
        let existing = converter

        Task.detached(priority: .userInitiated) {
            let converter = existing ?? ChineseConverter(dictionaryURL: AppModel.dictionaryURL())
            var collected: [ProcessLog] = []
            FileProcessor(converter: converter, options: options).process(urls) { collected.append($0) }
            await MainActor.run {
                self.converter = converter
                self.logs = collected
                self.isWorking = false
                let ok = collected.filter { $0.kind == .success }.count
                let failed = collected.filter { $0.kind == .failure }.count
                self.statusText = "完成：成功 \(ok) 項" + (failed > 0 ? "，失敗 \(failed) 項" : "")
            }
        }
    }
}
