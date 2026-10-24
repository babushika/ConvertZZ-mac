import XCTest
@testable import ConvertZZCore

final class ConvertZZCoreTests: XCTestCase {
    static let dictionaryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Dictionary.csv")
    static let converter = ChineseConverter(dictionaryURL: dictionaryURL)

    func testDictionaryLoaded() {
        XCTAssertGreaterThan(Self.converter.entryCount, 40000)
    }

    func testPhraseConversion() {
        let c = Self.converter
        XCTAssertEqual(c.convert("头发很长", .toTraditional), "頭髮很長")
        XCTAssertEqual(c.convert("我的软件", .toTraditional), "我的軟體")
        XCTAssertEqual(c.convert("頭髮很長", .toSimplified), "头发很长")
        XCTAssertEqual(c.convert("abc 123", .toTraditional), "abc 123")
    }

    func testDictionaryOnlyCSV() {
        let csv = "True\tSTPhrases\t后台\t0\t後臺\t0\r\nFalse\tSTPhrases\t测试\t0\tXX\t0\r\n"
        let c = ChineseConverter(csv: csv)
        XCTAssertEqual(c.entryCount, 1)
        XCTAssertTrue(c.convert("后台", .toTraditional).hasPrefix("後臺"))
    }

    func testEncodingDetection() throws {
        let text = "這是一個測試，我們來看看編碼是否正確。"
        let big5 = TextEncoding.big5.encode(text)
        XCTAssertEqual(EncodingDetector.decode(big5)?.encoding, .big5)
        XCTAssertEqual(EncodingDetector.decode(big5)?.text, text)

        let simp = "这是一个测试，我们来看看编码是否正确。"
        let gbk = TextEncoding.gbk.encode(simp)
        XCTAssertEqual(EncodingDetector.decode(gbk)?.encoding, .gbk)
        XCTAssertEqual(EncodingDetector.decode(gbk)?.text, simp)

        XCTAssertEqual(EncodingDetector.decode(Data(simp.utf8))?.encoding, .utf8)
    }

    func testTextFileToOutputFolder() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("简体歌词.txt")
        try TextEncoding.gbk.encode("这是一个测试").write(to: file)

        var options = ConversionOptions()
        options.overwrite = false
        FileProcessor(converter: Self.converter, options: options).process([file]) { _ in }

        let out = dir.appendingPathComponent(FileProcessor.outputFolderName).appendingPathComponent("簡體歌詞.txt")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "這是一個測試")
        // 原檔不動
        XCTAssertEqual(EncodingDetector.decode(try Data(contentsOf: file))?.text, "这是一个测试")
    }

    func testOverwriteRenamesFolders() throws {
        let dir = try tempDir()
        let sub = dir.appendingPathComponent("专辑")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("简单".utf8).write(to: sub.appendingPathComponent("说明.txt"))

        var options = ConversionOptions()
        options.overwrite = true
        FileProcessor(converter: Self.converter, options: options).process([sub]) { _ in }

        let out = dir.appendingPathComponent("專輯/說明.txt")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "簡單")
    }

    func testID3v23() throws {
        // ID3v2.3，TIT2 以 ISO-8859-1 宣告但實際存 GBK；另有 ID3v1
        let gbkTitle = [UInt8](TextEncoding.gbk.encode("后来"))
        let framePayload: [UInt8] = [0] + gbkTitle
        var frame: [UInt8] = Array("TIT2".utf8)
        frame += [0, 0, 0, UInt8(framePayload.count), 0, 0] + framePayload
        let bodySize = frame.count + 16
        var file: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, UInt8(bodySize)]
        file += frame + [UInt8](repeating: 0, count: 16)
        file += [UInt8](repeating: 0xFF, count: 64) // 假音訊資料
        var v1: [UInt8] = Array("TAG".utf8)
        let artist = [UInt8](TextEncoding.gbk.encode("刘若英"))
        v1 += [UInt8](repeating: 0, count: 30) + artist + [UInt8](repeating: 0, count: 30 - artist.count)
        v1 += [UInt8](repeating: 0, count: 128 - v1.count)
        file += v1

        let url = try tempDir().appendingPathComponent("song.mp3")
        try Data(file).write(to: url)

        let result = try ID3Converter(converter: Self.converter, direction: .toTraditional).process(fileAt: url)
        XCTAssertEqual(result, .converted)

        let out = [UInt8](try Data(contentsOf: url))
        // TIT2 改為 UTF-16 (encoding 1) 並轉為繁體
        let size = Int(out[17])
        XCTAssertEqual(out[20], 1)
        let title = String(data: Data(out[23..<(20 + size)]), encoding: .utf16LittleEndian)
        XCTAssertEqual(title, "後來")
        // 音訊資料保持不變
        XCTAssertEqual(Array(out[(out.count - 128 - 64)..<(out.count - 128)]), [UInt8](repeating: 0xFF, count: 64))
        // ID3v1 以 BIG5 寫回
        let v1Artist = Data(out[(out.count - 128 + 33)..<(out.count - 128 + 63)].prefix(while: { $0 != 0 }))
        XCTAssertEqual(TextEncoding.big5.decode(v1Artist), "劉若英")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
