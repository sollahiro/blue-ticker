# 引き継ぎ: 日経225 Stage 6 business カバレッジ（2026-07-24）

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
| PR #120 | **merged**（Mitsubishi/Aozora/Trust + MUFG swap ガードまで） |
| **未マージの先端コミット** | `2e657cd` … `8a0ac96`（下記）→ **main に未取り込み。新規 PR が必要** |

未マージ（`origin/main..HEAD`）:

1. `2e657cd` — Stage 4 `sales=null` でも外部顧客売上タグで正規化
2. `371a1da` — INPEX: `OilAndGasJapan` の axis_ambiguous 解除 + 利益タグ
3. `0d72cb5` — アサヒ: `Oceania`/`Korea` キーワードで地域→製品マトリクス swap
4. `8a0ac96` — ネクソン: 製品別表パスの real XBRL 回帰

**次セッション最初の作業候補:** main から新ブランチを切るか、本ブランチを rebase して **PR を新規作成**（DB には既に ingest 済みの結果あり）。

---

## いままでの到達点（サマリ）

### 実装・ingest 済み（代表）

| Code | 会社 | 結果 | source |
|------|------|------|--------|
| 8058 | 三菱商事 | NotesRevenue2 事業グループ | `revenue_recognition_llm` |
| 8304 | あおぞら | 製品・サービス別経常収益 | `segment_info_llm` |
| 8309 | 三井住友トラスト | 実質業務粗利益 | `segment_info_llm` |
| 8630 | SOMPO | 損保/生保/介護等 | `xbrl_facts`（最新へ更新済） |
| 8725 | MS&AD | 損保・生保各社 | `xbrl_facts` |
| 8750 | 第一生命HD | 国内/海外保険 | `xbrl_facts` |
| 8795 | T&D | 太陽/大同/TF/UC | `xbrl_facts` |
| 9602 | 東宝 | 映画/IP・アニメ/演劇/不動産 | `xbrl_facts` |
| **1605** | **INPEX** | 国内O&G / イクシス / その他PJ | `xbrl_facts`, needs_review=**false**, profit あり |
| **2502** | **アサヒ** | 酒類/飲料/食品・薬品 | `revenue_recognition_llm`, needs_review=**false** |
| **3659** | **ネクソン** | ゲーム課金/ロイヤリティ/その他 | `segment_info_llm`, needs_review=**false** |

### 分類で「空のまま」確定したもの（抜粋）

- **F 単一:** SUMCO, トレンドマイクロ, SMC, ソシオネクスト, ベイカレント, JPX, ARCHION, キーエンス, 横浜FG, 千葉銀, ふくおかFG, 塩野義, 中外, 日電硝（ガラスに集約）, ZOZO（MD&A のみ・注記は単一）
- **E 地域のみ:** 良品計画, **マツダ**（ユーザー確定）
- **既知ギャップ:** オリックス（巨大 USGAAP / #103）— 今はやらない

---

## needs_review 残り（最新有報・2026-07-24 時点）

ユーザー指示: **1 社ずつ**。次は **メルカリ**。

| # | Code | 会社 | 最新 doc | source | 現状ラベル（要約） | 見立て（未確認） |
|---|------|------|----------|--------|-------------------|------------------|
| **→** | **4385** | **メルカリ** | S100WQDW | xbrl_facts | Japan Region / US | 地域？製品別があるか **次に確認** |
| 2 | 4523 | エーザイ | S100YB05 | xbrl_facts | Americas/Japan/China/EMEA… | 地域寄り |
| 3 | 4911 | 資生堂 | S100XSCU | xbrl_facts | JapanBusiness / ChinaAndTR… | 地域事業ユニット境界 |
| 4 | 5332 | TOTO | S100YC72 | xbrl_facts | 日本住設+先進セラミック+裸の米欧亜 | **事業×地域混在** |
| 5 | 7532 | パンパシHD | S100WR05 | revenue_recognition_llm | 品目 + 北米/アジア | `business_label_mismatch` |
| 6 | 8233 | 高島屋 | S100Y4X5 | xbrl_facts | 国内/海外百貨店・不動産等 | 事業だが Domestic/Overseas 修飾 |
| 7 | 8604 | 野村 | S100YC5C | segment_info_llm | WM/IM/ホールセール/バンキング | 部門は妥当そう・`llm_row_sum_mismatch`（#105 系） |
| 8 | 9147 | NXHD | S100XTG8 | xbrl_facts | 地域 + 流通支援/警備/重量 | 混在 |

解消済み（上表から外れた）: 1605 INPEX, 2502 アサヒ, 3659 ネクソン。

---

## 次セッションの進め方（メルカリから）

1. **コード同期**
   - `git fetch && git checkout cursor/fix-mitsubishi-aozora-sumitomo-trust-breakdown`（または main + cherry-pick / 新ブランチ）
   - 未マージ 4 コミットを PR 化してから続けるのが安全
2. **メルカリ XBRL を見る**
   - doc `S100WQDW`（無ければ EDINET type=1 でキャッシュ）
   - 報告セグメントが地域だけか、製品・サービス別があるか
   - パターンはアサヒ（RR マトリクス）かネクソン（セグメント注記内の製品表）か
3. **live 確認**
   ```bash
   swift build --product TickerDev
   set -a && source .env && set +a
   .build/debug/TickerDev breakdown 4385 S100WQDW --live --axis business
   ```
4. **修正 → テスト → ingest**
   ```bash
   swift build --product blt-server
   .build/debug/blt-server ingest --stages 6 --codes 4385
   ```
5. ユーザーに結果を見せてから次社へ

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

### 正規化（`BreakdownNormalizer`）

- `sales=null` → `segmentExternalRevenueTags` で内部小計フォールバック
- 複合ラベル（`OilAndGasJapan`, `…Business`）内の地域語は `axis_ambiguous` にしない
- 利益タグに `ProfitLossAttributableToOwnersOfParentIFRS`（INPEX）

### 地理キーワード追加

- `Oceania`, `Korea`（アサヒ/ネクソンの地域判定用）

### LLM

- アサヒ: 列=製品・行=地域のマトリクス → 連結合計を転置（`RevenueRecognitionLLMNormalizer`）
- ネクソン: セグメント注記の製品表を地域表より優先（`SegmentInfoLLMNormalizer`）

---

## 環境・コマンド

```bash
# テスト（代表）
swift test --filter 'BreakdownNormalizerTests|RealXbrlBreakdownTests|SegmentParityTests'

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
- `labelRaw` の日本語化（現状は XBRL member 英語名が多い。アサヒ/ネクソンは LLM 日本語）
- オリックス #103 本対応
- ZOZO の MD&A スクレイピング
- needs_review の一括クリア

---

## ユーザーとの合意メモ

- E/F は空でよい
- ソシオネクストの製品売上/NRE は収益種類 → 無理に実装しない
- ZOZO は単一 + MD&A のみ → 実装しない
- マツダは E
- needs_review は **1 社ずつ**（INPEX → アサヒ → ネクソン 済、次メルカリ）

---

## 参照コミット / ドキュメント

- PR #119: geography → IFRS revenue / product tables
- PR #120: Mitsubishi / Aozora / Trust（merged）
- 本ハンドオフ以降の未マージ: 上記 4 commits
- `docs/breakdown-normalization-concept.md`
- `Sources/BlueTicker/Analysis/BreakdownExtractor.swift`
- `Sources/BlueTicker/Analysis/BreakdownNormalizer.swift`
- `Sources/BlueTicker/Analysis/BusinessBreakdownResolver.swift`
- `Sources/BltServerCore/Stage6Ingest.swift`
