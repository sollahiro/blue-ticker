# 現行版で消えた標準科目の日本語ラベル

旧版タクソノミで書かれた書類は、現行版（`../labels/`、2025-11-01）で廃止・改名された概念を使い続ける
（例: `jppfs_cor:RightOfUseAssets` は 2026年版で `RightOfUseAssetsPPE` 等に分かれた）。
現行版にも提出パッケージの `_lab.xml` にも無いため、Statement のラベルが空になる。

ここには、旧版の `_lab.xml` のうち **現行版に無い概念だけ** を抜き出して置く。
ingest は `../labels/` と任意のフル ZIP のあとに読み、欠測タグだけ埋める（現行ラベルは上書きしない）。

| ファイル | 出典 |
|---|---|
| `jppfs_2024-11-01_removed_lab.xml` | 2025年版 EDINETタクソノミ（タクソノミ日付 2024-11-01）`jppfs_2024-11-01_lab.xml` |
| `jpigp_2024-11-01_removed_lab.xml` | 同 `jpigp_2024-11-01_lab.xml` |

出典 ZIP: https://www.fsa.go.jp/search/20241112/1c_Taxonomy.zip

再生成: `python3 scripts/taxonomy/extract-removed-labels.py <旧版 _lab.xml> ../labels/<現行 _lab.xml> <出力>`
（jpcrp は現行版で消えた概念が無いので置かない）
