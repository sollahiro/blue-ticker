# 引き継ぎ: 日経225 Stage 6 business カバレッジ（2026-07-25 ingest 完了）

Stage 6（`company_breakdowns` / axis=business）の needs_review 棚卸しと、対象 7 社の本番 DB 再 ingest まで完了。

## ゴール

- 日経225の **business 軸** を、開示がある会社は正しく埋める
- **E（地域のみ）/ F（単一セグメント）** は空のままでよい
- `needs_review` は 1 社ずつ原因を見て直す

正本: `docs/breakdown-normalization-concept.md` / `docs/blt-server-roadmap.md`（Stage 6）

---

## Git / DB 状態

| 項目 | 値 |
|------|-----|
| 作業ブランチ | `cursor/stage6-nikkei225-business-203b` |
| PR #120 / #122 / #123 | **merged** |
| `breakdownCacheVersion` | まだ **`breakdown-v4`**（v5 バンプは未実施） |

### 2026-07-25 本番 ingest（完了）

```bash
# pooler 端点は transaction_read_only=on のため direct 端点を使用
DATABASE_URL=<non-pooler> \
  .build/debug/blt-server ingest --stages 6 --codes 4385,4523,5332,7532,8233,8604,9147
```

結果サマリ: `attempted=36 failed=0 stored=36 skipped=4`

| Code | 会社 |  ingest 後 latest | source |
|------|------|-------------------|--------|
| 4385 | メルカリ | nr=**false** | Marketplace / Fintech / その他 |
| 4523 | エーザイ | nr=**false** | ニューロ / オンコ / その他 |
| 5332 | TOTO | nr=**false** | 住設+海外地域+先進セラミック |
| 7532 | パンパシHD | nr=**false** | 品目+北米/アジア+その他収益 |
| 8233 | 高島屋 | nr=**false**（warn: 分母揃え） | 百貨店/不動産/建装/金融 等 |
| 8604 | 野村 | nr=**false**（warn: 表の計） | WM/IM/WS/銀行/**その他（消去分を含む）** |
| 9147 | NXHD | nr=**false** | ロジ地域+専門事業 |
| 4911 | 資生堂 | **未更新**（F・対象外） | stale flagged のまま |

### 運用メモ: Neon pooler が read-only

- Secret / `.env` の `-pooler` ホストは `transaction_read_only=on`
- 書き込み時は `-pooler` を除いた direct ホストを使う
- 読み取りは pooler のままで可

---

## 棚卸し結果（再掲）

- 日経225: 223 社 / business あり 206 / 空き 17（E/F/オリックス）
- 新規にコード修正が必要な needs_review は無し（PR #122/#123 で解消済み）
- 資生堂は **F**（製品別省略 → business 空）。「E 地域のみ」ではない

### 空き 17（空のままでよい）

| 分類 | コード |
|------|--------|
| **F** | 3436, 4704, 6273, 6526, 6532, 8697, 6861, 7186, 8331, 8354, 4507, 4519, 5214, 3092, **4911** |
| **E** | 7453 良品計画, 7261 マツダ |
| **既知ギャップ** | 8591 オリックス |

---

## 次にやること（任意）

1. **`breakdown-v5` バンプ**（分母揃え等を他社の xbrl_facts 行へ広げるなら）
2. v5 後に日経225全件（または limit 付き）Stage 6 再 ingest
3. 資生堂の stale flagged 行を消すなら明示 DELETE（F 維持。今は放置でも可）
4. Secret の `DATABASE_URL` を direct（非 pooler）に揃えると書き込み手順が単純になる

---

## やらないこと

- geography 軸 ingest 配線
- オリックス #103
- ZOZO MD&A
- 資生堂を business として無理に埋める
- needs_review 一括クリア

---

## ユーザー合意

- E/F は空でよい（資生堂 **F**・マツダ E）
- live 異常なしなら本番 ingest OK（2026-07-25）
- golden 更新はユーザーレビュー後
