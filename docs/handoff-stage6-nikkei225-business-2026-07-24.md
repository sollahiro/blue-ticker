# 引き継ぎ: 日経225 Stage 6 business カバレッジ（2026-07-25 棚卸し完了）

次セッション向け。Stage 6（`company_breakdowns` / axis=business）の空き・`needs_review` 棚卸しは一段落。残りは **DB 再 ingest**（と任意の `breakdown-v5` バンプ）。

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
| 作業ブランチ | `cursor/stage6-nikkei225-business-203b`（base: `main` @ `ffe85c9`） |
| PR #120 / #122 / #123 | **merged** |

### `breakdownCacheVersion` は **v4 のまま保留 → バンプ可**

- 現行: `breakdown-v4`
- **棚卸し完了**（下記）。分母揃え等を他社へ広げるなら、ingest 直前に `breakdown-v5` へバンプしてよい
- バンプ箇所: `BreakdownContract.swift` + `.agents/rules/project/versioning.md`

---

## 2026-07-25 再スキャン結果（読み取りのみ）

前提:

- `assets/nikkei225.csv` は **gitignore**（親リポジトリ `blue-ticker/assets/` に実体。worktree は symlink）
- ローカル `.env` の `DATABASE_URL` は本番寄り → **SELECT のみ。ingest 禁止**

### 母集団

- 日経225 コード: **223**
- business 行あり: **206**
- 空き: **17**（下記。E/F/既知ギャップと一致）
- 最新行 `needs_review=true`: **8**（すべてコード修正済みの stale DB）

### 最新 `needs_review=true`（DB）→ live 再確認

| Code | 会社 | DB | live（本セッション） | 次 |
|------|------|-----|----------------------|-----|
| 4385 | メルカリ | `xbrl_facts` + axis_ambiguous | `segment_info_llm` Marketplace/Fintech/その他, nr=**false** | **再 ingest** |
| 4523 | エーザイ | `xbrl_facts` + axis_ambiguous | `segment_info_llm` ニューロ/オンコ/その他, nr=**false** | **再 ingest** |
| 5332 | TOTO | axis_ambiguous | `xbrl_facts` 住設+地域+先進セラミック, nr=**false** | **再 ingest** |
| 7532 | パンパシHD | business_label_mismatch | `revenue_recognition_llm` 品目+海外, nr=**false** | **再 ingest** |
| 8233 | 高島屋 | axis_ambiguous（分母=売上高） | 分母=営業収益小計, nr=**false**, warning=`sales_denominator_aligned_to_segment_total` | **再 ingest** |
| 8604 | 野村 | llm_row_sum_mismatch / v1 | 分母=表の計, 「その他（消去分を含む）」=segment, nr=**false** | **再 ingest** |
| 9147 | NXHD | axis_ambiguous | ロジ地域+専門事業, nr=**false**, warnings=[] | **再 ingest** |
| 4911 | 資生堂 | axis_ambiguous | LLM が地域事業表を返し nr=**true**（`business_label_looks_like_geography`） | **F・空のまま**（ingest しない。ユーザー合意） |

### すでに DB 反映済み（再 ingest 不要）

| Code | 会社 | DB latest |
|------|------|-----------|
| 1605 | INPEX | nr=false, `xbrl_facts` |
| 2502 | アサヒ | nr=false, `revenue_recognition_llm` |
| 3659 | ネクソン | nr=false, `segment_info_llm` |

### 空き 17（空のままでよい）

| 分類 | コード |
|------|--------|
| **F 単一** | 3436 SUMCO, 4704 トレンド, 6273 SMC, 6526 ソシオネクスト, 6532 ベイカレント, 8697 JPX, 6861 キーエンス, 7186 横浜FG, 8331 千葉銀, 8354 ふくおかFG, 4507 塩野義, 4519 中外, 5214 日電硝, 3092 ZOZO, **4911 資生堂**（DB に stale flagged 行あり・ingest 対象外） |
| **E 地域のみ** | 7453 良品計画, 7261 マツダ |
| **既知ギャップ** | 8591 オリックス（#103・今はやらない） |

→ **新規にコード修正が必要な needs_review / 空きは無し。**

---

## 次セッションの進め方

1. **使い捨て Neon** の `DATABASE_URL` を用意（ローカル `.env` は使わない）
2. （推奨）`breakdownCacheVersion` → `breakdown-v5` をバンプ
3. Stage 6 再 ingest:

```bash
swift build --product blt-server
# 要再計算の flagged 7 社（資生堂 4911 は除外）
.build/debug/blt-server ingest --stages 6 --codes 4385,4523,5332,7532,8233,8604,9147
# v5 バンプ後は日経225全件（または limit 付き）で xbrl_facts 側の分母揃えも広げられる
```

4. ingest 後に DB で最新 nr を再確認（期待: 上記 7 社 nr=false。空き 17 は維持）

### 資生堂メモ

- ユーザー合意は **F（製品別省略 → business 空）**
- live は地域報告セグメントを LLM で拾い `needs_review=true` になることがある → **空扱いを崩さない。ingest しない**
- DB の stale flagged 行を消すなら disposable Neon 上でのみ（本番寄りには DELETE しない）

---

## 技術メモ（PR #123 以降・変更なし）

- 高島屋: Stage 4 `NetSales` とセグメント営業収益小計の分母揃え（名称一致小計の裏取り時のみ nr=false）
- 野村: 「その他（消去分を含む）」→ segment（決定的ガード）
- NXHD: 裸地域≥2 + 専門事業で axis_ambiguous 免除（`JapanBusiness` ラッパ型は免除しない）
- パンパシ: `business_label_mismatch` は地域名らしい行が**過半数**のとき
- **golden 更新はユーザーレビュー後**
- **`assets/nikkei225.csv` は gitignore**（親 `assets/` を参照）

---

## 環境・コマンド

```bash
# テスト（代表）
swift test --filter 'BreakdownNormalizerTests|BreakdownExtractorTests|RealXbrlBreakdownTests|SegmentParityTests|RevenueRecognitionLLMNormalizerTests|SegmentInfoLLMNormalizerTests'

# live 診断
swift build --product TickerDev
.build/debug/TickerDev breakdown <CODE> <DOC> --live --axis business

# Stage 6（使い捨て Neon のみ）
swift build --product blt-server
.build/debug/blt-server ingest --stages 6 --codes <CODES>
```

---

## やらないこと（このスコープ外）

- geography 軸の ingest 配線
- `labelRaw` の日本語化
- オリックス #103 本対応
- ZOZO の MD&A スクレイピング
- needs_review の一括クリア
- クボタ製品別と報告セグメントの融合
- ローカル `.env` の `DATABASE_URL` への ingest / DELETE
- 資生堂を business として無理に埋める

---

## ユーザーとの合意メモ

- E/F は空でよい（資生堂 F・マツダ E 含む）
- needs_review は **1 社ずつ**
- golden 更新はユーザーレビュー後
- ingest は Cursor VM 使い捨て DB のみ
- **`breakdownCacheVersion` バンプは棚卸し後** → **いまバンプ可**（ingest とセットが望ましい）

---

## 参照

- PR #119 / #120 / #122 / #123（merged）
- `docs/breakdown-normalization-concept.md`
- `Sources/BlueTicker/Analysis/BreakdownNormalizer.swift` ほか
- `Sources/BlueTicker/Models/BreakdownContract.swift`（`breakdown-v4` → 次は v5）
- `Sources/BltServerCore/Stage6Ingest.swift`
