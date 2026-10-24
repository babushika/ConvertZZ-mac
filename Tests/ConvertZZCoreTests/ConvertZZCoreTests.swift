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

    /// macOS 內建轉換常出錯的詞
    func testKnownSystemTransformMistakes() {
        let cases = [
            "干活": "幹活", "干脆": "乾脆", "干政": "干政", "乌干达": "烏干達", "很脏": "很髒",
            "内脏": "內臟", "想象": "想像", "（注": "（註", "发现": "發現", "干干净净": "乾乾淨淨",
            "发明了": "發明了", "斗争": "鬥爭", "饼干": "餅乾", "宽松": "寬鬆", "克扣": "剋扣",
            "报道": "報導", "回避": "迴避", "冗余": "冗餘", "克什米尔": "喀什米爾", "加沙": "加薩",
            "吕后": "呂后", "朴正熙": "朴正熙", "牵制": "牽制", "系统": "系統", "余杰": "余杰",
            "征战": "征戰", "干嘛": "幹嘛", "干不下去": "幹不下去", "台面": "檯面", "轮回": "輪迴",
            "我在这里等你": "我在這裡等你", "着急地看着": "著急地看著", "他用鼠标打开了网络": "他用滑鼠打開了網路",
            "看视频": "看影片", "视频会议": "視訊會議", "视频聊天": "視訊聊天",
        ]
        for (simp, trad) in cases {
            XCTAssertEqual(Self.converter.convert(simp, .toTraditional), trad, simp)
        }
        XCTAssertEqual(Self.converter.convert("我們一起幹活", .toSimplified), "我们一起干活")
        XCTAssertEqual(Self.converter.convert("乾淨的衣服", .toSimplified), "干净的衣服")
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

    func testDocxSplitRuns() throws {
        // 「干」與「活」在不同的格式片段，必須整段一起轉換才會得到「幹活」
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
        <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>我们一起干</w:t></w:r><w:r><w:t xml:space="preserve">活 &amp; 头发</w:t></w:r></w:p>\
        <w:p><w:r><w:t>干净</w:t></w:r></w:p>\
        </w:body></w:document>
        """
        let core = """
        <?xml version="1.0" encoding="UTF-8"?><cp:coreProperties xmlns:cp="c" xmlns:dc="d"><dc:title>简体标题</dc:title></cp:coreProperties>
        """
        let dir = try tempDir()
        let src = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("word"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("docProps"), withIntermediateDirectories: true)
        try "<Types/>".write(to: src.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try document.write(to: src.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try core.write(to: src.appendingPathComponent("docProps/core.xml"), atomically: true, encoding: .utf8)
        let docx = dir.appendingPathComponent("测试.docx")
        try OfficeConverter.run("/usr/bin/zip", ["-q", "-r", docx.path, "."], in: src)

        var options = ConversionOptions()
        options.overwrite = true
        options.convertFileNames = false
        FileProcessor(converter: Self.converter, options: options).process([docx]) { _ in }

        let out = dir.appendingPathComponent("out", isDirectory: true)
        try OfficeConverter.run("/usr/bin/unzip", ["-q", docx.path, "-d", out.path])
        let xml = try String(contentsOf: out.appendingPathComponent("word/document.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("<w:t>我們一起幹</w:t>"), xml)
        XCTAssertTrue(xml.contains("<w:t xml:space=\"preserve\">活 &amp; 頭髮</w:t>"), xml)
        XCTAssertTrue(xml.contains("<w:t>乾淨</w:t>"), xml)
        XCTAssertTrue(xml.contains("<w:rPr><w:b/></w:rPr>"), xml)
        let props = try String(contentsOf: out.appendingPathComponent("docProps/core.xml"), encoding: .utf8)
        XCTAssertTrue(props.contains("<dc:title>簡體標題</dc:title>"), props)
    }

    func testDistribute() {
        XCTAssertEqual(OfficeConverter.distribute("幹活好", like: ["干", "活好"]), ["幹", "活好"])
        XCTAssertEqual(OfficeConverter.distribute("abcd", like: ["a", "b"]), ["abcd", ""])
        XCTAssertEqual(OfficeConverter.unescape("a&amp;b&#x4E2D;&#25991;&lt;"), "a&b中文<")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
