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
| 2976 | low_vis_no_source | 2026-10-20 | 日本グランデ。公告 URL 全角ハイフンで origin 不能。公式 favicon 37px のみ |
| 7509 | low_vis_no_source | 2026-10-20 | アイエー。公告 URL 全角ハイフンで origin 不能。正方形/apple-touch なし |
| 135A | awaiting_go | 2026-10-28 | ＶＲＡＩＮＳｏｌｕｔｉｏｎ。32×32→180×180 staged review/2026-10-28 |
| 1375 | awaiting_go | 2026-10-28 | ユキグニファクトリー。32×32→180×180 staged review/2026-10-28 |
| 137A | awaiting_go | 2026-10-28 | Ｃｏｃｏｌｉｖｅ。32×32→180×180 staged review/2026-10-28 |
| 1384 | awaiting_go | 2026-10-28 | ホクリヨウ。32×32→180×180 staged review/2026-10-28 |
| 147A | awaiting_go | 2026-10-28 | ソラコム。32×32→192×192 staged review/2026-10-28 |
| 150A | awaiting_go | 2026-10-28 | ＪＳＨ。32×32→180×180 staged review/2026-10-28 |
| 153A | awaiting_go | 2026-10-28 | カウリス。32×32→180×180 staged review/2026-10-28 |
| 157A | awaiting_go | 2026-10-28 | グリーンモンスター。32×32→180×180 staged review/2026-10-28 |
| 160A | awaiting_go | 2026-10-28 | アズパートナーズ。32×32→180×180 staged review/2026-10-28 |
| 168A | awaiting_go | 2026-10-28 | イタミアート。32×32→180×180 staged review/2026-10-28 |
| 1783 | awaiting_go | 2026-10-28 | ｆａｎｔａｓｉｓｔａ。32×32→180×180 staged review/2026-10-28 |
| 1813 | awaiting_go | 2026-10-28 | 不動テトラ。32×32→180×180 staged review/2026-10-28 |
| 1887 | awaiting_go | 2026-10-28 | 日本国土開発。32×32→180×180 staged review/2026-10-28 |
| 192A | awaiting_go | 2026-10-28 | インテグループ。32×32→180×180 staged review/2026-10-28 |
| 1975 | awaiting_go | 2026-10-28 | 朝日工業社。32×32→180×180 staged review/2026-10-28 |
| 2158 | awaiting_go | 2026-10-28 | ＦＲＯＮＴＥＯ。16×16→630×630 staged review/2026-10-28 |
| 2160 | awaiting_go | 2026-10-28 | ジーエヌアイグループ。32×32→180×180 staged review/2026-10-28 |
| 2163 | awaiting_go | 2026-10-28 | アルトナー。32×32→180×180 staged review/2026-10-28 |
| 2216 | awaiting_go | 2026-10-28 | カンロ。32×32→180×180 staged review/2026-10-28 |
| 2222 | awaiting_go | 2026-10-28 | 寿スピリッツ。33×33→145×144 staged review/2026-10-28 |
| 2293 | awaiting_go | 2026-10-28 | 滝沢ハム。16×16→1024×1024 staged review/2026-10-28 |
| 2301 | awaiting_go | 2026-10-28 | 学情。16×16→180×180 staged review/2026-10-28 |
| 2467 | awaiting_go | 2026-10-28 | ＶＬＣセキュリティ。32×32→180×180 staged review/2026-10-28 |
| 247A | awaiting_go | 2026-10-28 | Ａｉロボティクス。16×16→180×180 staged review/2026-10-28 |
| 2488 | awaiting_go | 2026-10-28 | ＪＴＰ。48×48→260×260 staged review/2026-10-28 |
| 2493 | awaiting_go | 2026-10-28 | イーサポートリンク。32×32→180×180 staged review/2026-10-28 |
| 254A | awaiting_go | 2026-10-28 | ＡＩフュージョンキャピタルグループ。32×32→180×180 staged review/2026-10-28 |
| 2593 | awaiting_go | 2026-10-28 | 伊藤園。16×16→180×180 staged review/2026-10-28 |
| 263A | awaiting_go | 2026-10-28 | デジタルキューブ。32×32→180×180 staged review/2026-10-28 |
| 2656 | awaiting_go | 2026-10-28 | ベクターホールディングス。32×32→180×180 staged review/2026-10-28 |
| 2735 | awaiting_go | 2026-10-28 | ワッツ。32×32→180×180 staged review/2026-10-28 |
| 2750 | awaiting_go | 2026-10-28 | 石光商事。32×32→180×180 staged review/2026-10-28 |
| 2813 | awaiting_go | 2026-10-28 | 和弘食品。32×32→180×180 staged review/2026-10-28 |
| 2884 | awaiting_go | 2026-10-28 | ヨシムラ・フード・ホールディングス。32×32→180×180 staged review/2026-10-28 |
| 2901 | awaiting_go | 2026-10-28 | ウェルディッシュ。32×32→180×180 staged review/2026-10-28 |
| 2926 | awaiting_go | 2026-10-28 | 篠崎屋。32×32→180×180 staged review/2026-10-28 |
| 2981 | awaiting_go | 2026-10-28 | ランディックス。32×32→180×180 staged review/2026-10-28 |
| 2984 | awaiting_go | 2026-10-28 | ヤマイチエステート。32×32→180×180 staged review/2026-10-28 |
| 303A | awaiting_go | 2026-10-28 | ｖｉｓｕｍｏ。50×50→2084×2084 staged review/2026-10-28 |
| 3045 | awaiting_go | 2026-10-28 | カワサキ。32×32→180×180 staged review/2026-10-28 |
| 3069 | awaiting_go | 2026-10-28 | ＪＦＬＡホールディングス。32×32→180×180 staged review/2026-10-28 |
| 3139 | awaiting_go | 2026-10-28 | ラクト・ジャパン。32×32→144×144 staged review/2026-10-28 |
| 319A | awaiting_go | 2026-10-28 | 技術承継機構。32×32→180×180 staged review/2026-10-28 |
| 3238 | awaiting_go | 2026-10-28 | セントラル総合開発。32×32→180×180 staged review/2026-10-28 |
| 3242 | awaiting_go | 2026-10-28 | アーバネットコーポレーション。48×48→180×180 staged review/2026-10-28 |
| 3245 | awaiting_go | 2026-10-28 | ディア・ライフ。32×32→180×180 staged review/2026-10-28 |
| 324A | awaiting_go | 2026-10-28 | ブッキングリゾート。32×32→180×180 staged review/2026-10-28 |
| 3252 | awaiting_go | 2026-10-28 | 地主。32×32→180×180 staged review/2026-10-28 |
| 325A | awaiting_go | 2026-10-28 | ＴＥＮＴＩＡＬ。32×32→180×180 staged review/2026-10-28 |
| 3276 | awaiting_go | 2026-10-28 | ＪＰＭＣ。32×32→180×180 staged review/2026-10-28 |
| 3300 | awaiting_go | 2026-10-28 | アンビションＤＸホールディングス。32×32→180×180 staged review/2026-10-28 |
| 3329 | awaiting_go | 2026-10-28 | 東和フードサービス。37×37→180×180 staged review/2026-10-28 |
| 3346 | awaiting_go | 2026-10-28 | ヒロタグループホールディングス。32×32→180×180 staged review/2026-10-28 |
| 3387 | awaiting_go | 2026-10-28 | クリエイト・レストランツ・ホールディング。32×32→180×180 staged review/2026-10-28 |
| 340A | awaiting_go | 2026-10-28 | ジグザグ。32×32→180×180 staged review/2026-10-28 |
| 3415 | awaiting_go | 2026-10-28 | ＴＯＫＹＯＢＡＳＥ。32×32→180×180 staged review/2026-10-28 |
| 3433 | awaiting_go | 2026-10-28 | トーカロ。32×32→144×144 staged review/2026-10-28 |
| 3440 | awaiting_go | 2026-10-28 | 日創グループ。32×32→180×180 staged review/2026-10-28 |
| 3496 | awaiting_go | 2026-10-28 | アズーム。32×32→512×512 staged review/2026-10-28 |
| 3521 | awaiting_go | 2026-10-28 | テルマー湯ホールディングス。32×32→180×180 staged review/2026-10-28 |
| 3559 | awaiting_go | 2026-10-28 | ピーバンドットコム。16×16→500×500 staged review/2026-10-28 |
| 3600 | awaiting_go | 2026-10-28 | フジックス。16×16→500×500 staged review/2026-10-28 |
| 3622 | awaiting_go | 2026-10-28 | ネットイヤーグループ。16×16→180×180 staged review/2026-10-28 |
| 3698 | awaiting_go | 2026-10-28 | ＣＲＩ・ミドルウェア。16×16→180×180 staged review/2026-10-28 |
| 369A | awaiting_go | 2026-10-28 | エータイ。32×32→180×180 staged review/2026-10-28 |
| 3723 | awaiting_go | 2026-10-28 | 日本ファルコム。32×32→512×512 staged review/2026-10-28 |
| 3727 | awaiting_go | 2026-10-28 | アプリックス。32×32→180×180 staged review/2026-10-28 |
| 3773 | awaiting_go | 2026-10-28 | アドバンスト・メディア。16×16→160×160 staged review/2026-10-28 |
| 3775 | awaiting_go | 2026-10-28 | ガイアックス。32×32→180×180 staged review/2026-10-28 |
| 3841 | awaiting_go | 2026-10-28 | ジーダット。32×32→180×180 staged review/2026-10-28 |
| 3853 | awaiting_go | 2026-10-28 | アステリア。32×32→192×192 staged review/2026-10-28 |
| 3865 | awaiting_go | 2026-10-28 | 北越コーポレーション。48×48→180×180 staged review/2026-10-28 |
| 3912 | awaiting_go | 2026-10-28 | モバイルファクトリー。16×16→180×180 staged review/2026-10-28 |
| 3920 | awaiting_go | 2026-10-28 | アイビーシー。32×32→180×180 staged review/2026-10-28 |
| 3936 | awaiting_go | 2026-10-28 | グローバルウェイ。32×32→180×180 staged review/2026-10-28 |
| 3985 | awaiting_go | 2026-10-28 | テモナ。1×1→512×512 staged review/2026-10-28 |
| 4046 | awaiting_go | 2026-10-28 | 大阪ソーダ。32×32→144×144 staged review/2026-10-28 |
| 4064 | awaiting_go | 2026-10-28 | 日本カーバイド工業。32×32→180×180 staged review/2026-10-28 |
| 4075 | awaiting_go | 2026-10-28 | ブレインズテクノロジー。17×17→500×500 staged review/2026-10-28 |
| 410A | awaiting_go | 2026-10-28 | ＧＭＯコマース。32×32→180×180 staged review/2026-10-28 |
| 4112 | awaiting_go | 2026-10-28 | 保土谷化学工業。32×32→180×180 staged review/2026-10-28 |
| 4196 | awaiting_go | 2026-10-28 | ネオマーケティング。16×16→398×397 staged review/2026-10-28 |
| 4237 | awaiting_go | 2026-10-28 | フジプレアム。32×32→180×180 staged review/2026-10-28 |
| 4238 | awaiting_go | 2026-10-28 | ミライアル。32×32→180×180 staged review/2026-10-28 |
| 4243 | awaiting_go | 2026-10-28 | ニックス。32×32→180×180 staged review/2026-10-28 |
| 4284 | awaiting_go | 2026-10-28 | ソルクシーズ。32×32→180×180 staged review/2026-10-28 |
| 428A | awaiting_go | 2026-10-28 | サイプレス・ホールディングス。32×32→180×180 staged review/2026-10-28 |
| 4370 | awaiting_go | 2026-10-28 | モビルス。32×32→180×180 staged review/2026-10-28 |
| 4409 | awaiting_go | 2026-10-28 | 東邦化学工業。32×32→129×129 staged review/2026-10-28 |
| 4414 | awaiting_go | 2026-10-28 | フレクト。32×32→180×180 staged review/2026-10-28 |
| 4439 | awaiting_go | 2026-10-28 | 東名。48×48→600×600 staged review/2026-10-28 |
| 4441 | awaiting_go | 2026-10-28 | トビラシステムズ。96×96→320×320 staged review/2026-10-28 |
| 4450 | awaiting_go | 2026-10-28 | パワーソリューションズ。32×32→180×180 staged review/2026-10-28 |
| 4465 | awaiting_go | 2026-10-28 | ニイタカ。32×32→180×180 staged review/2026-10-28 |
| 4479 | awaiting_go | 2026-10-28 | マクアケ。32×32→360×360 staged review/2026-10-28 |
| 4544 | awaiting_go | 2026-10-28 | Ｈ．Ｕ．グループホールディングス。32×32→180×180 staged review/2026-10-28 |
| 4568 | awaiting_go | 2026-10-28 | 第一三共。16×16→180×180 staged review/2026-10-28 |
| 4571 | awaiting_go | 2026-10-28 | ＮＡＮＯホールディングス。32×32→512×512 staged review/2026-10-28 |
| 4633 | awaiting_go | 2026-10-28 | サカタインクス。32×32→180×180 staged review/2026-10-28 |
| 4642 | awaiting_go | 2026-10-28 | オリジナル設計。32×32→180×180 staged review/2026-10-28 |
| 4644 | awaiting_go | 2026-10-28 | イマジニア。16×16→400×400 staged review/2026-10-28 |
| 4664 | awaiting_go | 2026-10-28 | アール・エス・シー。32×32→180×180 staged review/2026-10-28 |
| 4685 | awaiting_go | 2026-10-28 | 菱友システムズ。16×16→192×192 staged review/2026-10-28 |
| 471A | awaiting_go | 2026-10-28 | ＮＳグループ。32×32→180×180 staged review/2026-10-28 |
| 4735 | awaiting_go | 2026-10-28 | 京進。32×32→180×180 staged review/2026-10-28 |
| 4746 | awaiting_go | 2026-10-28 | 東計電算。32×32→180×180 staged review/2026-10-28 |
| 4751 | awaiting_go | 2026-10-28 | サイバーエージェント。32×32→2226×2196 staged review/2026-10-28 |
| 4760 | awaiting_go | 2026-10-28 | アルファ。32×32→180×180 staged review/2026-10-28 |
| 4777 | awaiting_go | 2026-10-28 | ガーラ。32×32→256×256 staged review/2026-10-28 |
| 4801 | awaiting_go | 2026-10-28 | セントラルスポーツ。32×32→152×152 staged review/2026-10-28 |
| 4809 | awaiting_go | 2026-10-28 | パラカ。32×32→180×180 staged review/2026-10-28 |
| 4826 | awaiting_go | 2026-10-28 | ＣＩＪ。32×32→180×180 staged review/2026-10-28 |
| 4833 | awaiting_go | 2026-10-28 | Ｄｅｆｃｏｎｓｕｌｔｉｎｇ。32×32→180×180 staged review/2026-10-28 |
| 4883 | awaiting_go | 2026-10-28 | モダリス。32×32→180×180 staged review/2026-10-28 |
| 4932 | awaiting_go | 2026-10-28 | アルマード。32×32→180×180 staged review/2026-10-28 |
| 4936 | awaiting_go | 2026-10-28 | アクシージア。32×32→360×360 staged review/2026-10-28 |
| 5031 | awaiting_go | 2026-10-28 | モイ。32×32→180×180 staged review/2026-10-28 |
| 5035 | awaiting_go | 2026-10-28 | ＨＯＵＳＥＩ。32×32→256×256 staged review/2026-10-28 |
| 5132 | awaiting_go | 2026-10-28 | ｐｌｕｓｚｅｒｏ。32×32→152×152 staged review/2026-10-28 |
| 5136 | awaiting_go | 2026-10-28 | ｔｒｉｐｌａ。32×32→180×180 staged review/2026-10-28 |
| 5138 | awaiting_go | 2026-10-28 | Ｒｅｂａｓｅ。32×32→256×256 staged review/2026-10-28 |
| 520A | awaiting_go | 2026-10-28 | ジェイファーマ。32×32→180×180 staged review/2026-10-28 |
| 5262 | awaiting_go | 2026-10-28 | 日本ヒューム。32×32→180×180 staged review/2026-10-28 |
| 5310 | awaiting_go | 2026-10-28 | 東洋炭素。16×16→128×128 staged review/2026-10-28 |
| 5542 | awaiting_go | 2026-10-28 | 新報国マテリアル。32×32→180×180 staged review/2026-10-28 |
| 556A | awaiting_go | 2026-10-28 | 犬猫生活。32×32→180×180 staged review/2026-10-28 |
| 5571 | awaiting_go | 2026-10-28 | エキサイトホールディングス。32×32→180×180 staged review/2026-10-28 |
| 5588 | awaiting_go | 2026-10-28 | ファーストアカウンティング。32×32→180×180 staged review/2026-10-28 |
| 5612 | awaiting_go | 2026-10-28 | 日本鋳鉄管。32×32→192×192 staged review/2026-10-28 |
| 5619 | awaiting_go | 2026-10-28 | マーソ。32×32→180×180 staged review/2026-10-28 |
| 5631 | awaiting_go | 2026-10-28 | 日本製鋼所。32×32→180×180 staged review/2026-10-28 |
| 5699 | awaiting_go | 2026-10-28 | イボキン。32×32→180×180 staged review/2026-10-28 |
| 5753 | awaiting_go | 2026-10-28 | 日本伸銅。32×32→180×180 staged review/2026-10-28 |
| 5816 | awaiting_go | 2026-10-28 | オーナンバ。32×32→180×180 staged review/2026-10-28 |
| 5933 | awaiting_go | 2026-10-28 | アルインコ。16×16→180×180 staged review/2026-10-28 |
| 5952 | awaiting_go | 2026-10-28 | アマテイ。32×32→152×152 staged review/2026-10-28 |
| 6031 | awaiting_go | 2026-10-28 | ＺＥＴＡ。32×32→180×180 staged review/2026-10-28 |
| 6061 | awaiting_go | 2026-10-28 | ユニバーサル園芸社。32×32→180×180 staged review/2026-10-28 |
| 6088 | awaiting_go | 2026-10-28 | シグマクシス・ホールディングス。32×32→144×144 staged review/2026-10-28 |
| 6099 | awaiting_go | 2026-10-28 | エラン。32×32→180×180 staged review/2026-10-28 |
| 6155 | awaiting_go | 2026-10-28 | 高松機械工業。48×48→192×192 staged review/2026-10-28 |
| 6171 | awaiting_go | 2026-10-28 | 土木管理総合試験所。32×32→180×180 staged review/2026-10-28 |
| 6186 | awaiting_go | 2026-10-28 | 一蔵。32×32→180×180 staged review/2026-10-28 |
| 6224 | awaiting_go | 2026-10-28 | ＪＲＣ。32×32→180×180 staged review/2026-10-28 |
| 6228 | awaiting_go | 2026-10-28 | ジェイ・イー・ティ。32×32→180×180 staged review/2026-10-28 |
| 6268 | awaiting_go | 2026-10-28 | ナブテスコ。32×32→180×180 staged review/2026-10-28 |
| 6289 | awaiting_go | 2026-10-28 | 技研製作所。32×32→180×180 staged review/2026-10-28 |
| 6325 | awaiting_go | 2026-10-28 | タカキタ。32×32→180×180 staged review/2026-10-28 |
| 6335 | awaiting_go | 2026-10-28 | 東京機械製作所。32×32→180×180 staged review/2026-10-28 |
| 6346 | awaiting_go | 2026-10-28 | キクカワエンタープライズ。32×32→180×180 staged review/2026-10-28 |
| 6357 | awaiting_go | 2026-10-28 | 三精テクノロジーズ。32×32→180×180 staged review/2026-10-28 |
| 6367 | awaiting_go | 2026-10-28 | ダイキン工業。32×32→180×180 staged review/2026-10-28 |
| 6381 | awaiting_go | 2026-10-28 | アネスト岩田。16×16→800×800 staged review/2026-10-28 |
| 6395 | awaiting_go | 2026-10-28 | タダノ。32×32→180×180 staged review/2026-10-28 |
| 6418 | awaiting_go | 2026-10-28 | 日本金銭機械。32×32→144×144 staged review/2026-10-28 |
| 6464 | awaiting_go | 2026-10-28 | ツバキ・ナカシマ。32×32→180×180 staged review/2026-10-28 |
| 6479 | awaiting_go | 2026-10-28 | ミネベアミツミ。32×32→180×180 staged review/2026-10-28 |
| 6522 | awaiting_go | 2026-10-28 | アスタリスク。32×32→180×180 staged review/2026-10-28 |
| 6554 | awaiting_go | 2026-10-28 | エスユーエス。32×32→180×180 staged review/2026-10-28 |
| 6557 | awaiting_go | 2026-10-28 | ＡＩＡＩグループ。32×32→180×180 staged review/2026-10-28 |
| 6651 | awaiting_go | 2026-10-28 | 日東工業。32×32→180×180 staged review/2026-10-28 |
| 6656 | awaiting_go | 2026-10-28 | インスペック。32×32→200×200 staged review/2026-10-28 |
| 6662 | awaiting_go | 2026-10-28 | ユビテック。32×32→180×180 staged review/2026-10-28 |
| 6695 | awaiting_go | 2026-10-28 | キャストリコ。32×32→180×180 staged review/2026-10-28 |
| 6741 | awaiting_go | 2026-10-28 | 日本信号。32×32→180×180 staged review/2026-10-28 |
| 6803 | awaiting_go | 2026-10-28 | ティアック。32×32→180×180 staged review/2026-10-28 |
| 6837 | awaiting_go | 2026-10-28 | 京写。16×16→129×129 staged review/2026-10-28 |
| 6841 | awaiting_go | 2026-10-28 | 横河電機。16×16→144×144 staged review/2026-10-28 |
| 6912 | awaiting_go | 2026-10-28 | 菊水ホールディングス。32×32→180×180 staged review/2026-10-28 |
| 6964 | awaiting_go | 2026-10-28 | サンコー。32×32→180×180 staged review/2026-10-28 |
| 7012 | awaiting_go | 2026-10-28 | 川崎重工業。32×32→180×180 staged review/2026-10-28 |
| 7021 | awaiting_go | 2026-10-28 | ニッチツ。32×32→180×180 staged review/2026-10-28 |
| 7041 | awaiting_go | 2026-10-28 | ＣＲＧホールディングス。32×32→192×192 staged review/2026-10-28 |
| 7046 | awaiting_go | 2026-10-28 | ＴＤＳＥ。32×32→180×180 staged review/2026-10-28 |
| 7060 | awaiting_go | 2026-10-28 | ギークス。32×32→180×180 staged review/2026-10-28 |
| 7068 | awaiting_go | 2026-10-28 | フィードフォースグループ。32×32→180×180 staged review/2026-10-28 |
| 7082 | awaiting_go | 2026-10-28 | ジモティー。64×64→600×400 staged review/2026-10-28 |
| 7083 | awaiting_go | 2026-10-28 | ＡＨＣグループ。32×32→180×180 staged review/2026-10-28 |
| 7089 | awaiting_go | 2026-10-28 | フォースタートアップス。32×32→256×256 staged review/2026-10-28 |
| 7090 | awaiting_go | 2026-10-28 | リグア。32×32→180×180 staged review/2026-10-28 |
| 7157 | awaiting_go | 2026-10-28 | ライフネット生命保険。32×32→144×144 staged review/2026-10-28 |
| 7235 | awaiting_go | 2026-10-28 | 東京ラヂエーター製造。32×32→180×180 staged review/2026-10-28 |
| 7241 | awaiting_go | 2026-10-28 | フタバ産業。32×32→180×180 staged review/2026-10-28 |
| 7254 | awaiting_go | 2026-10-28 | ユニバンス。64×64→180×180 staged review/2026-10-28 |
| 7279 | awaiting_go | 2026-10-28 | ハイレックスコーポレーション。32×32→180×180 staged review/2026-10-28 |
| 7291 | awaiting_go | 2026-10-28 | 日本プラスト。32×32→180×180 staged review/2026-10-28 |
| 7294 | awaiting_go | 2026-10-28 | ヨロズ。32×32→180×180 staged review/2026-10-28 |
| 7318 | awaiting_go | 2026-10-28 | セレンディップ・ホールディングス。32×32→180×180 staged review/2026-10-28 |
| 7320 | awaiting_go | 2026-10-28 | Ｓｏｌｖｖｙ。32×32→180×180 staged review/2026-10-28 |
| 7361 | awaiting_go | 2026-10-28 | ヒューマンクリエイションホールディングス。32×32→180×180 staged review/2026-10-28 |
| 7367 | awaiting_go | 2026-10-28 | セルム。32×32→180×180 staged review/2026-10-28 |
| 7426 | awaiting_go | 2026-10-28 | 山大。32×32→180×180 staged review/2026-10-28 |
| 7510 | awaiting_go | 2026-10-28 | たけびし。32×32→256×256 staged review/2026-10-28 |
| 7537 | awaiting_go | 2026-10-28 | 丸文。32×32→180×180 staged review/2026-10-28 |
| 7567 | awaiting_go | 2026-10-28 | 栄電子。32×32→180×180 staged review/2026-10-28 |
| 7585 | awaiting_go | 2026-10-28 | かんなん丸。32×32→180×180 staged review/2026-10-28 |
| 7606 | awaiting_go | 2026-10-28 | ユナイテッドアローズ。32×32→180×180 staged review/2026-10-28 |
| 7608 | awaiting_go | 2026-10-28 | エスケイジャパン。32×32→180×180 staged review/2026-10-28 |
| 7678 | awaiting_go | 2026-10-28 | あさくま。16×16→220×160 staged review/2026-10-28 |
| 7683 | awaiting_go | 2026-10-28 | ダブルエー。32×32→180×180 staged review/2026-10-28 |
| 7687 | awaiting_go | 2026-10-28 | ミクリード。32×32→180×180 staged review/2026-10-28 |
| 7689 | awaiting_go | 2026-10-28 | コパ・コーポレーション。32×32→152×152 staged review/2026-10-28 |
| 7790 | awaiting_go | 2026-10-28 | バルコス。32×32→180×180 staged review/2026-10-28 |
| 7809 | awaiting_go | 2026-10-28 | 壽屋。32×32→180×180 staged review/2026-10-28 |
| 7821 | awaiting_go | 2026-10-28 | 前田工繊。16×16→2191×1906 staged review/2026-10-28 |
| 7831 | awaiting_go | 2026-10-28 | ウイルコホールディングス。32×32→180×180 staged review/2026-10-28 |
| 7841 | awaiting_go | 2026-10-28 | 遠藤製作所。32×32→180×180 staged review/2026-10-28 |
| 7850 | awaiting_go | 2026-10-28 | 総合商研。32×32→180×180 staged review/2026-10-28 |
| 7856 | awaiting_go | 2026-10-28 | 萩原工業。16×16→300×297 staged review/2026-10-28 |
| 7871 | awaiting_go | 2026-10-28 | フクビ化学工業。32×32→152×152 staged review/2026-10-28 |
| 7874 | awaiting_go | 2026-10-28 | レック。32×32→180×180 staged review/2026-10-28 |
| 7917 | awaiting_go | 2026-10-28 | ＺＡＣＲＯＳ。32×32→180×180 staged review/2026-10-28 |
| 7936 | awaiting_go | 2026-10-28 | アシックス。32×32→1920×1280 staged review/2026-10-28 |
| 7946 | awaiting_go | 2026-10-28 | 光陽社。32×32→256×256 staged review/2026-10-28 |
| 7975 | awaiting_go | 2026-10-28 | リヒトラブ。32×32→180×180 staged review/2026-10-28 |
| 7987 | awaiting_go | 2026-10-28 | ナカバヤシ。16×16→468×468 staged review/2026-10-28 |
| 8032 | awaiting_go | 2026-10-28 | 日本紙パルプ商事。64×64→192×192 staged review/2026-10-28 |
| 8107 | awaiting_go | 2026-10-28 | キムラタン。32×32→180×180 staged review/2026-10-28 |
| 8129 | awaiting_go | 2026-10-28 | 東邦ホールディングス。32×32→180×180 staged review/2026-10-28 |
| 8200 | awaiting_go | 2026-10-28 | リンガーハット。32×32→180×180 staged review/2026-10-28 |
| 8218 | awaiting_go | 2026-10-28 | コメリ。16×16→180×180 staged review/2026-10-28 |
| 8260 | awaiting_go | 2026-10-28 | 井筒屋。16×16→150×150 staged review/2026-10-28 |
| 8278 | awaiting_go | 2026-10-28 | フジ。32×32→180×180 staged review/2026-10-28 |
| 8537 | awaiting_go | 2026-10-28 | 大光銀行。32×32→180×180 staged review/2026-10-28 |
| 8550 | awaiting_go | 2026-10-28 | 栃木銀行。32×32→250×250 staged review/2026-10-28 |
| 8708 | awaiting_go | 2026-10-28 | アイザワ証券グループ。48×48→144×144 staged review/2026-10-28 |
| 8771 | awaiting_go | 2026-10-28 | イー・ギャランティ。32×32→180×180 staged review/2026-10-28 |
| 8914 | awaiting_go | 2026-10-28 | エリアリンク。32×32→180×180 staged review/2026-10-28 |
| 9008 | awaiting_go | 2026-10-28 | 京王電鉄。48×48→180×180 staged review/2026-10-28 |
| 9036 | awaiting_go | 2026-10-28 | 東部ネットワーク。32×33→180×184 staged review/2026-10-28 |
| 9107 | awaiting_go | 2026-10-28 | 川崎汽船。16×16→128×145 staged review/2026-10-28 |
| 9110 | awaiting_go | 2026-10-28 | ＮＳユナイテッド海運。32×32→144×144 staged review/2026-10-28 |
| 9166 | awaiting_go | 2026-10-28 | ＧＥＮＤＡ。32×32→180×180 staged review/2026-10-28 |
| 9214 | awaiting_go | 2026-10-28 | ＲｅｃｏｖｅｒｙＩｎｔｅｒｎａｔｉｏｎａ。16×16→834×630 staged review/2026-10-28 |
| 9229 | awaiting_go | 2026-10-28 | サンウェルズ。32×32→180×180 staged review/2026-10-28 |
| 9240 | awaiting_go | 2026-10-28 | デリバリーコンサルティング。32×32→152×152 staged review/2026-10-28 |
| 9251 | awaiting_go | 2026-10-28 | ＡＢ＆Ｃｏｍｐａｎｙ。32×32→180×180 staged review/2026-10-28 |
| 9278 | awaiting_go | 2026-10-28 | ブックオフグループホールディングス。32×32→180×180 staged review/2026-10-28 |
| 9279 | awaiting_go | 2026-10-28 | ギフトホールディングス。32×32→256×256 staged review/2026-10-28 |
| 9332 | awaiting_go | 2026-10-28 | ＮＩＳＳＯホールディングス。32×32→1000×1000 staged review/2026-10-28 |
| 9381 | awaiting_go | 2026-10-28 | エーアイテイー。32×32→180×180 staged review/2026-10-28 |
| 9434 | awaiting_go | 2026-10-28 | ソフトバンク。16×16→200×200 staged review/2026-10-28 |
| 9475 | awaiting_go | 2026-10-28 | 昭文社ホールディングス。32×32→180×180 staged review/2026-10-28 |
| 9556 | awaiting_go | 2026-10-28 | ＩＮＴＬＯＯＰ。32×32→180×180 staged review/2026-10-28 |
| 9601 | awaiting_go | 2026-10-28 | 松竹。16×16→1200×900 staged review/2026-10-28 |
| 9699 | awaiting_go | 2026-10-28 | ニシオホールディングス。32×32→180×180 staged review/2026-10-28 |
| 9716 | awaiting_go | 2026-10-28 | 乃村工藝社。48×48→260×260 staged review/2026-10-28 |
| 9723 | awaiting_go | 2026-10-28 | 京都ホテル。64×64→192×192 staged review/2026-10-28 |
| 9769 | awaiting_go | 2026-10-28 | 学究社。32×32→180×180 staged review/2026-10-28 |
| 9902 | awaiting_go | 2026-10-28 | 日伝。32×32→180×180 staged review/2026-10-28 |
| 9932 | awaiting_go | 2026-10-28 | 杉本商事。32×32→180×180 staged review/2026-10-28 |
| 9941 | awaiting_go | 2026-10-28 | 太洋物産。32×32→180×180 staged review/2026-10-28 |
| 9978 | awaiting_go | 2026-10-28 | 文教堂グループホールディングス。32×32→180×180 staged review/2026-10-28 |
| 9984 | awaiting_go | 2026-10-28 | ソフトバンクグループ。16×16→630×630 staged review/2026-10-28 |
