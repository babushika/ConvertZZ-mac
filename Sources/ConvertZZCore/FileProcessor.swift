import Foundation

public enum OutputEncoding: String, CaseIterable, Identifiable, Codable {
    case utf8, sameAsInput, big5, gbk

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .sameAsInput: return "與原檔相同"
        case .big5: return "BIG5"
        case .gbk: return "GBK"
        }
    }
}

public enum InputEncoding: String, CaseIterable, Identifiable, Codable {
    case auto, utf8, gbk, big5

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "自動偵測"
        case .utf8: return "UTF-8"
        case .gbk: return "GBK"
        case .big5: return "BIG5"
        }
    }
}

public enum OutputMode: String, CaseIterable, Identifiable, Codable {
    /// 輸出到旁邊的「ConvertZZ 輸出」資料夾
    case outputFolder
    /// 在原檔旁另存一份，檔名加上 .zh-tw（簡→繁）或 .zh-cn（繁→簡）
    case suffix
    /// 直接覆蓋原檔
    case overwrite

    public var id: String { rawValue }
}

public struct ConversionOptions: Codable, Equatable {
    public var direction: ConversionDirection = .toTraditional
    public var inputEncoding: InputEncoding = .auto
    public var outputEncoding: OutputEncoding = .utf8
    public var convertContent = true
    public var convertFileNames = true
    public var convertID3 = true
    public var outputMode: OutputMode = .outputFolder
    public var textExtensions = "txt,srt,ass,ssa,lrc,cue,csv,md,html,htm,xml,json,ini,nfo,log,sub,vtt,m3u,m3u8"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case direction, inputEncoding, outputEncoding, convertContent, convertFileNames, convertID3
        case outputMode, textExtensions
        case overwrite // 1.2.1 以前的設定
    }

    // 逐項讀取，新增欄位時舊版存下的設定仍可沿用
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decodeIfPresent(ConversionDirection.self, forKey: .direction) ?? direction
        inputEncoding = try c.decodeIfPresent(InputEncoding.self, forKey: .inputEncoding) ?? inputEncoding
        outputEncoding = try c.decodeIfPresent(OutputEncoding.self, forKey: .outputEncoding) ?? outputEncoding
        convertContent = try c.decodeIfPresent(Bool.self, forKey: .convertContent) ?? convertContent
        convertFileNames = try c.decodeIfPresent(Bool.self, forKey: .convertFileNames) ?? convertFileNames
        convertID3 = try c.decodeIfPresent(Bool.self, forKey: .convertID3) ?? convertID3
        textExtensions = try c.decodeIfPresent(String.self, forKey: .textExtensions) ?? textExtensions
        if let mode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) {
            outputMode = mode
        } else if try c.decodeIfPresent(Bool.self, forKey: .overwrite) == true {
            outputMode = .overwrite
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(direction, forKey: .direction)
        try c.encode(inputEncoding, forKey: .inputEncoding)
        try c.encode(outputEncoding, forKey: .outputEncoding)
        try c.encode(convertContent, forKey: .convertContent)
        try c.encode(convertFileNames, forKey: .convertFileNames)
        try c.encode(convertID3, forKey: .convertID3)
        try c.encode(outputMode, forKey: .outputMode)
        try c.encode(textExtensions, forKey: .textExtensions)
    }

    /// 另存模式加在檔名的字尾
    public var fileSuffix: String { direction == .toTraditional ? "zh-tw" : "zh-cn" }

    var extensionSet: Set<String> {
        Set(textExtensions.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
    }
}

public struct ProcessLog: Identifiable {
    public enum Kind { case success, unchanged, skipped, failure }
    public let id = UUID()
    public let kind: Kind
    public let path: String
    public let message: String
}

public final class FileProcessor {
    let converter: ChineseConverter
    let options: ConversionOptions
    let fm = FileManager.default
    public static let outputFolderName = "ConvertZZ 輸出"

    public init(converter: ChineseConverter, options: ConversionOptions) {
        self.converter = converter
        self.options = options
    }

    /// 處理拖進來的檔案或資料夾，每處理一個項目就呼叫一次 log
    public func process(_ urls: [URL], log: (ProcessLog) -> Void) {
        for url in urls {
            let root = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else {
                log(ProcessLog(kind: .failure, path: root.path, message: "找不到檔案"))
                continue
            }
            switch options.outputMode {
            case .overwrite: processInPlace(root, isDirectory: isDir.boolValue, log: log)
            case .outputFolder: processToOutput(root, isDirectory: isDir.boolValue, log: log)
            case .suffix: processWithSuffix(root, isDirectory: isDir.boolValue, log: log)
            }
        }
    }

    // MARK: - 覆蓋原檔

    private func processInPlace(_ root: URL, isDirectory: Bool, log: (ProcessLog) -> Void) {
        let files = isDirectory ? enumerateFiles(in: root) : [root]
        for file in files {
            convertFile(at: file, log: log)
        }
        guard options.convertFileNames else { return }
        // 由深到淺改名，避免先改了上層資料夾導致路徑失效
        var items = isDirectory ? enumerateAll(in: root) : []
        items.sort { $0.pathComponents.count > $1.pathComponents.count }
        items.append(root)
        for item in items {
            rename(item, log: log)
        }
    }

    // MARK: - 輸出到新資料夾

    private func processToOutput(_ root: URL, isDirectory: Bool, log: (ProcessLog) -> Void) {
        let outputDir = root.deletingLastPathComponent().appendingPathComponent(Self.outputFolderName, isDirectory: true)
        do {
            try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            log(ProcessLog(kind: .failure, path: outputDir.path, message: "無法建立輸出資料夾：\(error.localizedDescription)"))
            return
        }
        let base = root.deletingLastPathComponent()
        let files = isDirectory ? enumerateFiles(in: root) : [root]
        for file in files {
            let relative = file.pathComponents.dropFirst(base.pathComponents.count)
            var dest = outputDir
            for component in relative {
                dest.appendPathComponent(options.convertFileNames ? converter.convert(component, options.direction) : component)
            }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: file, to: dest)
            } catch {
                log(ProcessLog(kind: .failure, path: file.path, message: "複製失敗：\(error.localizedDescription)"))
                continue
            }
            convertFile(at: dest, log: log)
        }
    }

    // MARK: - 另存為 .zh-tw / .zh-cn

    private static let suffixes: Set<String> = ["zh-tw", "zh-cn"]

    private func processWithSuffix(_ root: URL, isDirectory: Bool, log: (ProcessLog) -> Void) {
        let files = isDirectory ? enumerateFiles(in: root) : [root]
        for file in files {
            // 已經是轉換結果的檔案（例如 a.zh-tw.txt）不再處理
            let stem = file.deletingPathExtension()
            if Self.suffixes.contains(stem.pathExtension.lowercased()) { continue }
            guard isConvertible(file) else {
                if !isDirectory {
                    log(ProcessLog(kind: .skipped, path: file.path, message: "不支援的檔案類型"))
                }
                continue
            }
            var name = stem.lastPathComponent
            if options.convertFileNames { name = converter.convert(name, options.direction) }
            name += "." + options.fileSuffix
            if !file.pathExtension.isEmpty { name += "." + file.pathExtension }
            let dest = file.deletingLastPathComponent().appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: file, to: dest)
            } catch {
                log(ProcessLog(kind: .failure, path: file.path, message: "複製失敗：\(error.localizedDescription)"))
                continue
            }
            convertFile(at: dest, log: log)
        }
    }

    /// 這個檔案在目前的設定下會不會被轉換
    private func isConvertible(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "mp3" { return options.convertID3 }
        guard options.convertContent else { return false }
        return OfficeConverter.supportedExtensions.contains(ext) || options.extensionSet.contains(ext)
    }

    // MARK: - 單一檔案

    private func convertFile(at url: URL, log: (ProcessLog) -> Void) {
        let ext = url.pathExtension.lowercased()
        if ext == "mp3" {
            guard options.convertID3 else { return }
            do {
                let result = try ID3Converter(converter: converter, direction: options.direction).process(fileAt: url)
                switch result {
                case .converted: log(ProcessLog(kind: .success, path: url.path, message: "ID3 標籤已轉換"))
                case .unchanged: log(ProcessLog(kind: .unchanged, path: url.path, message: "ID3 標籤不需轉換"))
                case .skipped(let reason): log(ProcessLog(kind: .skipped, path: url.path, message: reason))
                }
            } catch {
                log(ProcessLog(kind: .failure, path: url.path, message: error.localizedDescription))
            }
            return
        }
        guard options.convertContent else { return }
        if OfficeConverter.supportedExtensions.contains(ext) {
            do {
                switch try OfficeConverter(converter: converter, direction: options.direction).process(fileAt: url) {
                case .converted: log(ProcessLog(kind: .success, path: url.path, message: "Office 文件已轉換"))
                case .unchanged: log(ProcessLog(kind: .unchanged, path: url.path, message: "內容不需轉換"))
                }
            } catch {
                log(ProcessLog(kind: .failure, path: url.path, message: error.localizedDescription))
            }
            return
        }
        if OfficeConverter.legacyExtensions.contains(ext) {
            log(ProcessLog(kind: .skipped, path: url.path, message: "舊版 Office 格式無法轉換，請先用 Word / Excel / PowerPoint 或 Pages 另存為 .\(ext)x"))
            return
        }
        guard options.extensionSet.contains(ext) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded: DecodedText?
            switch options.inputEncoding {
            case .auto: decoded = EncodingDetector.decode(data)
            case .utf8: decoded = EncodingDetector.decode(data, as: .utf8)
            case .gbk: decoded = EncodingDetector.decode(data, as: .gbk)
            case .big5: decoded = EncodingDetector.decode(data, as: .big5)
            }
            guard let decoded else {
                log(ProcessLog(kind: .failure, path: url.path, message: "無法判斷檔案編碼"))
                return
            }
            let converted = converter.convert(decoded.text, options.direction)
            let target: TextEncoding
            switch options.outputEncoding {
            case .utf8: target = .utf8
            case .sameAsInput: target = decoded.encoding
            case .big5: target = .big5
            case .gbk: target = .gbk
            }
            let keepBOM = decoded.hadBOM && (target == decoded.encoding || target == .utf16le || target == .utf16be)
            let output = target.encode(converted, withBOM: keepBOM)
            if output == data {
                log(ProcessLog(kind: .unchanged, path: url.path, message: "內容不需轉換"))
                return
            }
            try output.write(to: url, options: .atomic)
            log(ProcessLog(kind: .success, path: url.path, message: "\(decoded.encoding.displayName) → \(target.displayName)"))
        } catch {
            log(ProcessLog(kind: .failure, path: url.path, message: error.localizedDescription))
        }
    }

    private func rename(_ url: URL, log: (ProcessLog) -> Void) {
        let name = url.lastPathComponent
        let newName = converter.convert(name, options.direction)
        guard newName != name else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        if fm.fileExists(atPath: dest.path) {
            log(ProcessLog(kind: .skipped, path: url.path, message: "「\(newName)」已存在，未改名"))
            return
        }
        do {
            try fm.moveItem(at: url, to: dest)
            log(ProcessLog(kind: .success, path: url.path, message: "改名為「\(newName)」"))
        } catch {
            log(ProcessLog(kind: .failure, path: url.path, message: "改名失敗：\(error.localizedDescription)"))
        }
    }

    // MARK: - 列舉

    private func enumerateAll(in dir: URL) -> [URL] {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { ($0 as? URL)?.standardizedFileURL }
            .filter { !$0.pathComponents.contains(Self.outputFolderName) }
    }

    private func enumerateFiles(in dir: URL) -> [URL] {
        enumerateAll(in: dir).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
