import Foundation

/// 轉換 Office Open XML 文件（.docx / .xlsx / .pptx）中的文字，保留所有格式。
/// 這些檔案是 zip，裡面的文字存在 XML 節點中；Word 等會把一個詞拆在多個格式片段（run）裡，
/// 所以以整個段落為單位轉換，再依原本各片段的字數分配回去。
public struct OfficeConverter {
    public enum Result: Equatable {
        case converted
        case unchanged
    }

    public static let supportedExtensions: Set<String> = ["docx", "docm", "xlsx", "xlsm", "pptx", "pptm"]
    /// 舊版二進位格式，無法安全修改
    public static let legacyExtensions: Set<String> = ["doc", "xls", "ppt"]

    let convert: (String) -> String

    public init(converter: ChineseConverter, direction: ConversionDirection) {
        convert = { converter.convert($0, direction) }
    }

    /// 某個 XML 檔裡的文字節點與段落結尾標籤
    struct TextRule {
        let textTag: String
        let unitEnd: String
    }

    static func rules(for path: String) -> [TextRule] {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        if path == "docProps/core.xml" {
            return ["dc:title", "dc:subject", "dc:creator", "cp:keywords", "dc:description", "cp:category"]
                .map { TextRule(textTag: $0, unitEnd: "</\($0)>") }
        }
        if dir == "word", ["document", "header", "footer", "footnotes", "endnotes", "comments"].contains(where: { name.hasPrefix($0) }) {
            return [TextRule(textTag: "w:t", unitEnd: "</w:p>")]
        }
        if dir.hasPrefix("ppt/slides") || dir.hasPrefix("ppt/notesSlides") || dir.hasPrefix("ppt/charts") || dir.hasPrefix("word/charts") || dir.hasPrefix("xl/charts") {
            return [TextRule(textTag: "a:t", unitEnd: "</a:p>")]
        }
        if path == "xl/sharedStrings.xml" {
            return [TextRule(textTag: "t", unitEnd: "</si>")]
        }
        if dir == "xl/worksheets" {
            return [TextRule(textTag: "t", unitEnd: "</is>")]
        }
        if dir == "xl", name.hasPrefix("comments") {
            return [TextRule(textTag: "t", unitEnd: "</comment>")]
        }
        return []
    }

    public func process(fileAt url: URL) throws -> Result {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ConvertZZ-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let unpacked = work.appendingPathComponent("doc", isDirectory: true)
        try Self.run("/usr/bin/unzip", ["-q", url.path, "-d", unpacked.path])

        var changed = false
        let root = unpacked.standardizedFileURL.path
        if let e = fm.enumerator(at: unpacked, includingPropertiesForKeys: nil) {
            for case let file as URL in e where file.pathExtension == "xml" {
                let relative = String(file.standardizedFileURL.path.dropFirst(root.count + 1))
                let rules = Self.rules(for: relative)
                guard !rules.isEmpty, let xml = try? String(contentsOf: file, encoding: .utf8) else { continue }
                var output = xml
                for rule in rules {
                    output = convertXML(output, rule)
                }
                if output != xml {
                    try output.write(to: file, atomically: true, encoding: .utf8)
                    changed = true
                }
            }
        }
        guard changed else { return .unchanged }

        let zipped = work.appendingPathComponent("out.zip")
        // [Content_Types].xml 放在第一個，與 Office 產生的檔案一致
        try Self.run("/usr/bin/zip", ["-q", "-X", zipped.path, "[Content_Types].xml"], in: unpacked)
        try Self.run("/usr/bin/zip", ["-q", "-X", "-r", zipped.path, ".", "-x", "[Content_Types].xml"], in: unpacked)
        _ = try fm.replaceItemAt(url, withItemAt: zipped)
        return .converted
    }

    // MARK: - XML

    func convertXML(_ xml: String, _ rule: TextRule) -> String {
        let tag = NSRegularExpression.escapedPattern(for: rule.textTag)
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)(?:\\s[^>]*)?>([^<]*)</\(tag)>") else { return xml }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return xml }

        // 依段落結尾分組
        var groups: [[NSRange]] = []
        var current: [NSRange] = []
        var lastEnd = 0
        for m in matches {
            let content = m.range(at: 1)
            let between = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            if between.contains(rule.unitEnd), !current.isEmpty {
                groups.append(current)
                current = []
            }
            current.append(content)
            lastEnd = m.range.location + m.range.length
        }
        if !current.isEmpty { groups.append(current) }

        var replacements: [(NSRange, String)] = []
        for group in groups {
            let pieces = group.map { Self.unescape(ns.substring(with: $0)) }
            let original = pieces.joined()
            let converted = convert(original)
            guard converted != original else { continue }
            let newPieces = Self.distribute(converted, like: pieces)
            for (range, (old, new)) in zip(group, zip(pieces, newPieces)) where old != new {
                replacements.append((range, Self.escape(new)))
            }
        }
        guard !replacements.isEmpty else { return xml }
        let result = NSMutableString(string: xml)
        for (range, text) in replacements.reversed() {
            result.replaceCharacters(in: range, with: text)
        }
        return result as String
    }

    /// 把轉換後的文字按原本各片段的字數切回去；字數不同時全部放在第一個片段
    static func distribute(_ text: String, like pieces: [String]) -> [String] {
        let chars = Array(text)
        let counts = pieces.map { $0.count }
        guard counts.reduce(0, +) == chars.count else {
            return [text] + Array(repeating: "", count: max(pieces.count - 1, 0))
        }
        var result: [String] = []
        var i = 0
        for n in counts {
            result.append(String(chars[i..<(i + n)]))
            i += n
        }
        return result
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";") else { break }
            let entity = rest[rest.index(after: amp)..<semi]
            switch entity {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                var scalar: Unicode.Scalar?
                if entity.hasPrefix("#x") { scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
                else if entity.hasPrefix("#") { scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init) }
                if let scalar { out.unicodeScalars.append(scalar) } else { out += rest[amp...semi] }
            }
            rest = rest[rest.index(after: semi)...]
        }
        out += rest
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - zip

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ tool: String, _ args: [String], in dir: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ToolError(message: "\((tool as NSString).lastPathComponent) 失敗：\(msg)")
        }
    }
}
