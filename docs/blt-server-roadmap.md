# blt-server ロードマップ

**方針・ゴール・非ゴールの索引**。構成は `docs/architecture.md`、手順は `.agents/skills/deploy/SKILL.md`、cache 床は各 Contract 定数（バンプ規則は `.agents/rules/versioning.md`）、経緯は Git。

サイクル段階・本番件数・公開ゲート・残作業の現在地は Linear（[JP 現在地](https://linear.app/sollahiro/document/jp-現在地-af2abd076034) / [公開と基盤 現在地](https://linear.app/sollahiro/document/公開と基盤-現在地-3bd56370454b)）。Git に件数や TODO チェックリストを置かない。

## 方針

- **REST `/v1` が契約の正**。製品面は REST と iOS。MCP は開発専用で凍結（コードは残す）。
- Core はサーバー専用にしない（テスト・ingest 計算と共有）。
- 第三者公開（段階 B）と x402 は `public-api.md`。機能単位の有料マスクは採らない。
- Summary の水準値は **Statement / Note / Breakdown → financials** 組立（`financials-summary-separation.md`）。Waterfall も同行走査のため同じ切替に乗る。

read 床・バンプ規則は `.agents/rules/versioning.md` のみ（ここへ値を書かない）。床の引き上げは旧版 stale 消化後。

## ゴール / 非ゴール

**ゴール**: ユーザー向け実行を blt-server（remote）へ集約（達成）。近傍は REST の安定と iOS。

**非ゴール**: 各サブコマンドへの backend 選択、床の「現行から N つ前」機械オフセット、`CacheManager` と EDINET external の無理な単一抽象化、数値 facts の Neon / R2 永続（生 XBRL L2 から再導出する。進捗は Linear Team `blue-ticker`）。MCP / ChatGPT Apps を製品面として伸ばすこと。

## 関連

`architecture.md` · `eu-esef-roadmap.md` · `public-api.md` · `api-auth.md` · `api-compatibility.md` · `ingest-policy.md` · `breakdown.md` · `statement.md` · `financials-summary-separation.md` · `ios-client.md` · `.agents/rules/versioning.md` · `.agents/skills/deploy/SKILL.md`
