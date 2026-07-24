# 引き継ぎ: 日経225 Stage 6 business カバレッジ（2026-07-25 更新）

次セッション向け。Stage 6（`company_breakdowns` / axis=business）の空き・`needs_review` を会社単位で潰している途中。

## ゴール

- 日経225の **business 軸** を、開示がある会社は正しく埋める
- **E（地域のみ）/ F（単一セグメント）** は空のままでよい（無理に埋めない）
- `needs_review` は 1 社ずつ原因を見て直す（一括雑修正しない）

正本コンセプト: `docs/breakdown-normalization-concept.md`  
ロードマップ: `docs/blt-server-roadmap.md`（Stage 6）

---

## Git / PR 状態（重要）

| 項目 | 値 |
|------|-----|
| 作業ブランチ | `cursor/fix-mitsubishi-aozora-sumitomo-trust-breakdown` |
| PR #120 | **merged**（Mitsubishi/Aozora/Trust + MUFG swap ガード） |
| PR #122 | INPEX / アサヒ / ネクソン / メルカリ + Stage4 sales=null 等（本ドキュメント更新時点で merge 待ち／直後） |

PR #122 に含まれる主なコミット（`origin/main..HEAD` 相当）:

1. `2e657cd` — Stage 4 `sales=null` でも外部顧客売上タグで正規化
2. `371a1da` — INPEX: `OilAndGasJapan` の axis_ambiguous 解除 + 利益タグ
3. `0d72cb5` — アサヒ: `Oceania`/`Korea` キーワードで地域→製品マトリクス swap
4. `8a0ac96` — ネクソン: 製品別表パスの real XBRL 回帰
5. `d393c46` — メルカリ: `US`/`Region` キーワード + RR stub 時の swap 抑止
6. `3dcee62` — `JapanBusiness` 型は学び11どおり `axis_ambiguous` 維持（INPEX 免除の過大緩和を修正）

**次セッション最初の作業候補:** main を pull したうえで、**未 ingest の 1605/2502/3659/4385 を Stage 6 ingest**（コードは PR #122 で入る。DB 反映はまだ）。その後 needs_review 残りは **エーザイ** から。

---

## いままでの到達点（サマリ）

### 実装済み・live 確認済み（ingest は別途）

| Code | 会社 | 結果 | source（想定） | ingest |
|------|------|------|----------------|--------|
| 8058 | 三菱商事 | NotesRevenue2 事業グループ | `revenue_recognition_llm` | 済（#120 系） |
| 8304 | あおぞら | 製品・サービス別経常収益 | `segment_info_llm` | 済 |
| 8309 | 三井住友トラスト | 実質業務粗利益 | `segment_info_llm` | 済 |
| 8630 | SOMPO | 損保/生保/介護等 | `xbrl_facts` | 済 |
| 8725 | MS&AD | 損保・生保各社 | `xbrl_facts` | 済 |
| 8750 | 第一生命HD | 国内/海外保険 | `xbrl_facts` | 済 |
| 8795 | T&D | 太陽/大同/TF/UC | `xbrl_facts` | 済 |
| 9602 | 東宝 | 映画/IP・アニメ/演劇/不動産 | `xbrl_facts` | 済 |
| **1605** | **INPEX** | 国内O&G / イクシス / その他PJ | `xbrl_facts`, needs_review=**false**, profit あり | **未** |
| **2502** | **アサヒ** | 酒類/飲料/食品・薬品 | `revenue_recognition_llm`, needs_review=**false** | **未** |
| **3659** | **ネクソン** | ゲーム課金/ロイヤリティ/その他 | `segment_info_llm`, needs_review=**false** | **未** |
| **4385** | **メルカリ** | Marketplace / Fintech / その他 | `segment_info_llm`, needs_review=**false**（live 確認 2026-07-25） | **未** |

### 分類で「空のまま」確定したもの（抜粋）

- **F 単一:** SUMCO, トレンドマイクロ, SMC, ソシオネクスト, ベイカレント, JPX, ARCHION, キーエンス, 横浜FG, 千葉銀, ふくおかFG, 塩野義, 中外, 日電硝（ガラスに集約）, ZOZO（MD&A のみ・注記は単一）
- **E 地域のみ:** 良品計画, **マツダ**（ユーザー確定）
- **既知ギャップ:** オリックス（巨大 USGAAP / #103）— 今はやらない

---

## needs_review 残り（2026-07-25 時点）

ユーザー指示: **1 社ずつ**。次は **エーザイ**（メルカリ実装・live 確認済、ingest はバッチで可）。

| # | Code | 会社 | 最新 doc | source | 現状ラベル（要約） | 見立て（未確認） |
|---|------|------|----------|--------|-------------------|------------------|
| **→** | **4523** | **エーザイ** | S100YB05 | xbrl_facts | Americas/Japan/China/EMEA… | 地域寄り |
| 2 | 4911 | 資生堂 | S100XSCU | xbrl_facts | JapanBusiness / ChinaAndTR… | 地域事業ユニット境界（`JapanBusiness` は axis_ambiguous 対象のまま） |
| 3 | 5332 | TOTO | S100YC72 | xbrl_facts | 日本住設+先進セラミック+米欧亜Business | **事業×地域混在**（axis_ambiguous 維持） |
| 4 | 7532 | パンパシHD | S100WR05 | revenue_recognition_llm | 品目 + 北米/アジア | `business_label_mismatch` |
| 5 | 8233 | 高島屋 | S100Y4X5 | xbrl_facts | 国内/海外百貨店・不動産等 | 事業だが Domestic/Overseas 修飾 |
| 6 | 8604 | 野村 | S100YC5C | segment_info_llm | WM/IM/ホールセール/バンキング | 部門は妥当そう・`llm_row_sum_mismatch`（#105 系） |
| 7 | 9147 | NXHD | S100XTG8 | xbrl_facts | 地域 + 流通支援/警備/重量 | 混在 |

解消済み（上表から外れた）: 1605 INPEX, 2502 アサヒ, 3659 ネクソン, **4385 メルカリ**（実装・live。DB ingest は未）。

---

## 次セッションの進め方

1. **コード同期**
   ```bash
   git fetch && git checkout main && git pull
   ```
2. **未反映 4 社を Stage 6 ingest**（ユーザー合意・`DATABASE_URL` 確認のうえ）
   ```bash
   set -a && source .env && set +a
   swift build --product blt-server
   .build/debug/blt-server ingest --stages 6 --codes 1605,2502,3659,4385
   ```
3. **エーザイから needs_review を 1 社ずつ**
   ```bash
   swift build --product TickerDev
   .build/debug/TickerDev breakdown 4523 S100YB05 --live --axis business
   ```
4. 修正 → テスト → ユーザー確認 → ingest → 次社

### メルカリで分かったこと（再掲）

- 報告セグメント facts は Japan Region / US（地域）
- Marketplace / Fintech / その他は **セグメント注記内のマトリクス**（行=事業・列=地域）
- IFRS 売上収益注記は「分解はセグメント情報に記載」＋契約負債表のみ → **RR へ無条件 swap すると製品表を失う**
- 経路: geography facts 判定 → SegmentInfoLLM が製品行を採用（live: 147618 / 38597 / 6416 百万円）

### よく使う診断パターン

- キャッシュ: `~/.config/blue-ticker/analysis_cache/external/edinet/xbrl/{DOC}_xbrl`
- 抽出: `BreakdownExtractor.extractSegmentInfo` / `extractRevenueRecognitionInfo`
- 地域判定: `BreakdownNormalizer.allMembersAreGeography`（キーワードは `Xbrl.segmentGeographyMemberKeywords`）
- Stage 4 `sales` null でも外部売上タグがあれば正規化できる（`2e657cd`）
- `needs_review=true` の行は Stage 6 が再試行対象（flaggedForReview）

---

## 技術メモ（このラウンドで入れた要点）

### 抽出（`BreakdownExtractor` / `Xbrl`）

- `NotesRevenue2…IFRSTextBlock`（三菱商事）
- `InformationForEachProductOrServiceTextBlock`（あおぞら等）
- `NotesSegmentInformationEtc…` は売上相当が無いときだけ追加（トラスト）
- 地域軸 → 収益認識/IFRS売上へ swap（`shouldPreferRevenueRecognition`）
- ただし **認識済み売上タグ付き facts があるときは swap しない**（MUFG 粗利益破壊防止 / `42f90de`）
- **セグメント側に売上相当があり RR 側に無いときは swap しない**（メルカリ: RR が契約負債 stub / `d393c46`）

### 正規化（`BreakdownNormalizer`）

- `sales=null` → `segmentExternalRevenueTags` で内部小計フォールバック
- 固有語幹付き複合（`OilAndGasJapan`）内の地域語は `axis_ambiguous` にしない
- **`JapanBusiness` / `AmericasBusiness` のように地域名＋汎用 Business ラッパだけのラベルは学び11どおり混在シグナル**（`3dcee62`。INPEX 免除の過大緩和を Sonnet レビューで修正）
- 利益タグに `ProfitLossAttributableToOwnersOfParentIFRS`（INPEX）

### 地理キーワード追加

- `Oceania`, `Korea`（アサヒ/ネクソン）
- `US`, `Region`（メルカリ `JapanRegion` / `US`）

### LLM

- アサヒ: 列=製品・行=地域のマトリクス → 連結合計を転置（`RevenueRecognitionLLMNormalizer`）
- ネクソン / メルカリ: セグメント注記の製品表を地域表より優先（`SegmentInfoLLMNormalizer`）

---

## 環境・コマンド

```bash
# テスト（代表）
swift test --filter 'BreakdownNormalizerTests|BreakdownExtractorTests|RealXbrlBreakdownTests|SegmentParityTests'

# Stage 6 単発
set -a && source .env && set +a
swift build --product blt-server
.build/debug/blt-server ingest --stages 6 --codes <CODES>

# DB 確認例
# company_breakdowns で code + 最新 doc_id、needs_review / source / rows.labelRaw
```

前提:

- `.env` に `DATABASE_URL`, `XAI_API_KEY`, `BLT_EDINET_API_KEY`
- `assets/nikkei225.csv`（Stage 6 母集団）
- AGENTS.md: Cloud の `DATABASE_URL` は使い捨て Neon 想定。ローカル `.env` は運用 DB の可能性あり → 書き込みはユーザー合意のうえ

---

## やらないこと（このスコープ外）

- geography 軸の ingest 配線（未着手のまま）
- `labelRaw` の日本語化（現状は XBRL member 英語名が多い。アサヒ/ネクソン/メルカリは LLM 日本語 or 英語製品名）
- オリックス #103 本対応
- ZOZO の MD&A スクレイピング
- needs_review の一括クリア

---

## ユーザーとの合意メモ

- E/F は空でよい
- ソシオネクストの製品売上/NRE は収益種類 → 無理に実装しない
- ZOZO は単一 + MD&A のみ → 実装しない
- マツダは E
- needs_review は **1 社ずつ**（INPEX → アサヒ → ネクソン → メルカリ 済、次エーザイ）
- メルカリは Marketplace / Fintech / その他が取れる（ユーザー確認）
- PR #122 のコード修正後、**ingest は別バッチ**（live のみ先に確認）

---

## 参照コミット / ドキュメント

- PR #119: geography → IFRS revenue / product tables
- PR #120: Mitsubishi / Aozora / Trust（merged）
- PR #122: INPEX / Asahi / Nexon / Mercari + sales=null + axis_ambiguous 修正
- `docs/breakdown-normalization-concept.md`
- `Sources/BlueTicker/Analysis/BreakdownExtractor.swift`
- `Sources/BlueTicker/Analysis/BreakdownNormalizer.swift`
- `Sources/BlueTicker/Analysis/BusinessBreakdownResolver.swift`
- `Sources/BltServerCore/Stage6Ingest.swift`
