# Feed

Feed は、既存の Struct / Norm / Viz のデータを時系列・集約して配信する Class である。REST を契約の正本とし、MCP は追従面、RSS は Feed の XML 投影とする。

## Feature

| Class | Module | Tier | 内容 |
|---|---|---|---|
| Feed | Trend | Free | 検索数の多い銘柄・検索トレンド |
| Feed | Update | Free | 新規取得・公開された有報などの更新情報 |
| Feed | Status | Free | Feature 単位のデータ鮮度・カバレッジ |
| Feed | Report | Paid | 事前生成済みの LLM 企業分析レポート |

`Report` は `Summary` や `Statement` と同じデータ粒度ではない。公開上は Feed の Paid Module として扱い、内部では Struct / Norm / Viz の情報から生成する保存済み分析成果物として扱う。

## 配信面

### REST

予定する入口:

```text
GET /v1/feed/trend
GET /v1/feed/update
GET /v1/feed/status
GET /v1/feed/report
```

企業単位の保存済み Report は次の入口を候補とする:

```text
GET /v1/companies/{code}/report
```

Report のオンデマンド生成 API（`POST`）は作らない。生成は ingest 時に行い、Read は保存済みデータだけを返す。未生成の Report は 404 とする。

### MCP

REST と同じデータソース・認可境界を使う。予定するツール:

```text
get_feed_trend
get_feed_updates
get_feed_status
get_feed_reports
get_company_report
```

Feed 用の別集計ロジックや、MCP 専用の Report 生成ロジックは持たない。

### RSS

RSS を提供するのは Trend と Update とする。

```text
GET /feeds/trend.xml
GET /feeds/update.xml
```

Status RSS は提供しない。Status は現在値を REST / MCP で返し、履歴は保存しない。

Report 本文は RSS に含めない。Report の更新通知は Update Feed に `report_updated` として含める。

```text
<item>
  <guid isPermaLink="false">report-update-7203-2026</guid>
  <title>トヨタ自動車の企業分析レポートが更新されました</title>
  <description>最新の有価証券報告書をもとに分析レポートを更新しました。</description>
  <link>https://api.example.com/v1/companies/7203/report</link>
  <pubDate>...</pubDate>
</item>
```

Report の本文は Paid REST / MCP で取得する。Update RSS の通知自体は公開する。

RSS には stable GUID、`pubDate`、`lastBuildDate`、`ETag`、`Last-Modified`、`Cache-Control`、絶対 URL を付ける。

## Status

### 内部 Status と公開 Status の分離

現在の `blt-server status-report` は、ingest / DB 運用向けの内部集計である。`financials` や `filing_sections` などの内部 Stage 名は、公開 Status の単位にしない。

```text
内部 Status
  financials / filing_sections / breakdown_business / ...

公開 Status
  Struct/Filing
  Struct/Statement
  Norm/Summary
  Norm/Breakdown
  Viz/Waterfall
  Feed/Report
  ...
```

公開 Status は Feature Catalog を単位とし、内部テーブル名・Stage 名を返さない。

### 公開 Status の項目

Feature に応じて、次の項目を任意に持つ。

- `class`
- `module`
- `tier`
- `status`
- `scope`
- `coverage`
- `freshness`
- `window`

`coverage` や `freshness` が意味を持たない Feature に、無理に数値を付けない。

状態値は次を基本とする。

```text
not_started
partial
available
stale
degraded
complete
```

未実装・未 ingest の Feature を `0%` と表示しない。

### Status の保持

Status の履歴は保存しない。現在の DB / ingest 状態から公開時に集計する。

`status.html` は廃止予定であり、Feature Status API への移行後に次を削除する。

- `assets/apex-site/status.html`
- `scripts/generate-status-page.sh`
- `scripts/blt-scheduled-sync.sh` の Status Page 生成処理
- 各静的ページの `status.html` へのリンク

`blt-server status-report` は、当面は静的ページ生成から切り離した内部運用コマンドとして残してよい。

## Update

初期 Update は既存の `edinet_documents` を利用して、EDINET 提出情報を返す。

初期イベント:

```text
submitted
```

将来のイベント候補:

```text
submitted
synced
published
recomputed
report_updated
```

主なイベント項目:

- `id`
- `type`
- `code`
- `name`
- `title`
- `occurred_at`
- `available_at`
- `target`

`doc_id` を持つ EDINET 提出イベントは `doc_id` を stable GUID にする。同じ書類を同期し直しても、Update Feed に重複表示しない。

`report_updated` は Report 本文を含めず、対象企業・更新日時・Paid Read API へのリンクだけを返す。

## Trend

Trend は既存の検索結果から過去分を復元しない。計測開始後のイベントだけを対象とする。

初期の主指標は、検索結果から銘柄が選択された回数とする。検索 API のヒット数は、必要に応じて補助指標として扱う。

保存方針:

- 生の検索語を長期保存しない
- IP / Cookie 等の個人識別情報を保存しない
- 日次集計を基本とする
- 一定期間後に集計を削除する
- 計測開始日を公開する

## Report

### 初期スコープ

Report はすぐには実装しない。初期スコープは次のとおりとする。

- 対象企業: 日経225
- 対象書類: 最新の有価証券報告書
- 生成方式: ingest 時の事前生成
- 提供方式: 保存済み Report の Read
- 更新通知: Update Feed / Update RSS

### 入力

Report は、次の全層を入力候補とする。

```text
Struct
  Filing
  Statement
  Statement-Notes

Norm
  Summary
  Breakdown

Viz
  Waterfall
  Sankey（将来）
```

Report 生成時には、実際に使用した入力を manifest として記録する。未実装・未算出の Feature は推測で補完せず、未使用として扱う。

### 生成フロー

```text
最新有報の選定
    ↓
Struct / Norm / Viz の準備
    ↓
LLM Report 生成
    ↓
数値・出典検証
    ↓
DB 保存
    ↓
REST / MCP Read
    ↓
Update Feed へ更新通知
```

LLM 呼び出しは serving 経路で行わない。入力不足の場合は `not_ready` とし、後続 ingest で再試行する。

### 保存情報

Report 本文に加え、少なくとも次を保存する。

- `report_id`
- `company_code`
- `doc_id`
- `report_type`
- `period`
- `payload`
- `input_manifest`
- `input_hash`
- `prompt_version`
- `model`
- `generated_at`
- `source_references`
- `needs_review`

既存 Breakdown の `content_hash`、`source`、`needs_review`、監査情報の考え方を参考にする。ただし Report は Prompt / Model の変更も再生成条件になるため、入力バージョンと生成バージョンを分けて管理する。

### 保持

Feed の通知は短期保持でよいが、Report 本体はユーザー価値のある生成成果物として長期保存候補とする。

| データ | 方針 |
|---|---|
| Status | 履歴を保存しない |
| Trend | 日次集計を一定期間保持し削除 |
| Update | 一定期間のイベントを保持 |
| Report 本体 | 長期保存候補 |
| Report 更新通知 | Update と同じ保持期間 |

## 課金境界

Paid 対象は次の Feature とする。

```text
Norm/Breakdown
Viz/Waterfall
Viz/Sankey
Feed/Report
```

Report は LLM 費用が発生するため、既存の Monetize Gateway / Entitlement で REST と MCP の双方を制御する。Report の更新通知は公開するが、Report 本文は Paid Read とする。

## ロードマップ

### 1. Feature Status

- Feature Catalog 基準の公開 Status 契約を定義
- 内部 Stage と公開 Feature を分離
- REST `/v1/feed/status`
- MCP `get_feed_status`
- Status 履歴を保存しない

### 2. `status.html` 廃止

- Feature Status API と既存内部集計を比較
- scheduled sync から HTML 生成・Git push を削除
- 静的ページのリンクを削除
- `status.html` と生成スクリプトを削除
- `status-report` は内部運用用として必要性を確認

### 3. Feed/Update

- `edinet_documents` から提出 Feed を作る
- REST / MCP / RSS を提供
- `report_updated` 通知を Update に追加できる契約にする
- stable GUID と保持期間を定義

### 4. Feed/Trend

- 検索・銘柄選択イベントの計測
- 日次集計
- REST / MCP / RSS
- 集計の保持期間と削除

### 5. Report 設計

- Report の種類と章立てを定義
- Struct / Norm / Viz の入力 manifest を定義
- 出典・Prompt・Model・入力バージョンを定義
- 品質検証と `needs_review` を定義

### 6. Report ingest

- 日経225・最新有報の選定
- 入力 Feature の確認
- LLM 生成
- Report 保存
- 再生成判定
- Report カバレッジ集計

### 7. Feed/Report Read

- 企業別 Report Read
- Report Feed
- REST / MCP
- 未生成は 404
- serving 時の LLM 呼び出しなし

### 8. Paid 公開

- Monetize Gateway
- Breakdown / Waterfall / Sankey / Report の Entitlement
- Report 本文の Paid Read
- Update RSS の公開通知
