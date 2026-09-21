# 会社アイコン manualSources スキップ台帳

会社単位の除外正本。手順・ingest・自己修正は `.agents/skills/company-icons/SKILL.md`。毎ラン開始時に読み、対象から除外する。同じ会社を安定取得不能のまま毎回復活させない。

| code | reason | date | memo |
| --- | --- | --- | --- |
| 6902 | blocked | 2026-09-12 | デンソー。安定した公開 URL が無い |
| 9020 | blocked | 2026-09-18 | JR東日本。origin 403 Access Denied |
| 6361 | blocked | 2026-09-18 | 荏原。origin 403（FaviconFetcher 既知 WAF） |
| 6472 | blocked | 2026-09-18 | NTN。Cloudflare challenge |
| 7453 | blocked | 2026-09-18 | 良品計画。Vercel 429 |
| 2681 | blocked | 2026-09-18 | ゲオHD。origin 403 |
| 7309 | blocked | 2026-09-18 | シマノ。origin 403 |
| 4661 | timeout | 2026-09-18 | オリエンタルランド。origin timeout 8s |
| 6988 | timeout | 2026-09-18 | 日東電工。HTTP/2 INTERNAL_ERROR のち timeout |
| 9042 | needs_link | 2026-09-18 | 阪急阪神HD。ogp.png 自己リダイレクト |
| 2296 | needs_link | 2026-09-18 | 伊藤ハム米久HD。正方形/OGP なし（横長ロゴのみ） |
| 8154 | needs_link | 2026-09-18 | 加賀電子。raster なし（SVG のみ） |
| 7167 | needs_link | 2026-09-18 | めぶきFG。正方形なし（198x86 ヘッダーのみ） |
| 4401 | needs_link | 2026-09-18 | ADEKA。正方形/OGP なし |
| 2292 | needs_link | 2026-09-18 | エスフーズ。横長ロゴのみ |
| 7593 | needs_link | 2026-09-18 | VTHD。GIF ロゴのみ、apple-touch 404 |
| 5851 | needs_link | 2026-09-18 | リョービ。ogimage.png 404 |
| 5805 | low_vis_no_source | 2026-09-20 | SWCC。origin 直下 apple-touch は「小冊子」画像。コーポレート logo は 475×81 |
| 3028 | blocked | 2026-09-20 | アルペン。store.alpen-group.jp 403 / alpen-group.jp 自己リダイレクト |
| 8167 | low_vis_no_source | 2026-09-20 | リテールパートナーズ。header_logo 350×60 のみ |
| 7180 | blocked | 2026-09-20 | 九州FG。Akamai 403 |
| 6135 | low_vis_no_source | 2026-09-20 | 牧野フライス。favicon 16/32 のみ |
| 3182 | low_vis_no_source | 2026-09-20 | オイシックス。公式 OGP 1201×701 ワードマークのみ（正方形化で中身が小さい） |
| 6622 | low_vis_no_source | 2026-09-20 | ダイヘン。ヘッダー GIF 288×56 のみ |
| 7864 | needs_link | 2026-09-20 | フジシール。HTML 上の apple-touch / ogimage / favicon が 404。logo 244×28 |
| 5989 | low_vis_no_source | 2026-09-20 | エイチワン。logo 83×63 / 144×68 |
| 8219 | blocked | 2026-09-20 | 青山商事。aoyama-syouji.co.jp 403。aoyamashoji.co.jp にアイコン無し |
| 6330 | blocked | 2026-09-20 | 東洋エンジニアリング。ボット壁（One moment / data:, favicon） |
| 3591 | blocked | 2026-09-20 | ワコールHD。wacoalholdings.jp 403 |
| 4927 | low_vis_no_source | 2026-09-20 | ポーラ・オルビスHD。logo GIF 184×38。apple-touch は HTML フォールバック |
| 6584 | tls | 2026-09-20 | 三櫻工業。sanoh.com 証明書検証不能、sanoh.co.jp handshake timeout |
| 6183 | low_vis_no_source | 2026-09-20 | ベルシステム24HD。OGP 1200×630 ワードマークのみ。favicon 32×32 |
| 1926 | needs_link | 2026-09-20 | ライト工業。有報に公告 URL 無し。公式 origin 未確定 |
| 1879 | low_vis_no_source | 2026-09-20 | 新日本建設。ヘッダー logo 372×78。正方形アイコン無し |
| 8228 | low_vis_no_source | 2026-09-20 | マルイチ産商。favicon 48×48 ICO のみ |
| 7570 | low_vis_no_source | 2026-09-20 | 橋本総業HD。apple-touch が単色青矩形のみ |
| 6101 | low_vis_no_source | 2026-09-21 | ツガミ。ヘッダー GIF 202×57 のみ |
| 7483 | needs_link | 2026-09-21 | ドウシシャ。公告 Pronexus。favicon 48×48 / 横長 logo のみ |
| 8079 | low_vis_no_source | 2026-09-21 | 正栄食品。lh_logo 339×47 / favicon 16×16 |
| 6023 | timeout | 2026-09-21 | ダイハツインフィニアース。d-infi.com timeout |
| 6652 | low_vis_no_source | 2026-09-21 | IDEC。正方形なし（IR 写真・横長） |
| 6517 | needs_link | 2026-09-21 | デンヨー。raster なし（SVG logo / favicon 48） |
| 4078 | low_vis_no_source | 2026-09-21 | 堺化学。favicon 32×32 のみ |
| 6516 | low_vis_no_source | 2026-09-21 | 山洋電気。先頭 favicon 極小、img-logo 539×65 |
| 5142 | low_vis_no_source | 2026-09-21 | アキレス。favicon 16×16。og:image はスライド写真 |
| 6062 | needs_link | 2026-09-21 | チャーム・ケア。favicon 48×48 のみ |
| 3320 | needs_link | 2026-09-21 | クロスプラス。favicon 48×48 のみ |
| 3947 | timeout | 2026-09-21 | ダイナパック。公式 origin 取得 timeout |
| 9357 | timeout | 2026-09-21 | 名港海運。公式 origin 取得 timeout |
| 9612 | low_vis_no_source | 2026-09-21 | ラックランド。logo 554×358 |
| 7721 | timeout | 2026-09-21 | 東京計器。公式 origin 取得 timeout |
| 7898 | low_vis_no_source | 2026-09-21 | ウッドワン。favicon 32×32 のみ |
| 1967 | low_vis_no_source | 2026-09-21 | ヤマト（建設）。tag-logo 51×50 |
| 3486 | needs_link | 2026-09-21 | グローバル・リンク・マネジメント。公式 origin 未確定 |
| 5986 | timeout | 2026-09-21 | モリテックスチール。公式 origin 取得 timeout |
| 3817 | needs_link | 2026-09-21 | SRA HD。ページ内の Facebook アイコン以外に正方形なし |
| 6638 | low_vis_no_source | 2026-09-21 | ミマキ。公式 OGP 1200×630 ワードマークのみ |
| 8877 | low_vis_no_source | 2026-09-21 | エスリード。公式 OGP 1200×630 ワードマークのみ |
| 8141 | low_vis_no_source | 2026-09-21 | 新光商事。OGP がトップページのスクリーンショット |
| 7595 | low_vis_no_source | 2026-09-21 | アルゴグラフィックス。corp.argo-graph.co.jp は 16×16 と横長 logo のみ |
