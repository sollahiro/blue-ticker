# バージョン管理

## 番号の付け方

バージョンは `YY.M.Micro` 形式にする。

- `YY`: 西暦下2桁（例: 2026年 → `26`）
- `M`: 月。ゼロ埋めしない（5月 → `5`、`05` は使わない）
- `Micro`: 同じ月内のリリース番号。月内初回は `0`

例: 2026年5月の初回リリースは `26.5.0`。

| 変更内容 | 上げ方 | 理由 |
|---|---|---|
| 月が変わった初回リリース | `YY.M.0` | 日付ベースのリリース識別 |
| 同じ月内の追加リリース | `Micro` を +1 | derived キャッシュを確実に無効化するため |

バージョンの単一の真実源は `Sources/BlueTicker/Constants/Version.swift` の `blueTickerVersion`。CLI の `--version`・MCP サーバー・derived キャッシュの `_cache_version` はすべてこの定数を参照する。したがって、同じ月内でも `Micro` を上げると derived キャッシュは再生成される。

外部取得キャッシュ（`analysis_cache/external/`）は原則としてグローバルバージョンに連動させない。TTL、取得日、外部API用の個別バージョンで管理する。

## リリース手順

バージョン更新を依頼されたら、以下のステップをすべて実行すること。

0. **バンプは機能コミットとは分離し、後続の独立コミットとして行う**
1. **リリース対象のコミットを main へプッシュし、CI（macOS + Linux）がグリーンであることを確認する**
   - ローカルの `swift test` 合格だけでタグを切らない。CI のツールチェーンはローカルより古く、ローカルで通るコードが CI で落ちることがある（実例: swift-testing マクロと SwiftSoup の `Comment` 型衝突で v26.6.1/26.6.2 を破棄）
2. `Sources/BlueTicker/Constants/Version.swift` の `blueTickerVersion` を更新する
3. バンプコミットを作成する（`chore: bump version to YY.M.Micro`）
4. タグを作成する（`git tag vYY.M.Micro`）
5. コミットとタグをリモートへプッシュする

```bash
git push origin main
git push origin vYY.M.Micro
```

- `git push origin main` ではタグは送られない。**タグは必ず `git push origin <tag>` で明示的にプッシュする**
- タグをプッシュすると `release.yml` が `swift build -c release` でバイナリを生成し、GitHub Release と Homebrew tap を更新する
- タグは軽量タグ（annotated 不要）で統一
- **既存タグの付け直しは禁止**。必ず新しいバージョンに上げて新タグを切ること
  - タグを付け直すと GitHub が tarball を再生成して SHA256 が変わり、Homebrew formula との checksum 不一致が発生する
- タグ後に間違いを見つけた場合もタグを削除せず、バージョンを上げて新タグを切ること

## キャッシュバージョンの埋め込み（derived キャッシュ）

derived キャッシュには `_cache_version` フィールドを埋め込み、`blueTickerVersion` と照合することで古いキャッシュの混入を防ぐ。

```swift
private let _cacheVersion = blueTickerVersion  // 例: "26.6.0"

// 保存時
dict["_cache_version"] = _cacheVersion

// 読み込み時
if let c = cached, (c["_cache_version"] as? String) == _cacheVersion {
    return c  // _cache_version を除いて返す
}
// バージョン不一致 → フォールスルーして再取得・上書き
```

## Neon キャッシュバージョン（グローバル非連動）

`blt-server` の Neon テーブルの staleness 判定は **`blueTickerVersion` と独立した専用定数**で行う。ローカル derived とコスト構造が逆（再生成に EDINET からの XBRL 再ダウンロード＋再パース／再計算が伴い高コスト）なため、月内 Micro バンプで毎回全件再 ingest が走らないよう、グローバルバージョンから切り離している。Stage 3・Stage 4 で別定数を持つ。

| テーブル | 定数 | 置き場所 | 現在値 |
|---|---|---|---|
| `edinet_xbrl_facts`（Stage 3 RAW） | `xbrlFactsCacheVersion` | `Models/XbrlFactRecord.swift` | `"facts-v1"` |
| `company_financials`（Stage 4 derived） | `companyFinancialsCacheVersion` | `Models/FinancialsContract.swift` | `"fin-v4"` |
| （同上・read 床） | `companyFinancialsMinServableVersion` | 同上 | `2`（`fin-v2` 以上を 200） |
| `company_half_financials`（Stage 4-half derived） | `companyHalfFinancialsCacheVersion` | `Models/HalfFinancialsContract.swift` | `"half-v2"` |
| （同上・read 床） | `companyHalfFinancialsMinServableVersion` | 同上 | `1`（`half-v1` 以上を 200） |
| `company_filing_sections`（Stage 5 有報セクション本文） | `filingSectionsCacheVersion` | `Models/FilingSectionsContract.swift` | `"sections-v2"` |
| （同上・read 床） | `filingSectionsMinServableVersion` | 同上 | `1`（`sections-v1` 以上を 200） |
| `company_segment_breakdowns`（Stage 6 事業別内訳。business 軸のみ） | `segmentBreakdownCacheVersion` | `Models/SegmentBreakdownContract.swift` | `"breakdown-v2"`（ingest/CLI(`--stages 6`)/REST(`segment-breakdown`)/MCP(`get_segment_breakdown`) 配線済み。対象は日経225構成銘柄限定。geography 軸は未配線。詳細は `docs/segment-normalization-concept.md`） |
| （同上・read 床。xbrl_facts 経由のみ適用） | `segmentBreakdownMinServableVersion` | 同上 | `1`（`breakdown-v1` 以上を 200。LLM 経由の行は cache_version でゲートしない） |

### バンプ規則

いずれも `blueTickerVersion` のバンプでは上げない。次のときのみ上げる。

- `xbrlFactsCacheVersion`: XBRL fact のパースロジック（`parseXbrlFactIndex`）、または RAW スキーマ（`XbrlFactRecord` / `XbrlFactIndexPayload`）を変更したとき
- `companyFinancialsCacheVersion`: 財務計算ロジック（`computeFinancials` / `Analysis` 抽出器）、または公開契約型（`FinancialsResponse` / `FinancialsYear`）の意味を変更したとき
- `companyFinancialsMinServableVersion`: **serving ポリシー変更**（再計算トリガーではない）。financials read が 200 を返す最低世代 N を人手で上げるとき。現行から N つ前の機械オフセットにはしない。引き上げは該当旧版の stale 消化完了後（servable 穴を作らない）。不変条件: 床 ≤ 現行 `fin-vN` の N。比較は数値パース（文字列辞書順禁止）
- `companyHalfFinancialsCacheVersion`: 半期計算ロジック（`HalfYearAnalyzer` / `buildH2Entry` / `EdinetDiscovery` の書類マッチング等、計算対象ドキュメントの選定を含む）、または公開契約型（`HalfFinancialsResponse` / `HalfFinancialsPeriod`）の意味を変更したとき
- `companyHalfFinancialsMinServableVersion`: **serving ポリシー変更**（再計算トリガーではない）。half financials read が 200 を返す最低世代 N を人手で上げるとき。規則は financials 床と同型（`half-v2` バンプ時に導入・床は `1` のまま据え置き）
- `filingSectionsCacheVersion`: セクション抽出ロジック（`XBRLParser.extractSections` / `SegmentExtractor` / `cleanText` の cap 等）、または格納契約型（`FilingSectionsPayload` / `SegmentPayload`）の意味を変更したとき。**セクションの「追加」はバンプ不要**（`section_keys` 列の不一致で当該行のみ自動再抽出される）
- `filingSectionsMinServableVersion`: **serving ポリシー変更**（再計算トリガーではない）。filing-content read の最低世代 N。規則は financials 床と同型
- `segmentBreakdownCacheVersion`: xbrl_facts 経路の分類・正規化ロジック（`SegmentNormalizer` / `Xbrl.segmentSubtotalMemberNames` 等の member 分類定数）、または `BreakdownSnapshotPayload` の意味を変える破壊的変更のとき。LLM 経由の行（source ≠ `xbrl_facts`）はバンプだけでは再計算しない（needs_review=false の行は据え置き。詳細は `docs/segment-normalization-concept.md`「今後の検討事項8」）
- `segmentBreakdownMinServableVersion`: **serving ポリシー変更**（再計算トリガーではない）。xbrl_facts 経由の行にのみ適用（LLM 経由は常に servable。規則は financials 床と同型）

### 運用上の注意（バンプ時の一度きり再 ingest）

`companyFinancialsCacheVersion` / `filingSectionsCacheVersion` 等の**現行版**を上げると、既存の Neon 行は全件が一度だけ stale 判定され、次回 `blt-server ingest` で再パース／再計算される。これは想定どおりの移行コスト。XBRL ダウンロードが重い（9MB/件）ため、必要なら `--limit` でバッチ分割して取り込む。

Stage 4 / Stage 5 read は現行版完全一致ではなく各 min servable 以上を返すため、現行版バンプ直後も床以上の旧行は 200 のまま（バンプの崖を避ける）。ingest は引き続き現行版へ収束する。
