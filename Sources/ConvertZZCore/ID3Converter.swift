import Foundation

/// 轉換 MP3 的 ID3v1 / ID3v2.3 / ID3v2.4 文字標籤。
/// v2 的文字一律改寫為 Unicode（v2.3 用 UTF-16，v2.4 用 UTF-8），
/// 這樣舊播放器把 GBK / BIG5 當 Latin-1 讀出的亂碼也一併修正。
public struct ID3Converter {
    public enum Result: Equatable {
        case converted
        case unchanged
        case skipped(String)
    }

    let convert: (String) -> String
    /// ID3v1 只能存單一位元組編碼，寫回時使用的編碼
    let v1Encoding: TextEncoding

    public init(converter: ChineseConverter, direction: ConversionDirection) {
        convert = { converter.convert($0, direction) }
        v1Encoding = direction == .toTraditional ? .big5 : .gbk
    }

    public func process(fileAt url: URL) throws -> Result {
        var data = try Data(contentsOf: url, options: .mappedIfSafe)
        var changed = false
        var notes: [String] = []

        if let v1 = convertV1(data) {
            data.replaceSubrange((data.count - 128)..<data.count, with: v1)
            changed = true
        }

        switch convertV2(data) {
        case .success(let newData?):
            data = newData
            changed = true
        case .success(nil):
            break
        case .failure(let reason):
            notes.append(reason)
        }

        if changed {
            try data.write(to: url, options: .atomic)
            return .converted
        }
        return notes.isEmpty ? .unchanged : .skipped(notes.joined(separator: "; "))
    }

    // MARK: - ID3v1

    private func convertV1(_ data: Data) -> Data? {
        guard data.count >= 128 else { return nil }
        let start = data.count - 128
        var tag = [UInt8](data[start..<data.count])
        guard tag[0] == 0x54, tag[1] == 0x41, tag[2] == 0x47 else { return nil } // "TAG"
        var changed = false
        // title, artist, album (各 30 bytes), comment (30 bytes，若有曲目編號則為 28)
        let commentLength = (tag[125] == 0 && tag[126] != 0) ? 28 : 30
        for (offset, length) in [(3, 30), (33, 30), (63, 30), (97, commentLength)] {
            let field = Array(tag[offset..<(offset + length)])
            let trimmed = Data(field.prefix(while: { $0 != 0 }))
            guard !trimmed.isEmpty, !EncodingDetector.isASCII(trimmed),
                  let decoded = EncodingDetector.decode(trimmed) else { continue }
            let converted = convert(decoded.text)
            let encoded = truncate(v1Encoding.encode(converted), to: length)
            let newField = encoded + [UInt8](repeating: 0, count: length - encoded.count)
            if newField != field {
                tag.replaceSubrange(offset..<(offset + length), with: newField)
                changed = true
            }
        }
        return changed ? Data(tag) : nil
    }

    /// 在字元邊界截斷，避免切斷雙位元組字
    private func truncate(_ data: Data, to maxLength: Int) -> [UInt8] {
        let bytes = [UInt8](data)
        guard bytes.count > maxLength else { return bytes }
        var i = 0
        while i < bytes.count {
            let width = bytes[i] >= 0x80 ? 2 : 1
            if i + width > maxLength { break }
            i += width
        }
        return Array(bytes[0..<i])
    }

    // MARK: - ID3v2

    private enum V2Outcome {
        case success(Data?)
        case failure(String)
    }

    private func convertV2(_ data: Data) -> V2Outcome {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return .success(nil) } // "ID3"
        let version = bytes[3]
        let flags = bytes[5]
        guard version == 3 || version == 4 else { return .failure("不支援 ID3v2.\(version)") }
        if flags & 0x80 != 0 { return .failure("ID3 使用 unsynchronisation，略過") }
        if flags & 0x10 != 0 { return .failure("ID3 含 footer，略過") }
        let tagSize = syncsafe(bytes[6], bytes[7], bytes[8], bytes[9])
        let tagEnd = 10 + tagSize
        guard data.count >= tagEnd else { return .failure("ID3 標籤長度不正確") }
        let body = [UInt8](data[10..<tagEnd])

        var pos = 0
        if flags & 0x40 != 0, body.count >= 4 { // extended header：重建時直接捨棄
            let extSize = version == 4
                ? syncsafe(body[0], body[1], body[2], body[3])
                : Int(be32(body[0], body[1], body[2], body[3])) + 4
            pos = extSize
        }

        var frames: [UInt8] = []
        var changed = false
        while pos + 10 <= body.count {
            let id = body[pos..<(pos + 4)]
            if id.first == 0 { break } // padding
            let size = version == 4
                ? syncsafe(body[pos + 4], body[pos + 5], body[pos + 6], body[pos + 7])
                : Int(be32(body[pos + 4], body[pos + 5], body[pos + 6], body[pos + 7]))
            let frameFlags = (body[pos + 8], body[pos + 9])
            let payloadStart = pos + 10
            guard size >= 0, payloadStart + size <= body.count else { return .failure("ID3 frame 損毀") }
            let payload = Array(body[payloadStart..<(payloadStart + size)])
            let frameID = String(decoding: id, as: UTF8.self)

            var newPayload: [UInt8]? = nil
            // 壓縮、加密等格式旗標的 frame 保持原樣
            if frameFlags.1 == 0 {
                newPayload = convertFrame(frameID, payload, version: version)
            }
            frames += Array(id)
            if let p = newPayload, p != payload {
                changed = true
                frames += version == 4 ? toSyncsafe(p.count) : toBE32(p.count)
                frames += [frameFlags.0, frameFlags.1]
                frames += p
            } else {
                frames += body[(pos + 4)..<(payloadStart + size)]
            }
            pos = payloadStart + size
        }
        guard changed else { return .success(nil) }

        // 若新標籤放得進原本的空間就補 padding，否則重寫整個檔案
        let newBodySize = max(frames.count, tagSize)
        let padding = newBodySize - frames.count
        var header: [UInt8] = [0x49, 0x44, 0x33, version, 0, flags & ~0x40]
        header += toSyncsafe(padding > 0 ? newBodySize : frames.count + 1024)
        var out = Data(header)
        out.append(contentsOf: frames)
        out.append(contentsOf: [UInt8](repeating: 0, count: padding > 0 ? padding : 1024))
        out.append(data[tagEnd...])
        return .success(out)
    }

    private func convertFrame(_ id: String, _ payload: [UInt8], version: UInt8) -> [UInt8]? {
        guard let enc = payload.first else { return nil }
        let prefixLength: Int
        if id.hasPrefix("T") {
            prefixLength = 1 // 包含 TXXX：描述與值以 \0 分隔，一併轉換
        } else if id == "COMM" || id == "USLT" {
            prefixLength = 4 // 編碼 + 3 字元語言碼
        } else {
            return nil
        }
        guard payload.count > prefixLength else { return nil }
        let raw = Data(payload[prefixLength...])
        guard let text = decodeV2(raw, encoding: enc) else { return nil }
        let converted = convert(text)
        if converted == text && (enc != 0 || EncodingDetector.isASCII(raw)) { return nil }

        var out: [UInt8] = [version == 4 ? 3 : 1]
        out += payload[1..<prefixLength]
        if version == 4 {
            out += Array(converted.utf8)
        } else {
            let parts = converted.components(separatedBy: "\0")
            for (index, part) in parts.enumerated() {
                if index > 0 { out += [0, 0] }
                if part.isEmpty && index == parts.count - 1 && index > 0 { continue }
                out += [0xFF, 0xFE]
                for unit in part.utf16 { out += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            }
        }
        return out
    }

    private func decodeV2(_ data: Data, encoding: UInt8) -> String? {
        switch encoding {
        case 0:
            // 宣告為 ISO-8859-1，但中文 MP3 常常其實是 GBK / BIG5
            if EncodingDetector.isASCII(data) { return String(decoding: data, as: UTF8.self) }
            return EncodingDetector.decode(data)?.text ?? String(data: data, encoding: .isoLatin1)
        case 1:
            // 可能有多段字串，每段都有自己的 BOM
            return splitUTF16(data).map { segment -> String in
                var bigEndian = false
                var seg = segment
                if seg.count >= 2 {
                    if seg[0] == 0xFE && seg[1] == 0xFF { bigEndian = true; seg.removeFirst(2) }
                    else if seg[0] == 0xFF && seg[1] == 0xFE { seg.removeFirst(2) }
                }
                return String(data: Data(seg), encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian) ?? ""
            }.joined(separator: "\0")
        case 2:
            return splitUTF16(data).map { String(data: Data($0), encoding: .utf16BigEndian) ?? "" }.joined(separator: "\0")
        case 3:
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    private func splitUTF16(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var parts: [[UInt8]] = []
        var current: [UInt8] = []
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                parts.append(current)
                current = []
            } else {
                current += [bytes[i], bytes[i + 1]]
            }
            i += 2
        }
        parts.append(current)
        return parts
    }

    private func syncsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        (Int(a & 0x7F) << 21) | (Int(b & 0x7F) << 14) | (Int(c & 0x7F) << 7) | Int(d & 0x7F)
    }

    private func be32(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    private func toSyncsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    private func toBE32(_ n: Int) -> [UInt8] {
        [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    }
}
