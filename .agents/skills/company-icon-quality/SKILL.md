---
name: company-icon-quality
description: use this when making, fixing, or reviewing a company logo icon image (square icon shown in a circle in 有報LAB) — the quality bar, candidate rules, and visual review flow. Icons live directly in R2; there is no fetch pipeline.
---
# 会社アイコン品質基準

スクリプトは都度生成してよい。この基準は毎回守る。

## 1. 仕上がり
- 512×512 PNG、白背景。透明は白で flatten する（アプリは黒地で描画するので、透明部分は消える）。
- 中心はキャンバスではなく、**中身の外接矩形**（角の色との差が 30 を超える画素）の中心で合わせる。
- 長辺比 `L = min(0.85, 1/sqrt(1+1/a^2))`、`a = 長辺/短辺 >= 1`。正方形は 70%、横長は最大 85%。
- 配置後、中身のすべての画素が中心から約 240px 以内（内接円の半径 256 で円クリップしても欠けない）。
- Lanczos で縮小する。引き伸ばさない。

## 2. 差し替え候補（どれか一つ）
計測は正方形への aspect-fit（letterbox）後、背景差 30 の外接矩形で行う。中央クロップで測らない。
- low_vis: マークの長辺 < 70%。
- lockup: マーク＋社名の並びで、短辺 < 70%。マークだけを連結成分マスクで切り出す。純ワードマーク（例: 花王、KEIO）は、長辺が 80〜88% なら対象外。
- low_res: 最小辺 < 128px、かつ公式に大きいマーク（apple-touch 180+、header の SVG/PNG、OGP）がある。無ければそのまま使い、引き伸ばさない。

## 3. 中身
- 1社1枚。会社（持株会社なら本体）のコーポレートマークを使う。App Icon・製品ブランドは不可。
- 次は捨てる: SNS ボタン、旧 Twitter マーク、WordPress 既定画像、単色の塗りつぶし、ページのスクリーンショット、別法人ホストの画像、ページ部品（toTOP ボタン等）。
- ソースは公式 HTTPS を優先する。必ず実 GET し、マジックバイトで確認する。SVG は `rsvg-convert` でラスタ化する。

## 4. 目視チェック（必須）
- 本番に入れる前に、全社でユーザーの visual GO を取る（新規も差し替えも）。
- 1社ずつ OK/NG の二択。NG 理由チップ: 余白が大きい / コンテンツが多い（マークだけでいい）/ 中身が適切ではない / 中心がずれている（丸で見たとき）/ 解像度が低い ＋ 自由記述。
- プレビューは高解像度にし、中心線と円クリップ表示を付ける。プレビュー自体の余白やずれで判断を誤らせない。
- NG は理由つきで記録し、理由を再ソースに反映する。同じソースを再提出しない。

## 5. 置き場所と公開
- 完成画像は R2 `blue-ticker-icons` の `company-icons/{code}.png` に置き、読み戻して sha を確認する。上書きする前に既存の画像をバックアップする。CDN は `https://icons.sollahiro.com/company-icons/{code}.png`（キャッシュ 4h）。  // pragma: allowlist secret
- 未 GO の候補は `company-icons/review/{date}/` に仮置きし、本番キーを上書きしない。
- PR やコメントに会社ロゴを載せない。Git に画像バイナリを入れない。秘密の値を出力しない。
