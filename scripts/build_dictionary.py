#!/usr/bin/env python3
"""合併 Resources/dictionaries/ 下的各詞彙表，產生 Resources/Dictionary.csv。

格式沿用原版 ConvertZZ：Enable<TAB>Type<TAB>簡體<TAB>優先<TAB>繁體<TAB>優先
Type 以 "ST:" 開頭的只用於簡→繁，"TS:" 開頭的只用於繁→簡，其餘雙向。
同一個 key 先出現者優先，所以輸出順序就是優先順序：
  簡→繁：自訂修正 > ConvertZZ 原版 > OpenCC 台灣用詞 > MediaWiki 台灣 > OpenCC 詞組
          > MediaWiki 簡繁 > OpenCC 單字
  繁→簡：ConvertZZ 原版 > OpenCC 詞組 > MediaWiki 繁簡 > OpenCC 單字
簡→繁的結果會再套用 OpenCC 台灣異體字（爲→為、着→著…）。
MediaWiki 只採用詞組，單字一律以 OpenCC 為準。
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Resources" / "dictionaries"
OUT = ROOT / "Resources" / "Dictionary.csv"


def is_cjk_text(s):
    return any(0x2E80 <= ord(c) for c in s) and "\t" not in s and "\n" not in s


def opencc(name):
    for line in (SRC / "opencc" / f"{name}.txt").read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        key, values = line.split("\t", 1)
        yield key, values.split(" ")[0]


tw_variants = dict(opencc("TWVariants"))
ts_chars = dict(opencc("TSCharacters"))


def to_tw(s):
    return "".join(tw_variants.get(c, c) for c in s)


def simplify_chars(s):
    return "".join(ts_chars.get(c, c) for c in s)


def main():
    rows = []
    seen = {"ST": set(), "TS": set()}

    def add(kind, simp, trad):
        if not simp or not trad or not is_cjk_text(simp + trad):
            return
        # 單向的列若在該方向已有同一個 key，就不必再寫
        if kind.startswith("ST:") and simp in seen["ST"]:
            return
        if kind.startswith("TS:") and trad in seen["TS"]:
            return
        if not kind.startswith("TS:"):
            seen["ST"].add(simp)
        if not kind.startswith("ST:"):
            seen["TS"].add(trad)
        rows.append(f"True\t{kind}\t{simp}\t0\t{trad}\t0")

    for line in (SRC / "UserFix.tsv").read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            s, t = line.split("\t")
            add("ST:UserFix", s, t)

    for line in (SRC / "ConvertZZ.csv").read_text(encoding="utf-8-sig").splitlines():
        cols = line.split("\t")
        if len(cols) == 6 and cols[0] == "True":
            add(cols[1], cols[2], cols[4])

    mw = json.loads((SRC / "mediawiki" / "zhcdict.json").read_text(encoding="utf-8"))

    # 台灣用詞的 key 是繁體，轉成簡體 key 以便一次轉換
    for t, tw in opencc("TWPhrases"):
        add("ST:OpenCC-TWPhrases", simplify_chars(t), to_tw(tw))
    # MediaWiki 的單字對照（面→麵、里→裡、喂→餵…）脫離上下文時常常是錯的，只採用詞組
    for k, v in mw["zh2TW"].items():
        if len(k) > 1:
            add("ST:MediaWiki-zh2TW", simplify_chars(k), to_tw(v))
    for s, t in opencc("STPhrases"):
        add("ST:OpenCC-STPhrases", s, to_tw(t))
    for s, t in mw["zh2Hant"].items():
        if len(s) > 1:
            add("ST:MediaWiki-zh2Hant", s, to_tw(t))
    for s, t in opencc("STCharacters"):
        add("ST:OpenCC-STCharacters", s, to_tw(t))

    for t, s in opencc("TSPhrases"):
        add("TS:OpenCC-TSPhrases", s, t)
    for t, s in mw["zh2Hans"].items():
        if len(t) > 1:
            add("TS:MediaWiki-zh2Hans", s, t)
    for t, s in opencc("TSCharacters"):
        add("TS:OpenCC-TSCharacters", s, t)
    # 台灣異體字也要能轉回簡體
    for v, tw in tw_variants.items():
        add("TS:OpenCC-TWVariants", simplify_chars(v), tw)

    OUT.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"{len(rows)} rows -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
