# 引き継ぎ: 日経225 Stage 6 business カバレッジ（2026-07-25 再々更新）

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
| 作業ブランチ | `main` @ `b07d2e5`（PR #123 merge 済み） |
| PR #120 | **merged** |
| PR #122 | **merged**（INPEX / アサヒ / ネクソン / メルカリ 等） |
| PR #123 | **merged**（エーザイ〜NXHD + Opus 監査硬化） |

PR #123 に含まれた主なコミット:

1. `b049c9b` — エーザイ: IFRS 製品表 + `EMEA` / TOTO: `HousingEquipment` 同居時 axis_ambiguous 解除 / クボタ golden tables
2. `50eccc9` — パンパシHD: 品目＋海外残（当時は全行地域名で mismatch。後続で過半数ルールへ）
3. `a64c6ae` — 高島屋: 営業収益ベース分母揃え / 野村: 「その他（消去分を含む）」を segment
4. `9ff6206` — NXHD: ロジスティクス地域展開＋専門事業を axis_ambiguous にしない
5. `326ce80` — Opus 5 監査指摘の硬化（分母裏取り / 資生堂型免除抑止 / RR 過半数 / その他調整）

### `breakdownCacheVersion` は **v4 のまま保留**

- 現行: `breakdown-v4`（`Sources/BlueTicker/Models/BreakdownContract.swift`）
- PR #123 は xbrl_facts 正規化の意味（分母揃え・axis 免除等）を変えているが、**バンプは意図的に見送った**
- 理由: 日経225の needs_review / 空きを一通り見終わってから、まとめて `breakdown-v5` にして Stage 6 再 ingest したい
- **次セッションでバンプしてよいタイミング**: 残 needs_review の棚卸しが一段落したあと（または ingest バッチを組む直前）
- バンプするまでは、既に DB に `needs_review=false` で入っている旧行は content_hash 一致時に据え置き（再計算されない）。今回スコープの要再計算社は多くが flagged / 未 ingest なので実害は限定的だが、**分母揃えの恩恵を他社に広げたいなら v5 バンプが必要**

**次セッション最初の作業候補:**

1. DB / live で **残 needs_review・空き** を再スキャン（高島屋・野村・NXHD はコード上解消済み）
2. **ingest**（Cursor VM の使い捨て Neon のみ。ローカル `.env` の `DATABASE_URL` は本番寄り → **書かない**）
3. 一通り見終わったら **`breakdownCacheVersion` → `breakdown-v5`** をバンプして再 ingest

未 ingest コード（live 確認済み・DB 未反映の想定）:

- PR #122 系: `1605,2502,3659,4385`
- PR #123 系: `4523,5332,7532,8233,8604,9147`（資生堂 4911 は F で空のまま → ingest 対象外）

```bash
# VM 上で例:
swift build --product blt-server
.build/debug/blt-server ingest --stages 6 --codes 1605,2502,3659,4385,4523,5332,7532,8233,8604,9147
```

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
| 1605 | INPEX | 国内O&G / イクシス / その他PJ | `xbrl_facts`, needs_review=**false** | **未** |
| 2502 | アサヒ | 酒類/飲料/食品・薬品 | `revenue_recognition_llm`, needs_review=**false** | **未** |
| 3659 | ネクソン | ゲーム課金/ロイヤリティ/その他 | `segment_info_llm`, needs_review=**false** | **未** |
| 4385 | メルカリ | Marketplace / Fintech / その他 | `segment_info_llm`, needs_review=**false** | **未** |
| 4523 | エーザイ | ニューロロジー/オンコロジー/その他 | `segment_info_llm`, needs_review=**false** | **未** |
| 5332 | TOTO | 日本住設+海外住設4地域+先進セラミック（利益あり） | `xbrl_facts`, needs_review=**false** | **未** |
| 7532 | パンパシHD | DS/GMS 品目 + 海外（北米/アジア）+ その他の収益 | `revenue_recognition_llm`, needs_review=**false** | **未** |
| **8233** | **高島屋** | 国内/海外百貨店・不動産・建装・金融・その他 | `xbrl_facts`, needs_review=**false**（分母=営業収益小計） | **未** |
| **8604** | **野村** | WM/IM/ホールセール/バンキング/**その他** | `segment_info_llm`, needs_review=**false**（分母=表の計） | **未** |
| **9147** | **NXHD** | ロジ5地域 + 警備輸送/重量品建設/物流サポート | `xbrl_facts`, needs_review=**false** | **未** |

### 分類で「空のまま」確定したもの（抜粋）

- **F 単一:** SUMCO, トレンドマイクロ, SMC, ソシオネクスト, ベイカレント, JPX, ARCHION, キーエンス, 横浜FG, 千葉銀, ふくおかFG, 塩野義, 中外, 日電硝（ガラスに集約）, ZOZO（MD&A のみ・注記は単一）, **資生堂（化粧品事業がほとんどで製品別記載省略）**
- **E 地域のみ:** 良品計画, **マツダ**（ユーザー確定）
- **既知ギャップ:** オリックス（巨大 USGAAP / #103）— 今はやらない
- **将来（低優先）:** クボタ等で報告セグメント（利益あり）と製品別明細（利益なし）の**融合**スキーマ。現状は粗い報告セグメントを採用

---

## needs_review 残り（2026-07-25 時点・コード上）

ユーザー指示: **1 社ずつ**。  
**高島屋 / 野村 / NXHD は PR #123 で live 解消済み。** 次は DB 再スキャンで残件を洗い出す。

| # | Code | 会社 | 状態 |
|---|------|------|------|
| — | 8233 | 高島屋 | **解消**（コード・live） |
| — | 8604 | 野村 | **解消**（コード・live） |
| — | 9147 | NXHD | **解消**（コード・live） |

解消済み（実装・live。DB ingest は未）: 1605 INPEX, 2502 アサヒ, 3659 ネクソン, 4385 メルカリ, 4523 エーザイ, 4911 資生堂（F・空）, 5332 TOTO, 7532 パンパシHD, **8233 高島屋**, **8604 野村**, **9147 NXHD**。

---

## 次セッションの進め方

1. **main を最新に**
   ```bash
   git fetch && git checkout main && git pull
   ```
2. **残 needs_review / 空きをスキャン**（DB または live バッチ）
3. 残があれば **1 社ずつ** 修正 → テスト → ユーザー確認
4. **ingest**（Cursor VM の使い捨て Neon のみ）
5. 一通り見終わったら **`breakdownCacheVersion` を `breakdown-v5` にバンプ**（`BreakdownContract.swift` + `versioning.md`）→ 全件/対象 Stage 6 再 ingest

### 高島屋で分かったこと（2026-07-25）

- 軸は事業（国内/海外百貨店・不動産開発・建装・金融・その他）。INPEX 型語幹判定で当初から `axis_ambiguous` ではない
- Stage 4 は `NetSales`（売上高 4019億）、セグメント注記の `RevenuesFromExternalCustomers` は営業収益ベース（4923億）
- 小計 `TotalOfReportableSegmentsAndOthers` に分母を揃え、warning `sales_denominator_aligned_to_segment_total`
- 公開 API に `share` は無い（`amount` + `denominator`）。内部 `share` は診断用
- Opus 後: **名称一致小計で裏取りできた揃えだけ** needs_review=false。小計無しの segmentSum フォールバックは要レビュー

### 野村で分かったこと（2026-07-25）

- #105 の分母フォールバック済み（金融費用控除後の「計」→ `llm_table_subtotal`）
- 「その他（消去分を含む）」はヘッジ・投資持分・持分法・本社等の残バケット → **segment**（ユーザー確認）
- 決定的ガード: ラベルに「その他」かつ（`消去分を含む` / `全社`）→ segment。「その他の調整額」等の消去・調整本体は reconciling のまま（Opus）

### NXHD で分かったこと（2026-07-25）

- 報告セグメントは **ロジスティクスを地域展開**（日本/米州/欧州/東アジア/南ア・オセアニア）＋警備輸送/重量品建設/物流サポート
- ユーザー方針: ロジスティクスを1行に潰さず **地域内訳も残す**のがベスト
- 免除条件: 裸地域（**`Business` ラッパを含まない**）が2件以上 かつ 非地域の専門事業が同居 → axis_ambiguous 解除
- 資生堂型 `JapanBusiness` ラッパは件数だけでは免除しない（学び11 / Opus）

### エーザイ / TOTO / パンパシ（再掲）

- エーザイ: 製品表 `InformationAboutProductsAndServicesIFRSTextBlock` + EMEA キーワード + 種類分解 swap 抑止
- TOTO: HousingEquipment 同居で海外住設の裸地域を事業として採用
- パンパシ: 品目＋海外残。`business_label_mismatch` は **地域名らしい行が過半数**のとき（Opus 後。当初の「全行一致」から変更）

### よく使う診断パターン

- キャッシュ: `~/.config/blue-ticker/analysis_cache/external/edinet/xbrl/{DOC}_xbrl`
- 抽出: `BreakdownExtractor.extractSegmentInfo` / `extractRevenueRecognitionInfo`
- 地域判定: `BreakdownNormalizer.allMembersAreGeography`（キーワードは `Xbrl.segmentGeographyMemberKeywords`）
- Stage 4 `sales` null でも外部売上タグがあれば正規化できる（`2e657cd`）
- `needs_review=true` の行は Stage 6 が再試行対象（flaggedForReview）
- **golden（`smoke/breakdown_extraction_expected.json`）はユーザーレビュー前に更新しない**
- **`breakdownCacheVersion` バンプは保留中（v4）** — 下記「技術メモ」参照

---

## 技術メモ（PR #123 時点）

### 抽出（`BreakdownExtractor` / `Xbrl`）

- `InformationAboutProductsAndServicesIFRSTextBlock` を `productOrServiceTextBlockTags` に追加
- 種類分解マーカーに `医薬品販売による収益` / `ライセンス供与による収益`
- 地理キーワードに `EMEA`（全大文字）

### 正規化（`BreakdownNormalizer`）

- Stage 4 売上とセグメント小計が ±5% 超乖離 → 小計側に分母揃え（`sales_denominator_aligned_to_segment_total`）
- 小計裏取りなしの揃え → `needs_review=true`
- `HousingEquipment` 同居 / NXHD 型（裸地域≥2・非 Business ラッパ + 専門事業）で axis_ambiguous 解除
- `JapanBusiness` 型は要レビュー維持

### LLM

- `SegmentInfoLLMNormalizer`: 「その他（消去分を含む）」→ segment（決定的 `resolvedRowKind`）
- `RevenueRecognitionLLMNormalizer`: パンパシ型プロンプト / `business_label_mismatch` は過半数ルール

### キャッシュバージョン（保留）

- **いま:** `breakdown-v4`
- **保留理由:** 残 needs_review を一通り見てからまとめてバンプしたい（ユーザー指示 2026-07-25）
- **やるとき:** `BreakdownContract.swift` の `breakdownCacheVersion` + `.agents/rules/project/versioning.md` を `breakdown-v5` に更新

### golden

- `S100XR0M`（クボタ）segments tables 8→10（製品別候補が先頭に追加。最終 business は xbrl_facts のまま）

---

## 環境・コマンド

```bash
# テスト（代表）
swift test --filter 'BreakdownNormalizerTests|BreakdownExtractorTests|RealXbrlBreakdownTests|SegmentParityTests|RevenueRecognitionLLMNormalizerTests|SegmentInfoLLMNormalizerTests'

# live 診断
swift build --product TickerDev
.build/debug/TickerDev breakdown <CODE> <DOC> --live --axis business

# Stage 6 単発（VM の使い捨て Neon のみ）
swift build --product blt-server
.build/debug/blt-server ingest --stages 6 --codes <CODES>
```

前提:

- `.env` に `XAI_API_KEY`, `BLT_EDINET_API_KEY`（解析用）
- **ローカル `.env` の `DATABASE_URL` は本番寄り → Stage 6 ingest 禁止**
- Cursor Cloud / VM の `DATABASE_URL` は使い捨て Neon → ingest 可
- `assets/nikkei225.csv`（Stage 6 母集団）

---

## やらないこと（このスコープ外）

- geography 軸の ingest 配線（未着手のまま）
- `labelRaw` の日本語化（XBRL member 英語名が多い。LLM 経路は日本語になりやすい）
- オリックス #103 本対応
- ZOZO の MD&A スクレイピング
- needs_review の一括クリア
- クボタ製品別と報告セグメントの融合（低優先・スキーマ拡張が先）
- **いまの時点での `breakdownCacheVersion` バンプ**（保留。一通り見終わってから）

---

## ユーザーとの合意メモ

- E/F は空でよい
- ソシオネクストの製品売上/NRE は収益種類 → 無理に実装しない
- ZOZO は単一 + MD&A のみ → 実装しない
- マツダは E
- **資生堂は F**（化粧品事業がほとんどで製品別記載省略 → business 空）
- needs_review は **1 社ずつ**
- エーザイ: ニューロロジー/オンコロジー/その他（ユーザー確認）
- TOTO: 日本住設・米州・アジア・オセアニア等を business 採用してよい（ユーザー確認）
- パンパシHD: 品目＋海外（北米/アジア）残し（方針1、ユーザー確認）
- 高島屋: 分母は営業収益ベース小計でよい（ユーザー確認）
- 野村: 「その他（消去分を含む）」は segment（ユーザー確認）
- NXHD: ロジスティクスの**地域内訳も残す**（ユーザー確認）
- クボタ製品別融合は低優先
- **golden 更新は必ずユーザーレビュー後**
- ingest は Cursor VM 使い捨て DB のみ（ローカル `.env` は本番寄り）
- コード修正後の **ingest は別バッチ**（live のみ先に確認）
- **`breakdownCacheVersion` バンプは一通り見終わるまで保留**（ユーザー指示 2026-07-25）

---

## 参照コミット / ドキュメント

- PR #119 / #120 / #122 / **#123**（いずれも merged）
- `docs/breakdown-normalization-concept.md`
- `Sources/BlueTicker/Analysis/BreakdownExtractor.swift`
- `Sources/BlueTicker/Analysis/BreakdownNormalizer.swift`
- `Sources/BlueTicker/Analysis/RevenueRecognitionLLMNormalizer.swift`
- `Sources/BlueTicker/Analysis/SegmentInfoLLMNormalizer.swift`
- `Sources/BlueTicker/Analysis/BusinessBreakdownResolver.swift`
- `Sources/BlueTicker/Models/BreakdownContract.swift`（`breakdownCacheVersion = "breakdown-v4"` 保留中）
- `Sources/BltServerCore/Stage6Ingest.swift`
