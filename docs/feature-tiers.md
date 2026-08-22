# 機能マトリクス

機能一覧・提供面・Class 依存の正本。ドメイン仕様は `statement.md` / `breakdown.md`。第三者 REST（段階 B）は `public-api.md`。

## 方針

- **機能単位の有料／無料分けはしない**（全機能を同一条件で提供）。
- **段階 B（第三者 REST）と x402 は残す**（機械課金・レート制限。顧客アカウントは持たない）。
- **MCP は当面 Apps in ChatGPT 専用**（他 MCP クライアント向けの案内・サポート対象外）。
- 公開規約（どの Feature をいつ外に出すか）は **実装サイクル**（`AGENTS.md`：smoke → golden → 限定投入 → 公開）に準拠する。サイクル段階・本番件数・公開ゲートの現在地は Linear（[JP 現在地](https://linear.app/sollahiro/document/jp-現在地-af2abd076034)）。本表の「実装」はコード有無。
- client 表の **All** は **実装済み Feature の全部**（未実装・構想は含めない）。

## Class 依存

実装・理解の順（下は上に依存）。JP / EU とも同じ（`eu-esef-roadmap.md`）。

```text
Meta → Struct → Norm → Viz
```

| Class | 役割 |
|---|---|
| Meta | 発行体・書類の同定 |
| Struct | 開示の構造化（**正本**） |
| Norm | 正規化・組立（Breakdown 正本＋ Summary 組立） |
| Viz | 正規化値の分解・配分 |
| Feed | 縦依存の外（検索・更新・鮮度・レポート系） |

**Summary** は Statement / Statement-Notes / Breakdown 経路の組立スナップショット（Filing は本文。`financials-summary-separation.md`）。

## Feature（Class × Module）

| Class | Module | Feature | 実装 | 備考 |
|---|---|---|---|---|
| Meta | Search | 銘柄コード・書類 ID の検索 | 済 | `GET /v1/companies` 等 |
| Meta | Icon | 会社アイコン取得 | 済 | R2 公開 URL（設定時） |
| Struct | Filing | 有報のテキスト抽出 | 済 | filing-sections |
| Struct | Statement | 財務諸表の構造化 | 済（日経225） | BS/PL/CF/SS |
| Struct | Statement-Notes | 財務諸表注記の構造化 | 済 | 日経225。ingest の現在地は Linear |
| Norm | Summary | 正規化済み財務データ | 済 | financials 水準値 |
| Norm | Breakdown | 事業別・地域別の売上／従業員／研究開発／報告セグメント指標 | 済（軸あり） | 公開判断は Linear。軸は下表・`breakdown.md` |
| Viz | Waterfall | 事業利益・ROIC・ROE の分解 | 済 | financials 同行の分析投影 |
| Viz | Sankey | 地域別・製品別・利益構造・投資構造（項目入替可） | 未 | 旧称 Allocation。要求具体化後 |
| Feed | Trend | 検索数の多い銘柄・検索トレンド | 済 | 匿名コマンド回数（Workers Analytics Engine）。提出件数ランキングは出さない |
| Feed | Update | 新規取得・公開された有報などの更新情報 | 済 | REST/MCP。RSS は未提供 |
| Feed | Status | データの新鮮度・カバー率 | 一部（運用 `status-report` / 既存 HTML） | Web HTML は抜本見直し予定 |
| Feed | Report | LLM による銘柄分析レポート | 構想 | **本来はクライアント責務** |

### Statement-Notes（note_type）

公開契約の note_type（決定論。詳細は `statement.md` / `StatementNotesContract.swift`）:

| note_type | 内容 |
|---|---|
| `per_share_information` | 1 株当たり情報 |
| `issued_shares_and_capital` | 発行済株式・資本金等 |
| `dividends` | 配当 |
| `borrowings_schedule` | 借入金等明細 |
| `property_plant_equipment_schedule` | 有形固定資産明細 |
| `goodwill_and_intangibles` | のれん・無形資産 |
| `lease_liabilities` | リース負債 |
| `policy_holding_securities` | 政策保有株式 |

### Breakdown（軸）

公開判断の現在地は Linear（[JP 現在地](https://linear.app/sollahiro/document/jp-現在地-af2abd076034)）。本表は軸の意味。

| axis | 内容 |
|---|---|
| `business` | 事業別売上 |
| `geography` | 地域別売上 |
| `employees` | 従業員内訳 |
| `research_and_development` | 研究開発費内訳 |
| `goodwill` | のれん |
| `segment_assets` 他7指標 | 報告セグメント別指標 |

## Client × Feature

| client | Feature | 位置づけ |
|---|---|---|
| REST API | **All**（実装済み全部） | 契約の正。段階 A は Service Token。段階 B で x402 |
| Apps in ChatGPT（MCP） | **All**（実装済み全部） | **当面この面のみ** MCP を提供 |
| Web | Search, Icon, Summary, Feed | 将来候補（優先度低）。HTML は抜本見直し |
| RSS | Search, Summary, Feed | 構想 |

## 段階 B（第三者 REST）と x402

- 対象は **REST**（機械課金＝x402。払済みレシートが識別子）。
- MCP は段階 B の x402 対象にしない（Apps in ChatGPT は課金なし）。
- 機能単位の有料マスクは採らない。制御は認証・レート・段階 B の契約で行う。
- 着手順・公開判断は Linear [BLT-25](https://linear.app/sollahiro/issue/BLT-25/rest-段階-b-x402)。定義は `public-api.md`。

## Sankey

サーバーは分解済み数値のみ返し、描画はクライアント。材料は geography / business / Statement PL+SS / notes（capex·dividends）+ rd 等。複数観点の合成・JSON・エンドポイントは要求具体化まで設計しない。現在地は Linear [BLT-18](https://linear.app/sollahiro/issue/BLT-18/sankey要求具体化後)。

## 関連

`public-api.md` · `api-auth.md` · `breakdown.md` · `statement.md` · `financials-summary-separation.md` · `blt-server-roadmap.md` · `eu-esef-roadmap.md` · `architecture.md`
