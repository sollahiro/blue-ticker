# REST 第三者公開（段階 B）

段階 A（自社向け REST 本線・Service Token・配布 CLI 廃止）は達成済み。達成済みの契約は次に委譲する（本ファイルに再叙述しない）:

- 認証の住み分け → `api-auth.md`
- 互換ポリシー → `api-compatibility.md`
- クライアント面の現構成 → `architecture.md`

ロック: 2026-09-09 Sorahiro。HAPIS v0 は Cloudflare Access を転送してよい。以下の段階 B 認証は v0 のあと。

## 例外: 静的 RSS（EDINET 提出ヘッドライン）

`https://feed.sollahiro.com/blue-ticker/edinet-filings.xml` は認証なしの公開。2026-09-09 ロックに対する**狭い文書化済み例外**で、これ以外はすべて HAPIS + App Attest（段階 B）のまま。BLT origin は閉じたまま（`BLT_ALLOW_UNAUTHENTICATED` は使わない）。

- Cron Worker `workers/feed-rss` が日次（19:15 JST）に Neon を読み取り専用ロールで読み、R2 へ静的オブジェクトとして書く。配信は R2 カスタムドメイン
- ヘッドラインのみ（社名・書類種別・提出日時・決算期・コード・doc_id）と、会社アイコンの公開 URL（`media:thumbnail`。アイコンのある会社だけ）。アイコン URL を一覧で出すのはこの RSS だけで、アイコン専用のエンドポイントは公開しない（2026-10-19 Sorahiro）
- クエリパラメータなし。どのパスも origin / Neon へは届かない
- REST `/v1/feed/updates` が契約の正。RSS はその派生ビューで、RSS 2.0 の形以上の互換保証は持たない

詳細は `workers/feed-rss/README.md`。

## 取引先・関係会社（`GET /v1/companies/{code}/relations`）

有報の記載だけを返す（`basis` は常に `disclosed`）。推定・競合（`competitor`）は持たない。MCP には出さない。

- `type`（カンマ区切り。省略時は全種類）: `customer`（主要な顧客）· `supplier`（他社の主要な顧客欄に自社が載っている＝逆引き）· `group`（関係会社。`parent` / `subsidiary` / `affiliate` で絞れる。`other_related` は `group` のみ）· `investee`（政策保有株式。逆引きはしない）· `major_shareholder`（大株主）· `major_shareholder_of`（他社の大株主欄に自社が載っている＝逆引き）
- 逆引きは上場企業どうしだけ。相手側の有報の行で、`reasons` に `disclosed_by_counterparty`、`evidence.from_code` は相手のコード（`code` と違う。記載の主語は相手の会社）
- 応答: `{code, relations[], omitted[], next_cursor}`。要素は `type, kind, basis, company{code,name}|null, name_raw, reasons[], amount_yen, segment_label, voting_ratio, voting_ratio_basis, investee{shares,book_value_yen,purpose,is_deemed,holder}|null, major_shareholder{rank,shares,ratio}|null, evidence{doc_id,section,fy_end,from_code}`。nullable のキーも必ず出す
- `company` は上場企業に名寄せできたときだけ（決定論。候補が複数なら null で `name_raw` のみ）。Jev が区分を決めた行は `reasons` に `jev_classified`
- `reasons` には名前解決の結果も入る: `name_exact`（EDINET 提出者名の一致）· `name_en_exact`（英字名の一致）· `via_listed_parent`（相手は非上場で、ある上場会社の連結子会社として載っている名前。`company` はその親会社。例: 9409 の顧客「㈱電通」→ 4324）· `edinet_unlisted`（非上場の EDINET 提出者）· `ambiguous`（候補が複数。`company: null`）· `unresolved`。`via_listed_parent` は顧客・関連会社の行だけ（出資先・大株主・親会社には使わない）
- 何が載るか（有報の記載の範囲そのもの）:
  - `customer`: 売上高の 10% 以上を占める相手先だけ（それ未満の取引先は載らない）
  - `investee`: 政策保有株式（純投資目的以外）だけ。純投資の保有は載らない
  - `major_shareholder`: 名義株主の上位（信託口・外国名義・証券金融会社などを含む）。実質株主ではない。個人名も記載どおり返す
- 各行は各社の最新有報 1 件の記載で、時点（`evidence.fy_end`）は会社ごとに揃わない。逆引きは相手側の有報の時点
- 単位: `amount_yen` は円。`voting_ratio` は %（記載どおり。66.16 = 66.16%）で、向きは `voting_ratio_basis`: `owned`＝提出会社が相手の議決権を持つ割合（子会社・関連会社）、`owned_by`＝相手が提出会社の議決権を持つ割合（被所有。親会社・その他の関係会社）。`voting_ratio` が null なら null。`major_shareholder.ratio` は割合（XBRL の値。0.128 = 12.8%）
- `omitted`: 提出会社が記載を省略した type（例: 売上高の 10% 以上の相手先がない → `customer`）。「省略」と「未抽出」を区別する
- 出さないもの: Jev の `needs_review` 行、訂正 overlay 回帰の書類の行、大株主の住所、`needs_review` キー
- `limit`（既定 200・上限 1000）と `cursor`（前の応答の `next_cursor`。不透明な文字列で、同じ `type` の要求にだけ使える）
- 未知の `type`・不正なコード・不正な `cursor` は 400、公開できる行が無い（未取り込み含む）は 404、DB 非接続は 503

## 定義

素性不明の第三者が自分のアプリに組み込める API へ移ること。3軸:

| 軸 | 内容 |
|---|---|
| 公開入口 | **HAPIS** が公開ゲートウェイ。上流 BLT origin は HAPIS の後ろに閉じ、公開しない。blt-server は ingest / serve REST に閉じ、API 認証・Attest・短命トークン・レート制限・課金アカウントは持たない |
| 契約の安定化 | 後方互換の約束を厳格化（段階 B で deprecation 期間等を足す） |
| 利用制御 | レート制限は HAPIS。機械の従量は x402 |

機能単位の有料マスクは採らない。**段階 B の機械 REST は x402**。MCP は開発専用のため段階 B の x402 対象外であり、HAPIS の中核依存にもしない。

iOS のアカウント不要パス（短命匿名トークン + App Attest）はゲートウェイ責務であり、blt-server の責務ではない。

土台（バックフィル・ストレージ）が未成熟なうちに不特定多数へ開放しない。着手順・公開判断は Linear Team `blue-ticker`。定義の索引は `blt-server-roadmap.md`。

## 公開 REST の認証（階層ではなく併存）

origin API キーは持たない。iOS にトークン / Service Token を埋め込まない。

| 経路 | 認証 |
|---|---|
| iOS（アカウント不要） | HAPIS が短命の匿名トークンを発行。本番は App Attest 必須。blt-server は見ない |
| 任意 Bearer | 有料機能・ウォッチリスト同期が要るときだけ顧客アカウント |
| 機械 / エンドポイント直叩き | x402 |
| Web | 当面、アカウント不要の無料枠は出さない |
| MCP | Access OTP（開発）。HAPIS の中核依存にしない |

## 具体ロック

1. **開発例外:** `http://127.0.0.1` と LAN `http` は無認証・Attest なし（現行どおり）
2. **内部退避:** staging ホストは Access を残す。段階 B 着地後の本番公開扉は HAPIS のみ（本番公開ゲートウェイに Access を置かない）
3. **初期レート制限**（後で調整）: 軽い read 約 60/min、重い（filing-content）約 10/min、合算約 10k/day
4. **トークン:** TTL 約 1 時間。期限の約 5 分前にサイレント refresh
5. **Attest / トークン失敗:** 2〜3 回自動リトライのあと、キャッシュ表示 + 柔らかい「一時的に更新できない」。ハードブロックしない。Attest なしの緊急トークンは出さない

## 公開バー

既存の servable / min 床に合わせる。新しいカバレッジバーは作らない。servable 床は latest `cache_version` の全行と同義ではない。
