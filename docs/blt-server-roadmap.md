# blt-server ロードマップ

**方針・ゴール・非ゴールの索引**。構成は `architecture.md`、手順は `deploy.md` / `operations.md`、cache 床は各 Contract 定数（バンプ規則は `.agents/rules/versioning.md`）、経緯は Git。

サイクル段階・本番件数・公開ゲート・残作業の現在地は Linear（[JP 現在地](https://linear.app/sollahiro/document/jp-現在地-af2abd076034) / [公開と基盤 現在地](https://linear.app/sollahiro/document/公開と基盤-現在地-3bd56370454b)）。Git に件数や TODO チェックリストを置かない。

## 方針

- **REST `/v1` が契約の正**。MCP は追従面。新機能は REST 先。
- Core はサーバー専用にしない（テスト・ingest 計算と共有）。
- 第三者公開（段階 B）と x402 は `public-api.md`。機能マトリクス・提供面は `feature-tiers.md`（機能単位の有料マスクは採らない）。
- Summary の水準値は **Statement / Note / Breakdown → financials** 組立。IBD の notes リース欠測埋めは `fin-v6`。値の意味が変わらない IA 切替では financials をバンプしない。Extractor の符号・抽出意味が変わったら上げる（`fin-v14`: 業種別本表タグ（RWY/ELE/SEC/OperatingRevenueRevenue2IFRS/InsuranceRevenueIFRS）を売上候補に追加。`fin-v13`: IFRS 1計算書方式 `…ComprehensiveIncomeSingleStatement…` を PL role に含め Summary sales/OP 欠落を解消。`fin-v12`: NTT 本表 `OperatingRevenuesIFRS` を売上候補に追加。`fin-v11`: US-GAAP Summary 純資産が単独ラベル「資本合計」も採用。`fin-v10`: US-GAAP Summary 売上が中間の「〜売上高」より営業収益計 / 収益合計を優先。`fin-v9`: Summary に BPS。`fin-v8`: IFRS `TotalNetRevenuesIFRS` を売上候補に追加。`fin-v7`: US-GAAP 自己株式取得の絶対値）。Waterfall も同行走査のため同じ切替に乗る。

read 床・バンプ規則は `.agents/rules/versioning.md` のみ（ここへ値を書かない）。床の引き上げは旧版 stale 消化後。

## ゴール / 非ゴール

**ゴール**: ユーザー向け実行を blt-server（remote）へ集約（達成）。

**非ゴール**: 各サブコマンドへの backend 選択、床の「現行から N つ前」機械オフセット、`CacheManager` と EDINET external の無理な単一抽象化、数値 facts の Neon / R2 永続（生 XBRL L2 から再導出する。Linear [BLT-23](https://linear.app/sollahiro/issue/BLT-23/facts-停止-ストレージ選定)）。

## 関連

`architecture.md` · `eu-esef-roadmap.md` · `public-api.md` · `api-auth.md` · `api-compatibility.md` · `deploy.md` · `ingest-policy.md` · `operations.md` · `breakdown.md` · `statement.md` · `financials-summary-separation.md` · `feature-tiers.md` · `ios-client.md` · `.agents/rules/versioning.md`
