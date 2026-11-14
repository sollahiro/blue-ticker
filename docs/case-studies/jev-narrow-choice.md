<!-- 移行元: 旧課題管理のドキュメント。正本はこのファイル。件数の最新値は書かない。 -->

# Jev活用事例：ロジック改善と簡略化

> 履歴スナップショット（2026-10-05）。件数・「未置換」と書いた項目は動かさない。現行契約は `docs/breakdown.md`。地理軸の Luna 経路と軸名 `business` は、その後 Jev 化と `product_service` リネーム済み。
>
> 作成: 2026-10-05。有報LAB で `typesafe/jev-1.13`（OpenRouter / `OPENROUTER_DECISION_API_KEY`）を使い、Luna 自由生成をやめて **決定論＋狭い選択** に寄せた事例の要約。詳細数値レポートは `docs/case-studies/revenue-recognition-jev.md`。

## 一言

Jevは「表を読んで全部書くLLM」ではなく、**すでに決めた候補の中から列・行・省略クラス・妥当性を選ばせる**。表の切り出し・合計一致・単位は決定論、曖昧なラベル選択だけJev。結果として Luna 依存が消え、経路が短くなり、誤列を fail-closed で止めやすくなった。

## 共通パターン（改善の型）

| 層 | 役割 | Luna時代 | Jev後 |
| -- | -- | -- | -- |
| 表構造（決定論） | ブロック分割、合計一致、並列表、指標行除外 | 一部だけ／LLMに任せることも | **先に固定**（再利用モジュール） |
| Jev | 列・軸・省略クラス・「この表は単一か」など **閉じた選択肢** | 自由記述の正規化・行生成 | 閾値付き選択（典型 0.5、「none」は高確信のみ） |
| 公開ガード | 空ラベル・重複・地理vs製品・銀行距離など | 厚い後段ガードで補正 | 残すが、**書類型を先に決める**方向へ簡略化予定 |

モデル: `typesafe/jev-1.13`。収益認識で296件検証時、**列の誤選択は0件**（失敗は表読み取り側）。セグメント258件試行でも失敗原因は表構造で、Jevではなかった。

---

## 事例1 — 収益認識 Breakdown（列選択）

**問題:** Lunaが収益認識表の「どの列が売上か」などを自由に決め、ゲートや waiver が増殖していた。

**改善:**

1. 決定論で表構造・候補列を列挙
2. Jevがその中から列を選ぶ（[#471](https://github.com/sollahiro/blue-ticker/pull/471)）
3. 不要な 0.9 ゲートや「その他の収益」closer の coverage waiver を落とす（[#473](https://github.com/sollahiro/blue-ticker/pull/473) / [#474](https://github.com/sollahiro/blue-ticker/pull/474)）

**簡略化:** Lunaステップ削除、カバレッジ例外の削減、同じ「列選択」部品を他経路へ再利用可能に。

**詳細:** 収益認識注記Breakdown：決定論＋Luna → 決定論＋Jev 実装レポート

---

## 事例2 — 事業別セグメント情報（旧チケット 118 / [#476](https://github.com/sollahiro/blue-ticker/pull/476)）

**問題:** `SegmentInfoLLMNormalizer` が Luna（`OPENAI_BUSINESS_MODEL

**改善:**

1. 収益認識と同じ **表構造チェック＋Jev列／行選択** に置換
2. Luna呼び出しと `OPENAI_BUSINESS_MODEL` 依存を削除
3. 公開分類を明確化（のち [#481](https://github.com/sollahiro/blue-ticker/pull/481) で③を確定）:
   * 事業・製品の報告／表 → 非地理軸に公開
   * 地域報告＋本物の製品表 → 製品のみ（足さない）
   * 地域のみ（省略文≠製品表） → 非地理軸は `geography_only` NA、地域は geography
   * 真の単一 → `single_segment_disclosed`
   * 単一タグ＋製品表（475A） → 短絡せず製品を公開

**簡略化:** 自由生成の正規化経路を「候補選択」に圧縮。地域別 Luna（`GeographyBreakdownLLMNormalizer`）は 旧チケット 117 に残し、同じ型で後続置換予定。

**Issue / PR:** 旧チケット 118 Done、[#476](https://github.com/sollahiro/blue-ticker/pull/476)。取りこぼし27行の組立品質は 旧チケット 122。

---

## 事例3 — 単一セグメント／Needs Review の再判定（[#478](https://github.com/sollahiro/blue-ticker/pull/478)）

**問題:** 専用タグや空行組み立てで単一セグメント／NRに落ち、製品表があるのに404になるケース（475Aなど）。

**改善:** 単一セグメントタグと Needs Review の妥当性を **Jevで再判定**。高確信（≥0.9程度）なら表から復旧、低確信は **fail-closedでNRのまま**。

**簡略化:** 「タグ＝即404」の短絡を減らし、決定は1回の選択問題に寄せる。空行フォールバック・銀行距離は決定論側の別修正。

---

## 事例4 — 収益認識「その他の収益」注記（旧チケット 115、設計）

**役割分担（合意）:**

1. 定型ルールで取れる米印注記
2. Jevが確信度＋既定理由で判定（不適切なら1回再分析）
3. 取れない自由記述だけ OpenRouter LLM（提案保存・自動公開しない）。Lunaは使わない（旧チケット 113で撤去）

ここでも Jevは **生成役ではなくゲート／分類役**。

---

## まだ簡略化しきれていないところ

* 公開後ガード（空ラベル、重複＋その他、地理vs製品、軸曖昧）が厚い → 旧チケット 122 で **報告軸 × 製品表あり/なし** を先に1回決め、`hasProductOrBusinessTable` / 専用タグ / `review_decision` / 省略写像の重複を削る方針
* 軸名 `business` は製品・サービス実態とズレ → 旧チケット 123 で `product_service` へ一括リネーム（互換なし）
* 地理軸の Luna 経路は未置換（旧チケット 117）

---

## 参照クイックリンク

| 用途 | リンク |
| -- | -- |
| RR Jev 詳細レポート | `docs/case-studies/revenue-recognition-jev.md` |
| セグメント Jev 置換 | 旧チケット 118、[#476](https://github.com/sollahiro/blue-ticker/pull/476) |
| geo-only = NA 確定 | [#481](https://github.com/sollahiro/blue-ticker/pull/481)（マージ済 `f30dd0c1`） |
| 分類・簡略化本筋 | 旧チケット 122 |
| 軸リネーム | 旧チケット 123 |
| Luna撤去親 | 旧チケット 113 |

