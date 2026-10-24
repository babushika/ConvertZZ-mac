# ConvertZZ for macOS

[ConvertZZ](https://github.com/flier268/ConvertZZ)（作者 flier268）的 macOS 原生版本，以 SwiftUI 重寫，主打**拖放即轉換**。

## 功能
- 把檔案或資料夾拖進視窗，或拖到 Dock 圖示上，就會開始轉換
- 簡體 ↔ 繁體，沿用原版的詞彙表 `Dictionary.csv`（約 5.4 萬筆，含台灣慣用詞）；詞彙表沒有的字交給 macOS 內建的 ICU 轉換
- 自動偵測 GBK / BIG5 / UTF-8 / UTF-16，可輸出 UTF-8、BIG5、GBK，或與原檔相同的編碼
- 轉換檔名、資料夾名稱
- 轉換 MP3 的 ID3v1 / v2.3 / v2.4 標籤（會修正 GBK / BIG5 被當成 Latin-1 的亂碼）
- 可以輸出到「ConvertZZ 輸出」資料夾（預設，不動原檔），也可以直接覆蓋原檔

## 下載
到 [Releases](../../releases) 下載 `ConvertZZ-macOS.zip`。App 沒有經過 Apple 公證，第一次開啟要在 Finder 中按右鍵 →「打開」。

## 自行建置
需要 macOS 13 以上與 Xcode 15 以上（或 Swift 5.9 以上的 Command Line Tools）。

```bash
swift test                # 執行單元測試
swift run ConvertZZ       # 直接執行（開發用）
./scripts/build-app.sh    # 產生 build/ConvertZZ.app
```

推送 `v*` 標籤（例如 `git tag v1.0.0 && git push --tags`）後，GitHub Actions 會自動建置並發佈 Release。

## 授權
GPL-3.0，與原專案相同。詞彙表來自原專案。
