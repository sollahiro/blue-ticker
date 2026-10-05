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
| 3024 | timeout | 2026-09-28 | クリエイト。www.cr-net.co.jp 取得不能 |
| 6191 | blocked | 2026-09-28 | エアトリ。origin 403 |
| 8135 | low_vis_no_source | 2026-09-28 | ゼット。公式トップ 200 だが正方形/OGP なし |
| 9419 | low_vis_no_source | 2026-09-28 | ワイヤレスゲート。Pronexus。公式トップ 200 だが usable 画像なし |
| 2597 | low_vis_no_source | 2026-09-28 | ユニカフェ。横長ワードマークのみ |
| 3943 | low_vis_no_source | 2026-09-28 | 大石産業。OGP は製品写真＋小さなワードマーク |
| 4235 | low_vis_no_source | 2026-09-28 | ウルトラファブリックスHD。logo 78×78 |
| 4524 | low_vis_no_source | 2026-09-28 | 森下仁丹。横長 logo |
| 5368 | low_vis_no_source | 2026-09-28 | 日本インシュレーション。OGP はビル写真＋小さなワードマーク |
| 5956 | low_vis_no_source | 2026-09-28 | トーソー。OGP は室内写真＋ワードマーク |
| 5979 | low_vis_no_source | 2026-09-28 | カネソウ。正方形だがスローガン＋ワードマークで中身が小さい |
| 6027 | low_vis_no_source | 2026-09-28 | 弁護士ドットコム。OGP はイラスト＋小さなワードマーク |
| 6035 | low_vis_no_source | 2026-09-28 | IRジャパンHD。favicon 64×64 |
| 6846 | low_vis_no_source | 2026-09-28 | 中央製作所。OGP は横長ロックアップ |
| 6863 | low_vis_no_source | 2026-09-28 | ニレコ。favicon 64×64 |
| 7600 | low_vis_no_source | 2026-09-28 | 日本エム・ディ・エム。横長 logo |
| 7989 | low_vis_no_source | 2026-09-28 | 立川ブラインド。OGP は室内写真＋ワードマーク |
| 9171 | low_vis_no_source | 2026-09-28 | 栗林商船。OGP は横長ロックアップ |
| 9216 | needs_link | 2026-09-28 | ビーウィズ。採用サイトは別名ドメイン。公式正方形なし |
| 9767 | low_vis_no_source | 2026-09-28 | 日建工学。横長 logo |
| 1381 | tls | 2026-10-05 | アクシーズ。www.axyz-grp.co.jp handshake hang |
| 1443 | needs_link | 2026-10-05 | 技研HD。公式 origin 未確定 |
| 1724 | low_vis_no_source | 2026-10-05 | シンクレイヤ。OGP 600×314 カード画像 |
| 2180 | needs_link | 2026-10-05 | サニーサイドアップ。公式 origin 未確定 |
| 2673 | needs_link | 2026-10-05 | 夢みつけ隊。公式 origin 未確定 |
| 2693 | low_vis_no_source | 2026-10-05 | YKT。OGP はトップコラージュ |
| 2806 | low_vis_no_source | 2026-10-05 | ユタカフーズ。favicon 32×32 のみ |
| 2876 | low_vis_no_source | 2026-10-05 | デルソーレ。favicon 180×127 |
| 288A | low_vis_no_source | 2026-10-05 | ラクサス。先頭 favicon は SNS の X。logo は横長ワードマーク |
| 3066 | low_vis_no_source | 2026-10-05 | JBイレブン。usable 正方形なし |
| 3075 | blocked | 2026-10-05 | 銚子丸。origin 403 |
| 3442 | needs_link | 2026-10-05 | MIE。公式 origin 未確定 |
| 3467 | low_vis_no_source | 2026-10-05 | アグレ。apple-touch が単色矩形。OGP はワードマーク |
| 3739 | low_vis_no_source | 2026-10-05 | コムシード。OGP 横長ワードマーク |
| 3753 | low_vis_no_source | 2026-10-05 | フライト。横長 logo |
| 3779 | low_vis_no_source | 2026-10-05 | Jエスコム。正方形 OGP が社名テキストのみ |
| 3807 | low_vis_no_source | 2026-10-05 | フィスコ。usable 正方形なし |
| 3892 | low_vis_no_source | 2026-10-05 | 岡山製紙。favicon 64×64 |
| 4054 | low_vis_no_source | 2026-10-05 | 日本情報クリエイト。認証ロゴのみ |
| 4171 | needs_link | 2026-10-05 | グローバルインフォメーション。公式 origin 未確定 |
| 4274 | low_vis_no_source | 2026-10-05 | 細谷火工。薄色マークで白地消滅 |
| 4366 | blocked | 2026-10-05 | ダイトーケミックス。origin 403 |
| 4429 | low_vis_no_source | 2026-10-05 | リックソフト。OGP はアイキャッチ写真 |
| 4480 | low_vis_no_source | 2026-10-05 | メドレー。OGP ワードマーク＋スローガン |
| 4714 | low_vis_no_source | 2026-10-05 | リソー教育。横長 logo |
| 4720 | low_vis_no_source | 2026-10-05 | 城南進学。縦長 banner |
| 5015 | needs_link | 2026-10-05 | BPカストロール。取れるのはグローバル BP マークのみ |
| 5381 | low_vis_no_source | 2026-10-05 | マイポックス。usable 正方形なし |
| 5867 | low_vis_no_source | 2026-10-05 | エスネットワークス。OGP 横長 |
| 5950 | low_vis_no_source | 2026-10-05 | 日本パワーファスニング。横長 logo |
| 5983 | tls | 2026-10-05 | イワブチ。証明書検証不能 |
| 6182 | low_vis_no_source | 2026-10-05 | メタリアル。OGP 横長 |
| 6343 | low_vis_no_source | 2026-10-05 | フリージア・マクロス。favicon 32×32 |
| 6577 | low_vis_no_source | 2026-10-05 | ベストワン。TSE ロゴ画像 |
| 6635 | low_vis_no_source | 2026-10-05 | 大日光。favicon 93×93 |
| 6655 | low_vis_no_source | 2026-10-05 | 東洋電機。横長 footer logo |
| 6777 | low_vis_no_source | 2026-10-05 | santec HD。横長 logo |
| 6834 | low_vis_no_source | 2026-10-05 | 精工技研。横長 header logo |
| 6907 | low_vis_no_source | 2026-10-05 | ジオマテック。OGP ワードマークのみ |
| 6919 | low_vis_no_source | 2026-10-05 | ケル。横長 logo |
| 6927 | low_vis_no_source | 2026-10-05 | ヘリオス。横長 header logo |
| 7271 | low_vis_no_source | 2026-10-05 | 安永。Pronexus。横長 GIF logo |
| 7487 | low_vis_no_source | 2026-10-05 | 小津産業。横長 header logo |
| 7506 | low_vis_no_source | 2026-10-05 | ハウス オブ ローゼ。横長 logo |
| 7515 | needs_link | 2026-10-05 | マルヨシセンター。公式 origin 未確定 |
| 7839 | low_vis_no_source | 2026-10-05 | SHOEI。OGP 600×351 |
| 7859 | low_vis_no_source | 2026-10-05 | アルメディオ。favicon 16×16 |
| 7868 | low_vis_no_source | 2026-10-05 | 広済堂HD。favicon が単色青矩形。OGP は横長ロックアップ |
| 7894 | low_vis_no_source | 2026-10-05 | 丸東産業。製品 logo |
| 7902 | low_vis_no_source | 2026-10-05 | ソノコム。usable 正方形なし |
| 8123 | low_vis_no_source | 2026-10-05 | 川辺。横長 logo |
| 8383 | low_vis_no_source | 2026-10-05 | 鳥取銀行。favicon 32×32 |
| 8559 | low_vis_no_source | 2026-10-05 | 豊和銀行。usable 正方形なし |
| 9073 | low_vis_no_source | 2026-10-05 | 京極運輸。favicon 74×74 |
| 9362 | low_vis_no_source | 2026-10-05 | 兵機海運。OGP 横長 |
| 9363 | needs_link | 2026-10-05 | 大運。公式 origin 未確定 |
| 9376 | low_vis_no_source | 2026-10-05 | ユーラシア旅行社。協会 logo のみ |
| 9407 | low_vis_no_source | 2026-10-05 | RKB毎日HD。OGP が noimage |
| 9514 | low_vis_no_source | 2026-10-05 | エフオン。横長 footer logo |
| 9664 | low_vis_no_source | 2026-10-05 | 御園座。横長 header logo |
| 9760 | low_vis_no_source | 2026-10-05 | 進学会HD。横長 logo |
| 9818 | low_vis_no_source | 2026-10-05 | 大丸エナウィン。OGP はビル写真 |
| 9850 | low_vis_no_source | 2026-10-05 | グルメ杵屋。事業アイコンであり HD マークではない |
| 9976 | low_vis_no_source | 2026-10-05 | セキチュー。横長 header GIF |
