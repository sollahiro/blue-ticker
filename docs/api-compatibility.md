# REST API 互換ポリシー（段階 A）

自社向け REST 本線化（段階 A）の契約ルール。第三者公開（段階 B）では deprecation 期間などを足す前提で、いまはゆるく運用する。

構想全体は `docs/public-api.md`（段階 B）。段階 A の契約は本ファイルと `api-auth.md` / `architecture.md`。内部の Neon `cache_version` / read 床は本ポリシーの対象外（`.agents/rules/versioning.md`）。

## 原則

1. **普段は追加中心** — 既存クライアントが知らなくてよいフィールド・エンドポイントの追加は互換
2. **たまってから明示付きで再編** — 削除・改名・型変更・意味変更はまとめて行い、breaking として版を上げる
3. **契約の正は REST** — 互換判断も REST 応答を基準にする。開発用 MCP ツールは REST を写すだけであり、MCP 単独の契約変更はしない

## 互換対象（段階 A）

| 対象 | 段階 A の扱い |
|---|---|
| 成功レスポンス JSON のフィールド（形・型・意味） | **厳格な互換対象** |
| URL パスの大きな再編 | breaking 時のみ `/v2` 等（下記） |
| クエリ名、HTTP ステータスの意味、エラーボディ形 | **努力目標**（意図なく壊さない。厳格対象外） |

## 互換 / breaking の判定

| 変更 | 分類 | 対応 |
|---|---|---|
| フィールド・エンドポイントの追加 | 互換 | `schema_version` 据え置き可。changelog に一言 |
| フィールドの削除・改名 | breaking | 該当契約の `schema_version` を上げる |
| 型の変更（例: number → string） | breaking | 同上 |
| 意味の変更（例: 千円→円、定義変更） | breaking | 同上（形が同じでも breaking） |
| 値の追加（enum 的な文字列の新値） | 原則互換 | 未知値を落とさず無視できるクライアントを推奨 |
| ルートの統廃合・リソース切り直し | breaking（大きい） | URL メジャー（`/v2`）を検討 |

## バージョンの出し方

### 応答 `schema_version`（主）

- 契約ごと（financials 等）に独立採番する整数
- **フィールド単位の breaking** では、影響する契約の `schema_version` だけを上げる
- URL は `/v1` のままでよい
- 現行値の定義箇所例: `Api.financialsSchemaVersion`（`Sources/BlueTicker/Constants/Api.swift`）

### URL メジャー（例外）

- パス構造の再編など、`schema_version` だけではクライアント切替が分かりにくいときに使う
- 普段のフィールド再編では使わない

### 移行の望ましい形（必須ではない）

breaking 再編時は可能な範囲で:

1. 新旧キーをしばらく併存（この間は互換として扱えることが多い）
2. changelog で旧キー廃止予定を書く
3. 旧キー削除時に `schema_version` を上げる

段階 A では固定の「N 日 / N リリース併存」は定めない。段階 B で期間を足す。

## 対象外・混同しないもの

| もの | 理由 |
|---|---|
| Neon `cache_version`（`fin-vN` 等）・min servable 床 | ingest / 配信世代の内部制御。公開契約に漏らさない |
| `blueTickerVersion`（配布物バージョン） | CLI / キャッシュ用。REST `schema_version` とは独立 |
| facts RAW | 非公開 |

## 変更時の運用（段階 A）

- breaking なら該当 `schema_version` 定数を上げ、PR / コミットで分かるようにする
- 互換追加も含め、契約に触る変更は短いメモを残す（PR 説明または関連 docs）
- 開発用 MCP の入出力を変える必要が出ても、先に REST 契約を決める。MCP を製品面として拡張しない

## 変更メモ（段階 A）

- Notes の `lease_liabilities` / `borrowings_schedule` を REST / MCP / skills / `--note-types` / ingest から外した（breaking。`apiSkillsSchemaVersion` 4）。未知 note_type と同じ 404（reason 無し、retired breakdown 軸と同型）。パーサは残し、有利子負債の正本は breakdown 軸 `interest_bearing_debt`。`fin-vN` / `breakdown-interest-bearing-debt-v2` / 組立指紋は据え置き。
- Notes の `property_plant_equipment_schedule` / `goodwill_and_intangibles` を同じ形で外し、breakdown 軸 `property_plant_equipment` / `goodwill_and_intangibles` を追加した（breaking。`apiSkillsSchemaVersion` 5）。軸の行は種類別の正味帳簿価額（`amount`・`source_tag`）、小計は `row_kind=subtotal`。日本基準の `available_via_statement` に当たる reason は breakdown に無く、`not_found` になる。job-03（notes-heavy）は廃止。
- `GET /v1/companies/{code}/statement/notes`（MCP `get_statement_notes`）を廃止し、`GET /v1/companies/{code}/shares`（MCP `get_shares`）を追加した（breaking。`apiSkillsSchemaVersion` 6）。shares は {code, doc_id, items}（key = `eps` / `diluted_eps` / `bps` / `issued_shares`）。旧パスは常に 404。資本金・資本準備金・推移の表は公開も取り込みもしない（新規行は期末の発行済株式総数だけ）。`notes-issued-shares-and-capital-v1`・組立指紋・`fin-vN`・`company_statement_notes` のテーブルは据え置き（期末値は不変のため再 ingest・再組立を起こさない）。Feed Trend の tool 名は `get_shares`（Worker は旧名も受ける）。
- shares に IFRS の継続事業・非継続事業別 EPS（key `continuing_eps` / `discontinued_eps` / `continuing_diluted_eps` / `discontinued_diluted_eps`）を足した（互換追加。同じ書類の格納済み statement から取る）。statement の IFRS 1株当たり利益の行の `label` を標準タクソノミの冗長ラベルにした（値・行数は不変。`statement-v3` は据え置き、旧行は該当 code の再取り込みで直す）。
- breakdown に軸 `segment`（報告セグメント表）を足し、`product_service` を関連情報・収益分解の製品表だけにした（意味変更は breaking。`apiSkillsSchemaVersion` 7、`breakdown-product_service-v2`、`breakdown-segment-v1`、`breakdown-geography-v14`）。任意フィールド `segment_basis` / `disclosure_basis` / `same_as` / `employees_join` は互換追加。報告セグメント facts を geography にコピーしない。旧 `product_service` の `xbrl_facts` 行は再 ingest で `segment` へ移す。
- breakdown 軸 `goodwill` を名前付きセル opening / closing / amortization / impairment に変え、`goodwill_amortization` を REST / MCP / skills から外した（breaking。`apiSkillsSchemaVersion` 8、`breakdown-goodwill-v3`、read 床 3）。旧 amount 行は再 ingest まで 404。`fin-vN` / `screen-vN` は据え置き。セル分母の `status`（`disclosed` / `none_disclosed`）と行の `in_total` は v3 の配信前に足した（同じ schema 8 のまま）。
- 金額を全エンドポイントで通貨の基本単位（円・ドル）に揃え、単位を応答に載せた（breaking。`apiSkillsSchemaVersion` 9、financials / waterfall `schema_version` 3、statement 2、screen snapshot 2）。financials / waterfall は百万円の小数を基本単位の整数にし、トップの `unit` を `units`（キー → 単位コード）に替え、`years[].currency`（ISO 4217）を足した（`fields` で絞っても残る）。トップの `currency` は全年度が同じ通貨のときだけ値を持つ。waterfall の `dso_change_impact` / `dio_change_impact` / `dpo_change_impact` は `ccc_dso_effect` / `ccc_dio_effect` / `ccc_dpo_effect` に改名した（日。和が `ccc_change` になる向き）。statement の行 `unit` は unitRef（JPY / JPYPerShares / yen）から単位コードへ、年度に `currency`。shares の行 `unit` は `currency_per_share` / `shares`、トップに `currency`。screen は sales / cfo / fcf を円で返し、`*_min` / `*_max` も円で受ける。breakdown は互換追加で `currency` と `unit`（employees は persons）。単位コードは `currency_amount` / `currency_per_share` / `shares` / `persons` / `percent` / `percentage_points` / `times` / `days`（`AmountUnit.Code`）。格納値（`company_financials` / `screen_index` は百万円のまま）と `fin-vN` / `screen-vN` は据え置き、変換は read 時だけ。外貨建て開示（6269 の USD）は通貨を持つ前の格納行が JPY と読まれるので、該当 code の再取り込みで直す。

## Codable 応答への段階移行

新規 REST エンドポイントは専用の `Codable` / `Sendable` 応答型を定義し、内部モデルから写像する。キー名は `CodingKeys` に集約する。開発用 MCP は同じ契約を再利用する。

- Optional の自動合成 `encodeIfPresent` は nil のキーを省略する。必須 nullable キーには `encode(_:forKey:)`（Optional の nil を null として符号化）または `encodeNil(forKey:)` を使う。
- 既存の疎な保存 JSON はデコード可能なままにする。`0`・空文字・空配列・null・欠落を相互に置換しない。
- 移行前に `Spec/Contract` へ固定の JSON 期待値を追加し、キー集合・値の型・null・`fields` 射影・エラー形を該当範囲で検証する。期待値を実装の `CodingKeys` だけから生成しない。固定 JSON のキー集合と `CodingKeys.allCases` も突き合わせ、encode 漏れと期待値漏れを両方拾う。
- `FinancialsYear` は最初の移行対象。`encode(to:)` を `CodingKeys` 網羅 switch にし、直接の Codable エンコードでも全キーを出す。Summary / Waterfall の射影と REST 応答の意味は維持するため、`schema_version` / `cache_version` は変更しない。
- REST ルートと MCP の動的な封筒、Waterfall の派生値、外部 API の JSON は後続の個別移行対象とする。境界アダプターの `JSONSerialization` は残せるが、新しい応答組立を辞書へ広げない。非 Sendable 辞書を運ぶ回避策も、型付き境界への移行と一緒に除く。

## 段階 B で足す予定

- 第三者向けの deprecation 期間（日数またはリリース数）
- 外部向け changelog / OpenAPI との突合
- クエリ・ステータス・エラー形を厳格対象に上げるかの再検討
