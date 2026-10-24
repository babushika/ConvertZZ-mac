import Foundation

public enum TextEncoding: String, CaseIterable, Identifiable, Codable {
    case utf8
    case gbk
    case big5
    case utf16le
    case utf16be

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .gbk: return "GBK (GB18030)"
        case .big5: return "BIG5"
        case .utf16le: return "UTF-16 LE"
        case .utf16be: return "UTF-16 BE"
        }
    }

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16le: return .utf16LittleEndian
        case .utf16be: return .utf16BigEndian
        case .gbk: return Self.cfEncoding(.GB_18030_2000)
        case .big5: return Self.cfEncoding(.big5)
        }
    }

    private static func cfEncoding(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    var bom: [UInt8] {
        switch self {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16le: return [0xFF, 0xFE]
        case .utf16be: return [0xFE, 0xFF]
        default: return []
        }
    }

    public func decode(_ data: Data) -> String? {
        String(data: data, encoding: stringEncoding)
    }

    public func encode(_ text: String, withBOM: Bool = false) -> Data {
        var data = Data(withBOM ? bom : [])
        // 目標編碼無法表示的字元以 "?" 取代，避免整個檔案寫入失敗
        data.append(text.data(using: stringEncoding, allowLossyConversion: true) ?? Data())
        return data
    }
}

public struct DecodedText {
    public var text: String
    public var encoding: TextEncoding
    public var hadBOM: Bool
}

public enum EncodingDetector {
    /// 偵測順序：BOM → 合法 UTF-8 → GBK / BIG5 擇優
    public static func decode(_ data: Data) -> DecodedText? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return TextEncoding.utf8.decode(data.dropFirst(3)).map { DecodedText(text: $0, encoding: .utf8, hadBOM: true) }
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return TextEncoding.utf16le.decode(data.dropFirst(2)).map { DecodedText(text: $0, encoding: .utf16le, hadBOM: true) }
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return TextEncoding.utf16be.decode(data.dropFirst(2)).map { DecodedText(text: $0, encoding: .utf16be, hadBOM: true) }
        }
        if let s = String(data: data, encoding: .utf8) {
            return DecodedText(text: s, encoding: .utf8, hadBOM: false)
        }
        let gbk = TextEncoding.gbk.decode(data)
        let big5 = TextEncoding.big5.decode(data)
        switch (gbk, big5) {
        case let (g?, b?):
            return score(g) >= score(b)
                ? DecodedText(text: g, encoding: .gbk, hadBOM: false)
                : DecodedText(text: b, encoding: .big5, hadBOM: false)
        case let (g?, nil): return DecodedText(text: g, encoding: .gbk, hadBOM: false)
        case let (nil, b?): return DecodedText(text: b, encoding: .big5, hadBOM: false)
        default: return nil
        }
    }

    /// 以指定編碼解碼（失敗時回傳 nil）
    public static func decode(_ data: Data, as encoding: TextEncoding) -> DecodedText? {
        var payload = data
        var hadBOM = false
        let bom = encoding.bom
        if !bom.isEmpty, data.starts(with: bom) {
            payload = data.dropFirst(bom.count)
            hadBOM = true
        }
        return encoding.decode(payload).map { DecodedText(text: $0, encoding: encoding, hadBOM: hadBOM) }
    }

    /// 常用字（簡繁並列）出現越多，代表解碼越可能正確；亂碼通常是罕用字或私用區字元。
    private static let common: Set<Character> = Set(
        "的一是不了人我在有他这這个個们們中来來上大为為和国國地到以说說时時要就出会會可也你对對生能而子那得于於着著下自之年过過发發后後作里裡用道行所然家种種事成方多经經么麼去法学學如都同现現当當没沒动動面起看定天分还還进進好小部其些主样樣理心她本前开開但因只从從想实實日月水火今最新文字章节節第回电電影音乐樂歌词詞曲名长長话話问問题題点點"
    )

    private static func score(_ s: String) -> Int {
        var score = 0
        for ch in s {
            if common.contains(ch) { score += 3; continue }
            guard let v = ch.unicodeScalars.first?.value else { continue }
            if (0xE000...0xF8FF).contains(v) || v == 0xFFFD { score -= 5 } // 私用區/替代字元
            else if (0x3400...0x4DBF).contains(v) || v >= 0x20000 { score -= 1 } // 罕用擴充區
        }
        return score
    }

    /// 只含 ASCII 的資料不需要轉換
    public static func isASCII(_ data: Data) -> Bool {
        !data.contains(where: { $0 >= 0x80 })
    }
}
