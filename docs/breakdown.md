# Breakdown（ドメイン仕様）

企業間比較（同業の割合）と同一企業の期ごと推移が目的。**現行の正規化方針・再発防止の正本**（構想メモではない）。**同じ形の割合（軸・分母・外部売上）で並べること**が本体。行ラベルの会社間統一はしない。

関連: 抽出は `BreakdownExtractor`（`docs/xbrl-parsing.md`）、正本分離は `docs/financials-summary-separation.md`。

## 方針（確定）

- 事業再編・名称変更の過去遡及補正はしない。各期はその期の開示どおり。
- 会社間の行ラベル対応は必須にしない。比較は構造（軸・分母・割合）まで。
- `segments` / `geography` は開示ブロックの取り分け。事業×地域の両方が常にあることは保証しない。
- 原則指標は外部顧客売上。分母は連結の外部売上（調整後）。金融機関は別経路（粗利益等）。

## 抽出の二段

1. TextBlock 内 HTML 表 → `html_table`
2. dimension 付き数値 fact → `xbrl_facts`

| API キー | 意味 |
|---|---|
| `segments` | 報告セグメント（事業とも地域とも限らない） |
| `geography` | 地域別注記 |

## 再発防止（学びの要約）

1. 比較に必須な揃えは構造側。行ラベル一致は不要。
2. 売上系タグは候補リストで絞る（単一タグ決め打ち不可。IFRS でも表記が割れる）。
3. LLM が効くのは軸判定・変則表。入力帰属が壊れていると救えない。
4. 全社で事業×地域がある前提は置かない。
5. 正規化契約（スキーマ・分母・軸）が本体。LLM は契約への写像補助。
6. 小計・調整行の除外は名称より**数値判定**が頑健。単一セグメントでは数値近似だけで小計扱いにしない。
7. 銀行は `normalizeBankBasis`（分母は segment 小計のうち行合計に最も近い値。単純最大は不可）。単一セグメントは専用タグで検出。
8. 実装コストの重心は geography の `html_table`。`segments` は多くが `xbrl_facts`。
9. `segments` の軸は member 名キーワード。全一致→geography、0一致→business、特定地域名の部分一致のみ混在扱いで `needs_review`（Domestic/Overseas だけの一致では立てない）。
10. 連結優先・非連結フォールバック必須。member ラベル選択は Dictionary 走査順に依存させない。
11. LLM の `profit == nil` だけでは未開示と見落としを区別できない → `profit_disclosed`＋決定的ガード。
12. LLM 行は `cache_version` バンプだけでは再計算しない（`needs_review` または削除）。`content_hash` は生入力＋分母のみ（プロンプト/モデルを含めない）。

## 契約・永続化（現行）

- 比較用スナップショット: `BreakdownSnapshot`（`BreakdownContract.swift` / `BreakdownNormalizer`）。
- 保存: `company_breakdowns`（filing-sections とは別。LLM 行を filing バンプに巻き込まない）。主キー `doc_id#axis`。
- `not_found` は行を作らない。business の E/F/unknown は `not_applicable` プレースホルダ。REST/MCP は 404＋ボディ `reason`（200 化しない）。
- 対象母集団: business/geography は上場全体（日経225は処理順の優先のみ）。employees / rd / goodwill は日経225。read は Fly 専用（ingest 時に LLM 計算）。処理順は日経225 → ローカル XBRL 展開済み → 欠測/要再試行/版ずれのラウンドロビン（軸ごとにキャッシュ集合を取り直す）。
- 分母は現状 `company_financials` 依存 → **正本分離で解消予定**。

## 残課題

- 分母の financials 逆依存解消
- employees / rd / goodwill 軸の公開・配線
- geography の巨大注記内での見出し・表の意味関連性の限界
- LLM 生ログ全文の別テーブル保持（任意）

## 非目標

過去セグメント遡及組替、会社間ラベル統一、全期の事業×地域完全充足、生 XBRL 一発 LLM 抽出。
