# EDINET 標準タクソノミ日本語ラベル

**2026年版 EDINETタクソノミ**（タクソノミ日付 **2025-11-01**。金融庁 2025-11-11 公表）。

ingest 時の標準 member / 勘定科目ラベル補完用。フルタクソノミ ZIP（約 105MB）は置かない。本番 ingest は手元 Mac の repo checkout からこれらのファイルを読む。

| ファイル | タクソノミ |
|---|---|
| `jpcrp_2025-11-01_lab.xml` / `jpcrp_dep_*` | 開示府令（`jpcrp_cor`。報告セグメント member を含む） |
| `jppfs_2025-11-01_lab.xml` / `jppfs_dep_*` | 財務諸表本表（`jppfs_cor`） |
| `jpigp_2025-11-01_lab.xml` / `jpigp_dep_*` | 国際会計基準（`jpigp_cor`） |

出典 ZIP: https://www.fsa.go.jp/search/20251111/1c_Taxonomy.zip

配置と読み込みは `docs/xbrl-parsing.md` §4。会社提出パッケージの `_lab.xml` が常に優先する。
