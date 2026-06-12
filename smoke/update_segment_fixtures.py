"""セグメント抽出ゴールデンファイル（segment_expected.json）を再生成する。

tmp_cache/edinet/ 配下の展開済み XBRL（prepare_cache.py / prepare_half_cache.py で準備）
に対して Python 実装の抽出結果を保存する。Swift 側の SegmentExtractorTests が
このファイルと照合してパリティを検証する。

実行: poetry run python smoke/update_segment_fixtures.py
"""

import json
from pathlib import Path

from blue_ticker.analysis.segment_extractor import extract_segment_info, extract_geography_info

from _common import edinet_cache_dir

OUTPUT = Path(__file__).parent / "segment_expected.json"


def main() -> None:
    base = edinet_cache_dir()
    out = {}
    for d in sorted(base.glob("*_xbrl")):
        doc_id = d.name.removesuffix("_xbrl")
        seg = extract_segment_info(d)
        geo = extract_geography_info(d)
        out[doc_id] = {"segments": seg, "geography": geo}
        print(
            f"{doc_id} seg: {seg['method']} {len(seg['tables'])} tables {len(seg['facts'])} facts"
            f" | geo: {geo['method']} {len(geo['tables'])} tables {len(geo['facts'])} facts"
        )
    OUTPUT.write_text(json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    print(f"wrote {OUTPUT} ({len(out)} docs)")


if __name__ == "__main__":
    main()
