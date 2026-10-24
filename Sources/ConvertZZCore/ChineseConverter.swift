import Foundation

public enum ConversionDirection: String, CaseIterable, Identifiable, Codable {
    /// 簡體 → 繁體
    case toTraditional
    /// 繁體 → 簡體
    case toSimplified

    public var id: String { rawValue }
}

/// 簡繁轉換器：先以 ConvertZZ 的詞彙表 (Dictionary.csv) 做最長詞匹配，
/// 詞彙表沒涵蓋到的字再交給 macOS 內建的 ICU 轉換 (Hans-Hant / Hant-Hans)。
public final class ChineseConverter {
    private struct Table {
        var map: [String: String] = [:]
        /// 以首字索引：該字開頭的 key 有哪些長度（以 Character 計），由長到短
        var lengths: [Character: [Int]] = [:]
    }

    private var toTrad = Table()
    private var toSimp = Table()

    public init(dictionaryURL: URL?) {
        if let url = dictionaryURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            load(csv: text)
        }
    }

    public init(csv: String) {
        load(csv: csv)
    }

    public var entryCount: Int { toTrad.map.count }

    private func load(csv: String) {
        var trad: [String: String] = [:]
        var simp: [String: String] = [:]
        for rawLine in csv.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            var line = String(rawLine)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            let cols = line.components(separatedBy: "\t").map(Self.unquote)
            guard cols.count == 6, cols[0] == "True" else { continue }
            let s = cols[2], t = cols[4]
            guard !s.isEmpty, !t.isEmpty else { continue }
            // 與原版相同：同一個 key 只取第一筆。Type 以 "ST:" / "TS:" 開頭的詞條只用於單一方向
            let type = cols[1]
            if !type.hasPrefix("TS:"), trad[s] == nil { trad[s] = t }
            if !type.hasPrefix("ST:"), simp[t] == nil { simp[t] = s }
        }
        toTrad = Self.makeTable(trad)
        toSimp = Self.makeTable(simp)
    }

    private static func unquote(_ field: String) -> String {
        guard field.count >= 2, field.hasPrefix("\""), field.hasSuffix("\"") else { return field }
        return String(field.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }

    private static func makeTable(_ map: [String: String]) -> Table {
        var sets: [Character: Set<Int>] = [:]
        for key in map.keys {
            sets[key.first!, default: []].insert(key.count)
        }
        return Table(map: map, lengths: sets.mapValues { $0.sorted(by: >) })
    }

    public func convert(_ input: String, _ direction: ConversionDirection) -> String {
        guard !input.isEmpty else { return input }
        let table = direction == .toTraditional ? toTrad : toSimp
        let chars = Array(input)
        var output = ""
        output.reserveCapacity(input.utf8.count)
        var pending = "" // 詞彙表沒命中的文字，累積起來一次交給系統轉換
        var i = 0
        while i < chars.count {
            var matched = false
            for len in table.lengths[chars[i]] ?? [] where len <= chars.count - i {
                let key = String(chars[i..<(i + len)])
                if let value = table.map[key] {
                    output += Self.systemTransform(pending, direction)
                    pending = ""
                    output += value
                    i += len
                    matched = true
                    break
                }
            }
            if !matched {
                pending.append(chars[i])
                i += 1
            }
        }
        output += Self.systemTransform(pending, direction)
        return output
    }

    static func systemTransform(_ text: String, _ direction: ConversionDirection) -> String {
        guard !text.isEmpty, text.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) else { return text }
        #if os(macOS)
        let id = direction == .toTraditional ? "Hans-Hant" : "Hant-Hans"
        return text.applyingTransform(StringTransform(id), reverse: false) ?? text
        #else
        return text
        #endif
    }
}
