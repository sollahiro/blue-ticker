// 実 EDINET XBRL キャッシュ（analysis_cache）での 財務諸表注記取り込み Statement Notes 決定論 resolver の
// 回帰テスト（2026-08-01 実データ検証）。
//
// sga_breakdown: 「販売費及び一般管理費の主要な内訳」注記は role=NotesStatementOfIncome 配下に
// 格納され、内訳科目タグは会社ごとに異なる拡張タグ名だが末尾は必ず SGA で統一されている。
// 固定タグリストではなく「role + tag接尾辞」の構造的パターンで会社非依存に抽出できることを
// 複数社の実データで確認する。開示コンテキストは常に非連結（`NonConsolidatedMember`）だが、
// これは会計基準（IFRS/J-GAAP）とは無関係（実データ検証: IFRS連結のトヨタ自動車 S100VWVY も
// この注記を持つ。単体決算が J-GAAP ベースであることに起因し、連結側の会計基準では判定できない
// ため、resolver も会計基準を条件分岐に使わない）。キャッシュ済み144件中99件で解決・45件が
// 正当な not_applicable（役割自体の不掲載）だった（キャッシュ全走査で確認、2026-08-01）。
//
// borrowings_schedule_cf_supplement: 連結附属明細表「借入金等明細表」を `BorrowingsSchedule.extract`
// （既存の IBD フォールバックと共有）経由でそのまま表として公開する。キャッシュ済み144件中
// 79件で解決・65件が正当な not_applicable（明細表自体が無い＝XBRL タグで IBD が完結）だった。
//
// policy_holding_securities: 「特定投資株式」（純投資目的以外で保有する上場株式のうち個別開示対象）
// は EDINET 標準タクソノミ（jpcrp_cor）で銘柄ごとに完全に構造化タグされている。contextRef が
// `CurrentYearInstant_Row{N}Member` という規則的な連番になっており、銘柄名・保有株式数・
// 貸借対照表計上額・保有目的が行番号で紐付く（法定開示様式であり、当初計画の想定「LLM必須」は
// 実データと食い違っていた）。20社ランダムサンプルで19/20が解決（キャッシュ全144件では135/144）。
// 提出会社自身が保有する場合は `ReportingCompany` サフィックス、純粋持株会社で子会社が保有する
// 場合は `LargestHoldingCompany`/`SecondLargestHoldingCompany` サフィックスになり、両変体で
// 正しく抽出できることを別会社で確認する。
//
// キャッシュが無い環境では `.enabled(if:)` で自動 SKIP（`swift test` は鍵なしでも緑）。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct RealXbrlStatementNotesTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    // MARK: - 京セラ S100TSIJ

    @Test(.enabled(if: cacheAvailable("S100TSIJ"), "XBRL cache S100TSIJ not available"))
    func kyoceraSGABreakdownExtractsCompanySpecificTagsByRoleAndSuffix() throws {
        let result = StatementNotesResolver.resolveSGABreakdown(xbrlDir: Self.xbrlDir("S100TSIJ"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let items = try #require(payload.items)
        let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0.value) })

        // 実データ検証済みの値（2026-08-01）。
        #expect(byTag["EmployeesSalariesAndAllowancesSGA"] == 30_184_000_000)
        #expect(byTag["ResearchAndDevelopmentExpensesSGA"] == 113_875_000_000)
        #expect(byTag["DepreciationSGA"] == 17_504_000_000)
        // 前期(Prior1YearDuration)の値は混入しない（当期のみ）。
        #expect(items.count == 6)
    }

    // MARK: - S100R09Z（別会社、別タグ名セット）

    @Test(.enabled(if: cacheAvailable("S100R09Z"), "XBRL cache S100R09Z not available"))
    func differentCompanyUsesDifferentCompanySpecificSGATagNames() throws {
        let result = StatementNotesResolver.resolveSGABreakdown(xbrlDir: Self.xbrlDir("S100R09Z"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let items = try #require(payload.items)
        let tags = Set(items.map(\.tag))
        // 京セラには無い、この会社固有の拡張タグ名（固定リストに依存しない設計の確認）。
        #expect(tags.contains("OfficeExpensesSGA"))
        #expect(tags.contains("PromotionalExpensesSGA"))
        #expect(!tags.contains("EmployeesSalariesAndAllowancesSGA"))
    }

    // MARK: - トヨタ自動車 S100VWVY（IFRS連結でも単体側の注記は存在する）

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func ifrsConsolidatedCompanyStillHasNonConsolidatedSGANote() throws {
        let result = StatementNotesResolver.resolveSGABreakdown(xbrlDir: Self.xbrlDir("S100VWVY"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let tags = Set(try #require(payload.items).map(\.tag))
        #expect(tags.contains("SalariesAndAllowancesSGA"))
    }

    // MARK: - S100L0TZ（この注記自体を持たない、正当な not_applicable）

    @Test(.enabled(if: cacheAvailable("S100L0TZ"), "XBRL cache S100L0TZ not available"))
    func companyWithoutTheNoteIsNotApplicableNotAFailure() {
        let result = StatementNotesResolver.resolveSGABreakdown(xbrlDir: Self.xbrlDir("S100L0TZ"))
        guard case .notApplicable(let reason) = result else {
            Issue.record("expected .notApplicable, got \(result)")
            return
        }
        #expect(reason == statementNoteNotApplicableNotFound)
    }

    // MARK: - borrowings_schedule_cf_supplement（S100JRT9、リース負債のみの明細表・千円単位）
    //
    // 実データレビュー（2026-08-02、ユーザーからの実データ確認依頼で発見）: 明細表のヘッダー単位は
    // 会社規模で揺れる（レーザーテック等は「（千円）」、SOMPO・神戸製鋼所等は「（百万円）」）。
    // 修正前は単位を見ず一律 `Financial.millionYen` で換算しており、千円ヘッダーの会社は実際の
    // 1000倍の値を返していた（当時の golden 値 24,202,000,000円 → 正しくは 24,202,000円。
    // レーザーテック当時の総資産 81,794,071,000円 に対し妥当な規模かで裏取り済み）。

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func borrowingsScheduleExtractsComponentsSummingExactlyToTotal() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100JRT9"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        // 実データ検証済みの値（2026-08-02、単位バグ修正後）: リース負債（流動）+ リース負債（非流動）= 合計。
        // 平均利率はいずれも表記「－」（開示なし）のため nil。
        let total = try #require(components.first { $0.isTotal })
        #expect(total.currentBalance == 24_202_000)
        #expect(total.priorBalance == 3_445_000)
        #expect(total.averageInterestRatePercent == nil)
        let componentSum = components.filter { !$0.isTotal }.map { $0.currentBalance ?? 0 }.reduce(0, +)
        #expect(componentSum == total.currentBalance)
    }

    // MARK: - borrowings_schedule_cf_supplement（SOMPO S100R1LR、平均利率・百万円単位）
    //
    // 実データ検証（2026-08-02、ユーザー確認済み）: 短期借入金の当期首50百万円・当期末180百万円・
    // 平均利率0.80%が実際のHTML注記の表と完全一致することを確認済み。合計行の平均利率は「－」
    // （複数金利の単純合計につき意味を持たないため開示されない）ので nil。

    @Test(.enabled(if: cacheAvailable("S100R1LR"), "XBRL cache S100R1LR not available"))
    func goldenBorrowingsSompoInterestRatesAndPriorBalance() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100R1LR"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let components = try #require(payload.borrowingsComponents)
        let shortTerm = try #require(components.first { $0.label == "短期借入金" })
        #expect(shortTerm.priorBalance == 50_000_000)
        #expect(shortTerm.currentBalance == 180_000_000)
        #expect(shortTerm.averageInterestRatePercent == 0.80)

        let total = try #require(components.first { $0.isTotal })
        #expect(total.currentBalance == 662_453_000_000)
        #expect(total.priorBalance == 479_122_000_000)
        #expect(total.averageInterestRatePercent == nil)
    }

    // MARK: - borrowings_schedule_cf_supplement（あおぞら銀行 S100R24O、カテゴリ小計の二重計上防止）
    //
    // 実データ検証（2026-08-03、ユーザーレビューで発見）: 銀行業の明細表は「借用金」（連結BS上の
    // 負債科目名、カテゴリ小計）の下に「再割引手形」「借入金」（内訳の実体行）がインデント付きで
    // 並ぶ。インデントを見ずに全行を合算すると「借用金」と「借入金」が二重計上され、合計が
    // 実際の約2倍（865,193百万円）になっていた。インデント深さで小計行を除外した結果、正しい
    // 合計（借入金 + リース負債流動 + リース負債非流動 = 432,851百万円）になることを確認する。

    @Test(.enabled(if: cacheAvailable("S100R24O"), "XBRL cache S100R24O not available"))
    func goldenBorrowingsAozoraBankExcludesCategorySubtotal() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100R24O"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let components = try #require(payload.borrowingsComponents)

        // 「借用金」（カテゴリ小計）はコンポーネントに含まれず、実体行の「借入金」のみが残ること。
        #expect(components.contains { $0.label == "借入金" })
        #expect(!components.contains { $0.label == "借用金" })

        let total = try #require(components.first { $0.isTotal })
        #expect(total.currentBalance == 525_873_000_000)
        #expect(total.priorBalance == 432_851_000_000)
        let componentSum = components.filter { !$0.isTotal }.map { $0.currentBalance ?? 0 }.reduce(0, +)
        #expect(componentSum == total.currentBalance)
    }

    // MARK: - borrowings_schedule_cf_supplement（KDDI S100R0PR、IFRS注記・セクション小計の除外）
    //
    // 実データ検証（2026-08-03）: J-GAAP附属明細表タグが存在しないIFRS企業は
    // `NotesBondsAndBorrowingsConsolidatedFinancialStatementsIFRSTextBlock` 注記へフォールバックする。
    // 「非流動」「流動」の2区分見出し下に実体行＋セクション小計「　小計」（nbsp+"小計"）が続き、
    // 末尾に真の合計「　合計」がある。セクション小計を除外しないと二重計上になることを確認する。

    @Test(.enabled(if: cacheAvailable("S100R0PR"), "XBRL cache S100R0PR not available"))
    func goldenBorrowingsKDDIIfrsNotesExcludesSectionSubtotal() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100R0PR"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        #expect(!components.contains { $0.label == "小計" })
        let total = try #require(components.first { $0.isTotal })
        #expect(total.currentBalance == 1_252_194_000_000)
        #expect(total.priorBalance == 1_208_121_000_000)
        let componentSum = components.filter { !$0.isTotal }.map { $0.currentBalance ?? 0 }.reduce(0, +)
        #expect(componentSum == total.currentBalance)
    }

    // MARK: - borrowings_schedule_cf_supplement（丸紅 S100VYGC、見出しアンカー方式）
    //
    // 実データ検証（2026-08-04）: J-GAAP附属明細表・IFRS専用タグ（社債及び借入金/有利子負債）の
    // いずれも無く、「金融商品に関する注記」汎用タグ（`NotesFinancialInstrumentsConsolidatedFinancialStatementsIFRSTextBlock`）
    // の中に「⑤　社債及び借入金」「社債及び借入金の帳簿価額の内訳は以下のとおりであります。」という
    // 見出し段落の直後に前/当の内訳表がある。この汎用タグは為替リスク・売掛金等、無関係な表も多数
    // 含むため、見出しテキストをアンカーにして直後の表だけを選ぶ必要があることを確認する。

    @Test(.enabled(if: cacheAvailable("S100YAY4"), "XBRL cache S100YAY4 not available"))
    func goldenBorrowingsMarubeniHeadingAnchoredComparisonTable() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100YAY4"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        let bonds = try #require(components.first { $0.label == "社債" })
        #expect(bonds.priorBalance == 512_546_000_000)
        #expect(bonds.currentBalance == 431_951_000_000)
        let borrowings = try #require(components.first { $0.label == "借入金" })
        #expect(borrowings.priorBalance == 1_935_890_000_000)
        #expect(borrowings.currentBalance == 1_927_051_000_000)

        let total = try #require(components.first { $0.isTotal })
        #expect(total.currentBalance == 2_409_977_000_000)
        #expect(total.priorBalance == 2_535_010_000_000)
        let componentSum = components.filter { !$0.isTotal }.map { $0.currentBalance ?? 0 }.reduce(0, +)
        #expect(componentSum == total.currentBalance)
    }

    // MARK: - borrowings_schedule_cf_supplement（日立製作所 S100YGBO、満期構成ペアテーブル）
    //
    // 実データ検証（2026-08-04）: 前/当の比較列を持つ表が無く、「金融商品に関する注記」汎用タグの
    // 中に会計年度末ごとの別テーブル（先頭行に単一の日付、「帳簿価額｜契約上のキャッシュ・フロー｜
    // １年以内｜１年超５年以内｜５年超」列を持つ満期構成表）が2つ並ぶ。信用リスク・
    // 非支配持分プットオプション等の無関係な行が混入しないよう、社債・借入金・リース関連ラベルの
    // 帳簿価額のみを合算していることを確認する。

    @Test(.enabled(if: cacheAvailable("S100YGBO"), "XBRL cache S100YGBO not available"))
    func goldenBorrowingsHitachiMaturityBucketPairTables() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100YGBO"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        // プット・オプション等、社債・借入金・リース以外の行は混入しないこと。
        #expect(!components.contains { $0.label.contains("プット") })

        let bonds = try #require(components.first { $0.label == "社債" })
        #expect(bonds.priorBalance == 220_000_000_000)
        #expect(bonds.currentBalance == 220_000_000_000)
        let longTerm = try #require(components.first { $0.label == "長期借入金" })
        #expect(longTerm.priorBalance == 653_797_000_000)
        #expect(longTerm.currentBalance == 443_696_000_000)

        let total = try #require(components.first { $0.isTotal })
        #expect(total.currentBalance == 1_009_037_000_000)
        #expect(total.priorBalance == 1_206_116_000_000)
        let componentSum = components.filter { !$0.isTotal }.map { $0.currentBalance ?? 0 }.reduce(0, +)
        #expect(componentSum == total.currentBalance)
    }

    // MARK: - borrowings_schedule_cf_supplement（ソニーグループ S100YE2C、自社拡張タグ＋rowspanヘッダー補正）
    //
    // 実データ検証（2026-08-04）: 満期構成表が汎用「金融商品に関する注記」タグではなく自社拡張タグ
    // （`NotesShortTermBorrowingsAndLongTermDebtConsolidatedFinancialStatementsIFRSTextBlock`）に
    // 格納される。さらにヘッダー行が「項目」列をrowspanで上段と共有しヘッダー行自体には値列の
    // 先頭に「項目」のプレースホルダーが無いため、そのまま列位置を使うとデータ行と1列ズレる
    // （直後のデータ行のセル数がヘッダー行より多い分だけ右にずらす補正が必要）ことを確認する。

    @Test(.enabled(if: cacheAvailable("S100YE2C"), "XBRL cache S100YE2C not available"))
    func goldenBorrowingsSonyGroupExtensionTagWithRowspanHeaderOffset() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100YE2C"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        let shortTerm = try #require(components.first { $0.label == "短期借入金" })
        #expect(shortTerm.priorBalance == 1_843_959_000_000)
        #expect(shortTerm.currentBalance == 51_183_000_000)
        let unsecuredBonds = try #require(components.first { $0.label == "無担保社債" })
        #expect(unsecuredBonds.priorBalance == 664_390_000_000)
        #expect(unsecuredBonds.currentBalance == 474_343_000_000)

        let total = try #require(components.first { $0.isTotal })
        #expect(total.currentBalance == 1_041_986_000_000)
        #expect(total.priorBalance == 3_598_776_000_000)
        let componentSum = components.filter { !$0.isTotal }.map { $0.currentBalance ?? 0 }.reduce(0, +)
        #expect(componentSum == total.currentBalance)
    }

    // MARK: - borrowings_schedule_cf_supplement（三菱重工業 S100YHZG、自社拡張タグ・非借入項目を含む全体構造化）
    //
    // 実データ検証（2026-08-04）: 「社債、借入金及びその他の金融負債」注記（自社拡張タグ）は
    // 区分｜前期｜当期の3列で「前」「当」を含み、社債・借入金・リース以外にデリバティブ負債・
    // 債権流動化等に伴う支払債務・その他も同一表に並ぶ。`parseComparisonTable`はラベルで絞り込まず、
    // 注記自身の「合計」行をそのまま採用する設計のため、これらの非借入項目も含めてそのまま
    // 構造化されることを確認する（Statementとしての全体構造化方針、ユーザー承認2026-08-04）。

    @Test(.enabled(if: cacheAvailable("S100YHZG"), "XBRL cache S100YHZG not available"))
    func goldenBorrowingsMitsubishiHeavyIndustriesExtensionTagIncludesNonDebtItems() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100YHZG"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        // 社債・借入金・リース以外の非借入項目も注記どおりそのまま構造化されること。
        let derivatives = try #require(components.first { $0.label.contains("デリバティブ負債") })
        #expect(derivatives.priorBalance == 6_331_000_000)
        #expect(derivatives.currentBalance == 12_332_000_000)
        let securitization = try #require(components.first { $0.label.contains("債権流動化") })
        #expect(securitization.priorBalance == 288_041_000_000)
        #expect(securitization.currentBalance == 174_610_000_000)

        let bonds = try #require(components.first { $0.label.contains("社債") })
        #expect(bonds.priorBalance == 225_000_000_000)
        #expect(bonds.currentBalance == 200_000_000_000)

        // 注記自身の「合計」行をそのまま採用する（自前フィルタ合算ではない）。開示側の丸め誤差
        // （各行を百万円単位に丸めた後の合算のため、合計行と3百万円ずれる）があるため、
        // 個別行の合算とは一致検証しない。
        let total = try #require(components.first { $0.isTotal })
        #expect(total.priorBalance == 1_131_274_000_000)
        #expect(total.currentBalance == 876_241_000_000)
    }

    // MARK: - borrowings_schedule_cf_supplement（東京海上ホールディングス S100YLS8、保険会社の投資契約負債込み拡張タグ）
    //
    // 実データ検証（2026-08-04）: 保険会社は「社債、借入金及び投資契約負債」を1注記にまとめる
    // 自社拡張タグを使う。列構成は「区分｜移行日｜前期｜当期｜平均利率｜返済期限」（J-GAAP附属
    // 明細表に「移行日」列が1つ増えた形）で、`parseComparisonTable`のヘッダー検出（"前"/"当"の
    // 部分一致）が「移行日」列に惑わされず正しく前期/当期列を解決できることを確認する。

    @Test(.enabled(if: cacheAvailable("S100YLS8"), "XBRL cache S100YLS8 not available"))
    func goldenBorrowingsTokioMarineHoldingsExtensionTagIncludesInvestmentContractLiabilities() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100YLS8"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        let investmentContractLiabilities = try #require(
            components.first { $0.label.contains("投資契約負債") && $0.label.contains("除く") })
        #expect(investmentContractLiabilities.priorBalance == 515_627_000_000)
        #expect(investmentContractLiabilities.currentBalance == 617_474_000_000)
        #expect(investmentContractLiabilities.averageInterestRatePercent == 4.8)

        let bonds = try #require(components.first { $0.label.contains("社債") })
        #expect(bonds.priorBalance == 225_761_000_000)
        #expect(bonds.currentBalance == 227_575_000_000)

        // 注記自身の「合計」行をそのまま採用する（開示側の丸め誤差があるため個別行の合算とは
        // 一致検証しない。三菱重工業と同様）。
        let total = try #require(components.first { $0.isTotal })
        #expect(total.priorBalance == 1_418_466_000_000)
        #expect(total.currentBalance == 1_776_849_000_000)
    }

    // MARK: - borrowings_schedule_cf_supplement（住友金属鉱山 S100YJ6N、標準タグ「その他の金融負債」に完全な表）
    //
    // 実データ検証（2026-08-04、ユーザー実データ提示で合計値を確認）: 自社拡張タグではなく標準タグ
    // `NotesOtherFinancialLiabilitiesConsolidatedFinancialStatementsIFRSTextBlock`に、社債・借入金・
    // リースに加えデリバティブ負債・その他も含む区分｜前期｜当期｜平均利率｜返済期限の完全な表が
    // 格納される。列間に罫線用の空白スペーサー列（KDDIと同型）を挟む。

    @Test(.enabled(if: cacheAvailable("S100YJ6N"), "XBRL cache S100YJ6N not available"))
    func goldenBorrowingsSumitomoMetalMiningOtherFinancialLiabilitiesStandardTag() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100YJ6N"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        let shortTermBorrowings = try #require(components.first { $0.label == "短期借入金" })
        #expect(shortTermBorrowings.priorBalance == 70_463_000_000)
        #expect(shortTermBorrowings.currentBalance == 133_960_000_000)
        #expect(shortTermBorrowings.averageInterestRatePercent == 1.95)

        // 社債・借入金・リース以外の非借入項目（デリバティブ負債・その他）も注記どおりそのまま構造化される。
        let derivatives = try #require(components.first { $0.label.contains("デリバティブ負債") })
        #expect(derivatives.priorBalance == 9_670_000_000)
        #expect(derivatives.currentBalance == 5_750_000_000)

        let total = try #require(components.first { $0.isTotal })
        #expect(total.priorBalance == 588_229_000_000)
        #expect(total.currentBalance == 691_184_000_000)
    }

    // MARK: - borrowings_schedule_cf_supplement（三井物産 S100YAVT、連結BS直接タグを注記より優先）
    //
    // 実データ検証（2026-08-04、ユーザーとの対話で発見）: 「短期銀行借入金等」表と「長期債務」表が
    // 別々の注記表に分かれ、後者は区分見出し行（値なし）と金額行（返済期限・利率テキストがラベル）
    // が分離しラベル品質が悪い。連結BSには`ShortTermDebtCLIFRS`／`CurrentPortionOfLongTermDebtCLIFRS`／
    // `LongTermDebtNCLIFRS`という個別の数値タグが揃っており（`LongTermDebtNCLIFRS`は標準タグ、他は
    // 自社拡張タグだがローカル名で解決）、リース負債等も`LongTermDebtNCLIFRS`に正しく合算済みのため、
    // 注記のHTML明細表より直接タグを優先する（`parseDirectDebtFacts`）。

    @Test(.enabled(if: cacheAvailable("S100YAVT"), "XBRL cache S100YAVT not available"))
    func goldenBorrowingsMitsuiPrefersDirectConsolidatedDebtTagsOverMessyNoteTable() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100YAVT"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        // 直接タグ経由のため3行（短期負債／1年内返済予定の長期負債／長期負債）のみで、
        // 注記の返済期限・利率テキストのような不明瞭なラベルは混入しない。
        #expect(components.filter { !$0.isTotal }.count == 3)

        let shortTermDebt = try #require(components.first { $0.label == "短期負債" })
        #expect(shortTermDebt.priorBalance == 163_909_000_000)
        #expect(shortTermDebt.currentBalance == 166_249_000_000)

        let longTermDebt = try #require(components.first { $0.label == "長期負債" })
        #expect(longTermDebt.priorBalance == 4_047_663_000_000)
        #expect(longTermDebt.currentBalance == 5_032_042_000_000)

        let total = try #require(components.first { $0.isTotal })
        #expect(total.priorBalance == 4_841_260_000_000)
        #expect(total.currentBalance == 5_707_766_000_000)
    }

    // MARK: - borrowings_schedule_cf_supplement（ファーストリテイリング S100X6X6、資産/負債併存タグから負債側のみ選択）
    //
    // 実データ検証（2026-08-04、ユーザー提示の実データで確認）: 標準タグ「その他の金融資産及び
    // その他の金融負債に関する注記」は資産セクションと負債セクションが同一タグ内に併存し、資産側の
    // 表も「前」「当」列を持つため銘柄除外だけでは資産表を誤選択する。社債・借入金・リース・
    // 有利子負債のいずれかを含む表のみを対象にする条件を追加して負債側を正しく選択する。負債側は
    // 「有利子負債（注）」という単一集約行のみ（社債/借入金/リースへの内訳分解はされない）。

    @Test(.enabled(if: cacheAvailable("S100X6X6"), "XBRL cache S100X6X6 not available"))
    func goldenBorrowingsFastRetailingSelectsLiabilitiesTableNotAssetsTable() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100X6X6"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        let interestBearingDebt = try #require(components.first { $0.label.contains("有利子負債") })
        #expect(interestBearingDebt.priorBalance == 240_935_000_000)
        #expect(interestBearingDebt.currentBalance == 211_328_000_000)

        // 資産側の項目（債券・敷金保証金等）が混入しないこと。
        #expect(!components.contains { $0.label.contains("債券") })

        let total = try #require(components.first { $0.isTotal })
        #expect(total.priorBalance == 315_917_000_000)
        #expect(total.currentBalance == 292_013_000_000)
    }

    // MARK: - borrowings_schedule_cf_supplement（ディスコ S100YC6I、無借金だがリース負債のみ計上）
    //
    // 実データ検証（2026-08-04、ユーザーとの対話で発見）: 借入金等明細表は「該当事項はありません」
    // だが、J-GAAP「リース取引に関する注記」（標準タグ）に「区分｜前期｜当期」の単純な表
    // （１年内／１年超／合計）でリース負債の残高が開示される。リース以外の話題を含まないタグの
    // ため、通常の社債・借入金キーワード必須の候補選定を適用せず`parseLeaseOnlyNote`で解決する。

    @Test(.enabled(if: cacheAvailable("S100YC6I"), "XBRL cache S100YC6I not available"))
    func goldenBorrowingsDiscoDebtFreeButHasLeaseLiabilities() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100YC6I"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        let total = try #require(components.first { $0.isTotal })
        #expect(total.priorBalance == 2_647_000_000)
        #expect(total.currentBalance == 3_714_000_000)
    }

    // MARK: - borrowings_schedule_cf_supplement（中外製薬 S100XTBJ、無借金だがリース負債のみ計上・IFRS版）
    //
    // 実データ検証（2026-08-04、ユーザーとの対話で発見）: 借入金等明細表・社債及び借入金注記の
    // いずれも存在しないが、IFRS版「リース」注記（標準タグ）に満期構成ペアテーブル形式（会計年度末
    // ごとに別テーブル、「帳簿価額」列）でリース負債の残高が開示される。「リース負債」1行のみの表
    // のため、`parseMaturityBucketPairTables`の通常の2行以上要件を`minMatchingRows: 1`で緩めて解決する。

    @Test(.enabled(if: cacheAvailable("S100XTBJ"), "XBRL cache S100XTBJ not available"))
    func goldenBorrowingsChugaiDebtFreeButHasLeaseLiabilitiesIFRS() throws {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100XTBJ"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let components = try #require(payload.borrowingsComponents)

        let leaseLiabilities = try #require(components.first { $0.label.contains("リース") })
        #expect(leaseLiabilities.priorBalance == 10_897_000_000)
        #expect(leaseLiabilities.currentBalance == 25_711_000_000)

        let total = try #require(components.first { $0.isTotal })
        #expect(total.currentBalance == 25_711_000_000)
    }

    // MARK: - borrowings_schedule_cf_supplement（第一三共 S100QYCY、明細表自体が無い）
    //
    // 実データ検証（2026-08-03）: J-GAAP附属明細表タグ・IFRS社債及び借入金/有利子負債注記タグの
    // いずれも存在しない。借入金等の残高は「金融商品に関する注記」内の流動性リスク（期日別
    // キャッシュ・フロー）表にのみ現れるが、これは残高を期間比較する表ではなく満期バケット別の
    // 表のため、本 note_type の契約（当期首/当期末残高・平均利率）には対応できない
    // （S100TSIJ・村田製作所は2026-08-03のIFRS注記対応で解決するようになったため差し替え）。
    @Test(.enabled(if: cacheAvailable("S100QYCY"), "XBRL cache S100QYCY not available"))
    func borrowingsScheduleNotApplicableWhenScheduleAbsent() {
        let result = StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(
            xbrlDir: Self.xbrlDir("S100QYCY"))
        guard case .notApplicable(let reason) = result else {
            Issue.record("expected .notApplicable, got \(result)")
            return
        }
        #expect(reason == statementNoteNotApplicableNotFound)
    }

    // MARK: - property_plant_equipment_schedule / goodwill_and_intangibles（京セラ S100TSIJ、IFRS連結）
    //
    // 実データ検証（2026-08-01）: role=NotesPropertyPlantAndEquipmentConsolidatedFinancialStatementsIFRS /
    // NotesGoodwillAndIntangibleAssetsConsolidatedFinancialStatementsIFRS 配下は「{資産区分}IFRS」
    // （正味帳簿価額）・「{資産区分}AcquisitionCostIFRS」（取得原価）・
    // 「{資産区分}AccumulatedDepreciationAndImpairmentLossesIFRS」等（累計償却/減損）の3点セットで
    // 開示される。正味帳簿価額タグだけを抽出できているかを実データで確認する
    // （取得原価・累計償却タグが誤って混入していないこと）。IFRS連結企業限定（J-GAAP単体の
    // 有形固定資産等明細表 HTML テーブルは Task 7 で未対応と判明・次タスクへ持ち越し）。

    @Test(.enabled(if: cacheAvailable("S100TSIJ"), "XBRL cache S100TSIJ not available"))
    func kyoceraPPEScheduleExtractsNetCarryingAmountsOnly() throws {
        let result = StatementNotesResolver.resolvePropertyPlantEquipmentSchedule(
            xbrlDir: Self.xbrlDir("S100TSIJ"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let items = try #require(payload.items)
        let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0.value) })

        // 実データ検証済みの値（2026-08-01）。
        #expect(byTag["LandIFRS"] != nil)
        #expect(byTag["PropertyPlantAndEquipmentIFRS"] != nil)
        // 取得原価・累計償却/減損タグは正味帳簿価額と別ものなので混入しないこと。
        #expect(!items.contains { $0.tag.hasSuffix("AcquisitionCostIFRS") })
        #expect(!items.contains { $0.tag.hasSuffix("AccumulatedDepreciationAndImpairmentLossesIFRS") })
        #expect(!items.contains { $0.tag.hasSuffix("AccumulatedImpairmentLossesIFRS") })
    }

    @Test(.enabled(if: cacheAvailable("S100TSIJ"), "XBRL cache S100TSIJ not available"))
    func kyoceraGoodwillScheduleExtractsNetCarryingAmountsOnly() throws {
        let result = StatementNotesResolver.resolveGoodwillAndIntangibles(xbrlDir: Self.xbrlDir("S100TSIJ"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let items = try #require(payload.items)
        let tags = Set(items.map(\.tag))

        #expect(tags.contains("GoodwillIFRS"))
        #expect(tags.contains("SoftwareIFRS"))
        #expect(tags.contains("CustomerRelationshipsIFRS"))
        #expect(!items.contains { $0.tag.hasSuffix("AcquisitionCostIFRS") })
        #expect(!items.contains { $0.tag.hasSuffix("AccumulatedAmortizationAndImpairmentLossesIFRS") })
    }

    // MARK: - goodwill_and_intangibles（トヨタ自動車 S100VWVY、この注記自体を持たない）

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaHasNoGoodwillNoteIsNotApplicableNotAFailure() {
        let result = StatementNotesResolver.resolveGoodwillAndIntangibles(xbrlDir: Self.xbrlDir("S100VWVY"))
        guard case .notApplicable(let reason) = result else {
            Issue.record("expected .notApplicable, got \(result)")
            return
        }
        #expect(reason == statementNoteNotApplicableNotFound)
    }

    // MARK: - policy_holding_securities（S100L0TZ、ReportingCompany変体・60銘柄）

    @Test(.enabled(if: cacheAvailable("S100L0TZ"), "XBRL cache S100L0TZ not available"))
    func reportingCompanyVariantExtractsSecuritiesOrderedByDisclosureRow() throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100L0TZ"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let securities = try #require(payload.securities)
        #expect(securities.count == 60)

        // 実データ検証済みの値（2026-08-02）: 開示順(Row1)先頭銘柄。
        let first = try #require(securities.first)
        #expect(first.issuerName == "㈱リクルートホールディングス")
        #expect(first.numberOfShares == 3_550_000)
        #expect(first.carryingAmount == 15_339_000_000)
        // 前期(Prior1YearInstant)の行は混入しない（当期のみ、60件 = Row数と一致）。
    }

    // MARK: - policy_holding_securities（S100VW4E、LargestHoldingCompany変体・保有目的テキストあり）

    @Test(.enabled(if: cacheAvailable("S100VW4E"), "XBRL cache S100VW4E not available"))
    func largestHoldingCompanyVariantExtractsSecuritiesWithPurposeText() throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100VW4E"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let securities = try #require(payload.securities)
        let first = try #require(securities.first)

        // 実データ検証済みの値（2026-08-02）: ReportingCompany 変体とはタグの中間語句が異なる
        // （「事業上の関係の概要」挿入）保有目的タグからも正しくテキストが取れること。
        #expect(first.issuerName == "スズキ㈱")
        #expect(first.numberOfShares == 46_402_892)
        #expect(first.carryingAmount == 83_989_000_000)
        #expect(try #require(first.purpose).contains("保有目的"))
    }

    // MARK: - policy_holding_securities（S100QXRZ、LargestHoldingCompany + SecondLargestHoldingCompany が
    // 同一書類に同時出現するケース）
    //
    // `LargestHoldingCompany` は `SecondLargestHoldingCompany` の末尾一致でもあるため、保有目的タグの
    // variant 判定（`isPolicyHoldingPurposeTag`）で誤って取り違えないことを実データで確認する
    // （生 XBRL の行数: LargestHoldingCompany=19件・SecondLargestHoldingCompany=22件、grep確認済み）。

    @Test(.enabled(if: cacheAvailable("S100QXRZ"), "XBRL cache S100QXRZ not available"))
    func largestAndSecondLargestVariantsCoexistWithoutCrossContamination() throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100QXRZ"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let securities = try #require(payload.securities)

        // 19 + 22 = 41（生XBRLの行数と一致。variant取り違えによる重複・欠落が無いこと）。
        #expect(securities.count == 41)

        // 電源開発株式会社は Largest 側子会社・Second 側子会社の双方が個別に保有しており
        // 正当に2行存在する（実データ確認済み）。variant取り違えで1行に潰れていないこと、かつ
        // 保有株式数が異なる別々の行として残っていることを確認する。
        let denpatsuRows = securities.filter { $0.issuerName == "電源開発株式会社" }
        #expect(denpatsuRows.count == 2)
        #expect(Set(denpatsuRows.map(\.numberOfShares)) == [542_540, 1_993_680])

        // LargestHoldingCompany 変体側の先頭銘柄（実データ検証済み、2026-08-02）。
        let largest = try #require(securities.first { $0.issuerName == "株式会社大和証券グループ本社" })
        #expect(largest.numberOfShares == 41_140_000)
        #expect(largest.carryingAmount == 25_547_000_000)

        // SecondLargestHoldingCompany 変体側の銘柄（実データ検証済み、2026-08-02）。
        // Largest 側で誤って保有目的タグが取られていないこと（取り違えなら purpose が同一文字列に
        // なる、または欠落する）を確認する。
        let second = try #require(securities.first { $0.issuerName == "株式会社ＴＫＣ" })
        #expect(second.numberOfShares == 5_138_092)
        #expect(second.carryingAmount == 18_856_000_000)
        #expect(try #require(second.purpose).contains("中小企業"))
    }

    // MARK: - policy_holding_securities（S100QXRZ、年度中に全数売却した銘柄の当年値は nil）
    //
    // 実データ検証（2026-08-02、ユーザーからの実データ確認依頼で発見）: 当年に全数売却済みの銘柄は
    // 当年 fact が `xsi:nil="true"`（または当年 fact 自体が存在しない）で、前年 fact のみが残る。
    // `collectAllNumericFacts` の既定 `nilAsZero: true` で値を読むと、この `xsi:nil` が誤って `0`
    // （保有株式数0・計上額0円）に化けてしまい、「保有目的は説明されているのに0株保有」という
    // 矛盾した値を返す不具合があった（41銘柄中14銘柄で発生）。`collectAllNumericElements(nilAsZero:
    // false)` を使うことで、未開示（nil）のまま返るように修正した。

    @Test(.enabled(if: cacheAvailable("S100QXRZ"), "XBRL cache S100QXRZ not available"))
    func divestedSecurityDuringTheYearReportsNilNotZero() throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100QXRZ"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let securities = try #require(payload.securities)

        // 当年 fact が xsi:nil="true"（前年 fact は 998,820株・53.74億円で実在。実データ確認済み）。
        let sompo = try #require(securities.first { $0.issuerName == "ＳＯＭＰＯホールディングス株式会社" })
        #expect(sompo.numberOfShares == nil)
        #expect(sompo.carryingAmount == nil)
        #expect(sompo.purpose != nil)  // 保有目的テキスト自体は残っている

        // 当年 fact 自体が存在しない（前年 fact のみ）ケースも同様に nil。
        let strike = try #require(securities.first { $0.issuerName == "株式会社ストライク" })
        #expect(strike.numberOfShares == nil)
        #expect(strike.carryingAmount == nil)
    }

    // MARK: - policy_holding_securities（S100R218、個別銘柄非開示・集計のみ、正当な not_applicable）

    @Test(.enabled(if: cacheAvailable("S100R218"), "XBRL cache S100R218 not available"))
    func aggregateOnlyDisclosureWithoutNamedSecuritiesIsNotApplicableNotAFailure() {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100R218"))
        guard case .notApplicable(let reason) = result else {
            Issue.record("expected .notApplicable, got \(result)")
            return
        }
        #expect(reason == statementNoteNotApplicableNotFound)
    }

    // MARK: - policy_holding_securities golden（全銘柄リスト、ユーザー実データ確認済み 2026-08-02）
    //
    // 年度中に保有株式を全数売却した銘柄（当年の保有株式数・計上額が nil になる）を含む4社について、
    // 開示順（保有額の大きい順）での全銘柄・全値をユーザーが目視確認した結果を golden として固定する
    // （`.agents/rules/generic/workflow.md` のテスト方針: 実データ検証→golden記録。
    // memory `feedback_practicality_validation_methodology` と同型の運用）。
    // 件数・順序・値のいずれかが変わればこのテストが検知する（resolver の将来的な変更に対する
    // 回帰ガード）。

    /// golden 全銘柄リスト（銘柄名・保有株式数・貸借対照表計上額、開示順）を完全一致で検証する。
    private static func assertGoldenSecurities(
        _ securities: [PolicyHoldingSecurityPayload], golden: [(name: String, shares: Double?, carrying: Double?)]
    ) {
        #expect(securities.count == golden.count)
        for (i, expected) in golden.enumerated() {
            guard i < securities.count else { continue }
            let actual = securities[i]
            if actual.issuerName != expected.name || actual.numberOfShares != expected.shares
                || actual.carryingAmount != expected.carrying
            {
                Issue.record(
                    """
                    row \(i): expected (\(expected.name), \(String(describing: expected.shares)), \
                    \(String(describing: expected.carrying))), got (\(actual.issuerName), \
                    \(String(describing: actual.numberOfShares)), \(String(describing: actual.carryingAmount)))
                    """)
            }
        }
    }

    @Test(.enabled(if: cacheAvailable("S100QXRZ"), "XBRL cache S100QXRZ not available"))
    func goldenSecuritiesTAndDHoldings() throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100QXRZ"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let securities = try #require(payload.securities)
        Self.assertGoldenSecurities(
            securities,
            golden: [
                ("株式会社大和証券グループ本社", 41_140_000.0, 25_547_000_000.0),
                ("株式会社椿本チエイン", 3_559_663.0, 11_444_000_000.0),
                ("三菱地所株式会社", 3_850_000.0, 6_069_000_000.0),
                ("ライト工業株式会社", 2_734_500.0, 5_335_000_000.0),
                ("椿本興業株式会社", 573_805.0, 2_372_000_000.0),
                ("株式会社大気社", 422_029.0, 1_553_000_000.0),
                ("電源開発株式会社", 542_540.0, 1_156_000_000.0),
                ("大和自動車交通株式会社", 375_000.0, 308_000_000.0),
                ("盟和産業株式会社", 210_120.0, 206_000_000.0),
                ("ＳＯＭＰＯホールディングス株式会社", nil, nil),
                ("相鉄ホールディングス株式会社", nil, nil),
                ("三井物産株式会社", nil, nil),
                ("株式会社島津製作所", nil, nil),
                ("京王電鉄株式会社", nil, nil),
                ("三井不動産株式会社", nil, nil),
                ("東急株式会社", nil, nil),
                ("株式会社大林組", nil, nil),
                ("株式会社栗本鐵工所", nil, nil),
                ("高砂熱学工業株式会社", nil, nil),
                ("株式会社ＴＫＣ", 5_138_092.0, 18_856_000_000.0),
                ("NuernbergerBeteiligungs-Aktiengesellschaft", 1_727_036.0, 18_748_000_000.0),
                ("株式会社りそなホールディングス", 28_590_000.0, 18_283_000_000.0),
                ("小野薬品工業株式会社", 6_549_500.0, 18_102_000_000.0),
                ("大和ハウス工業株式会社", 5_000_000.0, 15_570_000_000.0),
                ("江崎グリコ株式会社", 3_500_400.0, 11_673_000_000.0),
                ("株式会社ＦＵＪＩ", 3_342_000.0, 7_466_000_000.0),
                ("関西電力株式会社", 3_656_550.0, 4_720_000_000.0),
                ("電源開発株式会社", 1_993_680.0, 4_248_000_000.0),
                ("株式会社岡三証券グループ", 8_660_000.0, 4_078_000_000.0),
                ("三菱鉛筆株式会社", 2_344_000.0, 3_811_000_000.0),
                ("積水ハウス株式会社", 1_400_000.0, 3_777_000_000.0),
                ("株式会社しずおかフィナンシャルグループ", 3_824_000.0, 3_636_000_000.0),
                ("コニカミノルタ株式会社", 4_520_518.0, 2_572_000_000.0),
                ("株式会社バリューＨＲ", 1_505_600.0, 2_378_000_000.0),
                ("月島機械株式会社", 2_115_700.0, 2_301_000_000.0),
                ("京阪ホールディングス株式会社", 633_800.0, 2_189_000_000.0),
                ("株式会社ストライク", nil, nil),
                ("株式会社三菱ＵＦＪフィナンシャル・グループ", nil, nil),
                ("ＳＭＣ株式会社", nil, nil),
                ("関西ペイント株式会社", nil, nil),
                ("三井不動産株式会社", nil, nil),
            ])
    }

    @Test(.enabled(if: cacheAvailable("S100VW4E"), "XBRL cache S100VW4E not available"))
    func goldenSecuritiesShizuokaFinancialGroup() throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100VW4E"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let securities = try #require(payload.securities)
        Self.assertGoldenSecurities(
            securities,
            golden: [
                ("スズキ㈱", 46_402_892.0, 83_989_000_000.0),
                ("第一三共㈱", 22_422_790.0, 78_726_000_000.0),
                ("㈱フジクラ", 5_788_725.0, 31_247_000_000.0),
                ("ヤマハ㈱", 22_576_365.0, 26_109_000_000.0),
                ("ヤマハ発動機㈱", 16_948_524.0, 20_202_000_000.0),
                ("トヨタ自動車㈱", 6_603_990.0, 17_276_000_000.0),
                ("東海旅客鉄道㈱", 5_019_500.0, 14_325_000_000.0),
                ("ダイキン工業㈱", 500_000.0, 8_070_000_000.0),
                ("㈱ニコン", 4_996_112.0, 7_404_000_000.0),
                ("三菱地所㈱", 2_754_109.0, 6_697_000_000.0),
                ("大和ハウス工業㈱", 1_104_708.0, 5_455_000_000.0),
                ("㈱セブン＆アイ・ホールディングス", 2_392_923.0, 5_175_000_000.0),
                ("㈱マネーフォワード", 1_188_240.0, 4_758_000_000.0),
                ("小田急電鉄㈱", 2_802_711.0, 4_142_000_000.0),
                ("㈱ＴＯＫＡＩホールディングス", 4_065_527.0, 3_996_000_000.0),
                ("㈱Ｔ＆Ｄホールディングス", 1_204_000.0, 3_821_000_000.0),
                ("ＤＯＷＡホールディングス㈱", 747_383.0, 3_459_000_000.0),
                ("浜松ホトニクス㈱", 2_150_400.0, 3_132_000_000.0),
                ("静岡ガス㈱", 2_682_215.0, 3_033_000_000.0),
                ("㈱島津製作所", 804_988.0, 3_002_000_000.0),
                ("明治ホールディングス㈱", 860_444.0, 2_796_000_000.0),
                ("横浜ゴム㈱", 802_867.0, 2_763_000_000.0),
                ("日清食品ホールディングス㈱", 900_000.0, 2_747_000_000.0),
                ("㈱村上開明堂", 459_300.0, 2_406_000_000.0),
                ("芝浦機械㈱", 596_080.0, 2_136_000_000.0),
                ("㈱セブン銀行", 7_500_000.0, 2_100_000_000.0),
                ("イオン㈱", 551_958.0, 2_069_000_000.0),
                ("㈱サーラコーポレーション", 2_180_887.0, 1_884_000_000.0),
                ("日本電気硝子㈱", 506_436.0, 1_765_000_000.0),
                ("京浜急行電鉄㈱", 1_117_000.0, 1_690_000_000.0),
                ("㈱ツムラ", 375_000.0, 1_618_000_000.0),
                ("森永乳業㈱", 439_724.0, 1_369_000_000.0),
                ("㈱ハマキョウレックス", 1_056_000.0, 1_359_000_000.0),
                ("積水ハウス㈱", 396_250.0, 1_323_000_000.0),
                ("日機装㈱", 899_732.0, 1_147_000_000.0),
                ("中部電力㈱", 687_075.0, 1_115_000_000.0),
                ("高砂香料工業㈱", 173_000.0, 1_100_000_000.0),
                ("ＫＤＤＩ㈱", 452_000.0, 1_066_000_000.0),
                ("電源開発㈱", 421_080.0, 1_066_000_000.0),
                ("特種東海製紙㈱", 303_925.0, 1_065_000_000.0),
                ("㈱ミダックホールディングス", 507_000.0, 1_049_000_000.0),
                ("ＮＴＮ㈱", 4_309_538.0, 1_045_000_000.0),
                ("アサヒグループホールディングス㈱", 525_000.0, 1_003_000_000.0),
                ("㈱メニコン", 800_000.0, 996_000_000.0),
                ("名港海運㈱", 612_577.0, 967_000_000.0),
                ("レック㈱", 800_000.0, 951_000_000.0),
                ("はごろもフーズ㈱", 291_610.0, 947_000_000.0),
                ("天龍製鋸㈱", 455_100.0, 857_000_000.0),
                ("㈱山梨中央銀行", 382_100.0, 824_000_000.0),
                ("フジ日本㈱", 792_014.0, 822_000_000.0),
                ("㈱小糸製作所", 444_674.0, 817_000_000.0),
                ("㈱ＰＫＳＨＡ Ｔｅｃｈｎｏｌｏｇｙ", 268_500.0, 788_000_000.0),
                ("王子ホールディングス㈱", 1_243_220.0, 779_000_000.0),
                ("㈱メイコー", 98_800.0, 675_000_000.0),
                ("㈱ジーエス・ユアサコーポレーション", 256_250.0, 610_000_000.0),
                ("㈱河合楽器製作所", 204_000.0, 582_000_000.0),
                ("東ソー㈱", 274_303.0, 563_000_000.0),
                ("住友不動産㈱", 100_000.0, 559_000_000.0),
                ("㈱マキヤ", 495_500.0, 520_000_000.0),
                ("エア・ウォーター㈱", 250_000.0, 472_000_000.0),
                ("三菱電機㈱", nil, nil),
                ("東京海上ホールディングス㈱", nil, nil),
                ("住友商事㈱", nil, nil),
                ("スター精密㈱", nil, nil),
                ("日本電気㈱", nil, nil),
                ("清水建設㈱", nil, nil),
                ("㈱スクロール", nil, nil),
                ("㈱クレディセゾン", nil, nil),
            ])
    }

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func goldenSecuritiesToyota() throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100VWVY"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let securities = try #require(payload.securities)
        Self.assertGoldenSecurities(
            securities,
            golden: [
                ("ＫＤＤＩ㈱", 203_294_600.0, 959_347_000_000.0),
                ("ＭＳ＆ＡＤインシュアランスグループホールディングス㈱", 105_551_899.0, 340_405_000_000.0),
                ("日本電信電話㈱", 2_019_385_000.0, 292_205_000_000.0),
                ("㈱三菱ＵＦＪフィナンシャル・グループ", 102_580_000.0, 206_288_000_000.0),
                ("スズキ㈱", 96_000_000.0, 173_760_000_000.0),
                ("GRABHOLDINGS LIMITED", 222_906_079.0, 150_980_000_000.0),
                ("ルネサス エレクトロニクス㈱", 75_015_900.0, 149_094_000_000.0),
                ("HO TAIMOTOR CO.,LTD.", 45_294_234.0, 124_609_000_000.0),
                ("PT ASTRAINTERNATIONAL Tbk", 1_920_000_000.0, 85_962_000_000.0),
                ("いすゞ自動車㈱", 39_000_000.0, 78_644_000_000.0),
                ("Joby Aviation, Inc.", 72_871_831.0, 65_593_000_000.0),
                ("Pony AI Inc.", 42_453_831.0, 55_987_000_000.0),
                ("UBERTECHNOLOGIES,INC.", 5_125_868.0, 55_841_000_000.0),
                ("Aurora Innovation, Inc.", 47_348_178.0, 47_610_000_000.0),
                ("住友金属鉱山㈱", 11_058_000.0, 35_883_000_000.0),
                ("マツダ㈱", 31_928_500.0, 30_083_000_000.0),
                ("ヤマハ発動機㈱", 18_750_000.0, 22_350_000_000.0),
                ("パナソニック ホールディングス㈱", 8_227_800.0, 14_576_000_000.0),
                ("ヤマトホールディングス㈱", 5_748_133.0, 11_275_000_000.0),
                ("INCHCAPE PLC", 6_666_327.0, 8_657_000_000.0),
                ("カヤバ㈱", 2_938_834.0, 8_637_000_000.0),
                ("住友電気工業㈱", 2_420_000.0, 5_968_000_000.0),
                ("㈱ジーエス・ユアサコーポレーション", 2_236_080.0, 5_327_000_000.0),
                ("大同特殊鋼㈱", 4_345_000.0, 5_171_000_000.0),
                ("㈱ゼンリン", 4_272_000.0, 4_533_000_000.0),
                ("㈱三井ハイテック", 4_677_500.0, 3_237_000_000.0),
                ("信越化学工業㈱", 744_000.0, 3_152_000_000.0),
                ("㈱ＰＫＳＨＡＴｅｃｈｎｏｌｏｇｙ", 766_600.0, 2_251_000_000.0),
                ("曙ブレーキ工業㈱", 15_495_175.0, 1_658_000_000.0),
                ("Electreon Wireless Ltd.", 291_911.0, 955_000_000.0),
                ("第一交通産業㈱", 1_078_000.0, 825_000_000.0),
                ("中央可鍛工業㈱", 792_000.0, 371_000_000.0),
                ("㈱御園座", 80_000.0, 136_000_000.0),
                ("ダイナミックマッププラットフォーム㈱", 10_000.0, 15_000_000.0),
                ("㈱三井住友フィナンシャルグループ", nil, nil),
                ("浜松ホトニクス㈱", nil, nil),
                ("東京海上ホールディングス㈱", nil, nil),
                ("東海旅客鉄道㈱", nil, nil),
                ("ＴＯＹＯ ＴＩＲＥ㈱", nil, nil),
                ("セイノーホールディングス㈱", nil, nil),
                ("福山通運㈱", nil, nil),
                ("中日本興業㈱", nil, nil),
                ("Getaround,Inc.", nil, nil),
            ])
    }

    @Test(.enabled(if: cacheAvailable("S100VGBM"), "XBRL cache S100VGBM not available"))
    func goldenSecuritiesBridgestone() throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: Self.xbrlDir("S100VGBM"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let securities = try #require(payload.securities)
        Self.assertGoldenSecurities(
            securities,
            golden: [
                ("トヨタ自動車㈱", 9_799_450.0, 30_829_000_000.0),
                ("TOYO TIRE㈱", 2_500_000.0, 6_114_000_000.0),
                ("大塚ホールディングス㈱", 200_000.0, 1_720_000_000.0),
                ("㈱三井住友フィナンシャルグループ", 421_836.0, 1_588_000_000.0),
                ("㈱イエローハット", 527_076.0, 1_416_000_000.0),
                ("出光興産㈱", 856_000.0, 886_000_000.0),
                ("福山通運㈱", 200_162.0, 741_000_000.0),
                ("富士急行㈱", 244_510.0, 547_000_000.0),
                ("センコーグループホールディングス㈱", 366_888.0, 547_000_000.0),
                ("西日本鉄道㈱", 212_237.0, 481_000_000.0),
                ("㈱オートバックスセブン", 313_632.0, 460_000_000.0),
                ("近鉄グループホールディングス㈱", 124_281.0, 411_000_000.0),
                ("新潟交通㈱", 163_870.0, 341_000_000.0),
                ("三愛オブリ㈱", 153_550.0, 291_000_000.0),
                ("井関農機㈱", 270_970.0, 253_000_000.0),
                ("阪急阪神ホールディングス㈱", 57_983.0, 239_000_000.0),
                ("伊藤忠エネクス㈱", 101_386.0, 166_000_000.0),
                ("広島電鉄㈱", 120_000.0, 76_000_000.0),
                ("東海旅客鉄道㈱", 25_000.0, 74_000_000.0),
                ("三重交通グループホールディングス㈱", 121_536.0, 60_000_000.0),
                ("日新商事㈱", 50_000.0, 44_000_000.0),
                ("大和自動車交通㈱", 42_000.0, 30_000_000.0),
                ("酒井重工業㈱", 11_616.0, 28_000_000.0),
                ("カメイ㈱", 12_100.0, 23_000_000.0),
                ("エア・ウォーター㈱", 10_000.0, 19_000_000.0),
                ("セイノーホールディングス㈱", nil, nil),
                ("山九㈱", nil, nil),
                ("㈱エスライングループ本社", nil, nil),
                ("オリックス㈱", nil, nil),
            ])
    }

    // MARK: - dividends golden（決議単位、ユーザー実データ確認済み 2026-08-02）
    //
    // 「配当の状況」注記（role=DividendPolicy）の `DateOfResolutionDividendsOfSurplus`・
    // `ResolutionDividendsOfSurplus`・`DividendPerShareDividendsOfSurplus`・
    // `TotalAmountOfDividendsDividendsOfSurplus` が `FilingDateInstant_Row{N}Member` で
    // 決議ごとに行番号付けされている。当初 財務取り込み の `dividendSs`（株主資本等変動計算書の
    // 当期変動額）単一値を再公開していたが、実データレビューでこの単一値は「その事業年度の
    // 業績に対応する配当（中間+期末）」ではなく「そのSS計算期間中に純資産を減少させた配当
    // （前期末配当+当期中間配当）」という別概念であり、期末配当の扱いが1期ずれることが
    // レーザーテック S100JRT9 の実データで確認された（`dividendSs`=2,795,516,000円 =
    // 前期末配当(逆算1,397,759,000円)+当期中間配当(1,397,757,000円)、`dividendEvents`合計
    // 3,832,560,000円 = 当期中間配当(1,397,757,000円)+当期末配当(2,434,803,000円)）。
    // 効力発生日・基準日はタグ自体が存在しないため決議日のみを返す。中間/期末の区分ラベルは
    // 決議機関だけでは判別できない会社があるため（デンソー S100QXX3 は両方とも「取締役会決議」）
    // 持たせない。キャッシュ済み144件中138件で解決・6件が正当な not_applicable（無配当企業、
    // 例: メルカリ S100RX8V）。

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func goldenDividendsLaserTec() throws {
        let result = StatementNotesResolver.resolveDividends(xbrlDir: Self.xbrlDir("S100JRT9"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let events = try #require(payload.dividendEvents)
        #expect(events.count == 2)
        #expect(events[0].resolutionDate == "2020-02-03")
        #expect(events[0].resolutionBody == "取締役会決議")
        #expect(events[0].dividendPerShare == 31.0)
        #expect(events[0].totalAmount == 1_397_757_000.0)
        #expect(events[1].resolutionDate == "2020-09-28")
        #expect(events[1].resolutionBody == "定時株主総会決議")
        #expect(events[1].dividendPerShare == 27.0)
        #expect(events[1].totalAmount == 2_434_803_000.0)
    }

    @Test(.enabled(if: cacheAvailable("S100R24O"), "XBRL cache S100R24O not available"))
    func goldenDividendsAozoraBankQuarterly() throws {
        // 四半期配当（決議4件）。全件が同一事業年度(2022-04-01..2023-03-31)に属することを
        // ユーザーと突き合わせ確認済み（決議日はいずれも事業年度内〜株主総会直後まで）。
        let result = StatementNotesResolver.resolveDividends(xbrlDir: Self.xbrlDir("S100R24O"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let events = try #require(payload.dividendEvents)
        #expect(events.count == 4)
        #expect(events.map(\.resolutionDate) == ["2022-08-01", "2022-11-11", "2023-02-03", "2023-05-17"])
        #expect(events.map(\.dividendPerShare) == [38.0, 38.0, 38.0, 40.0])
        #expect(events.map(\.totalAmount) == [4_437_000_000.0, 4_437_000_000.0, 4_437_000_000.0, 4_671_000_000.0])
    }

    @Test(.enabled(if: cacheAvailable("S100RX8V"), "XBRL cache S100RX8V not available"))
    func companyWithoutDividendsIsNotApplicableNotAFailure() {
        // メルカリ: 配当政策の注記(DividendPolicyTextBlock)自体はあるが無配当のため
        // 決議単位の構造化タグ(Row{N}Member)は存在しない。
        let result = StatementNotesResolver.resolveDividends(xbrlDir: Self.xbrlDir("S100RX8V"))
        guard case .notApplicable(let reason) = result else {
            Issue.record("expected .notApplicable, got \(result)")
            return
        }
        #expect(reason == statementNoteNotApplicableNotFound)
    }

    // MARK: - per_share_information golden（ユーザー実データ確認済み 2026-08-02）
    //
    // EPS・潜在株式調整後EPS・BPSはいずれも「業績等の概要（SummaryOfBusinessResults）」の離散数値
    // タグから決定論で取得する（注記本体のHTMLテーブルはパースしない）。BPSはJGAAPが
    // `NetAssetsPerShareSummaryOfBusinessResults`、IFRSは`EquityToAssetRatioIFRSSummaryOfBusinessResults`
    // （タグ名は「自己資本比率」の意味だが誤り。`unitRef=JPYPerShares`の場合のみ実体は
    // 「１株当たり親会社株主持分」。日立 S100QZT0の実データでHTML本文ラベルと完全一致を確認済み。
    // US-GAAP企業では同名タグが真の比率(`unitRef=pure`)として使われるため`unitRef`を見ずタグ名だけ
    // で判定してはならない、小松製作所 S100QYNI で確認済み）。カバレッジ実測（144件）:
    // EPS 144/144、BPS 142/144、潜在株式調整後EPS 88/144。
    //
    // IFRS企業のEPS/潜在株式調整後EPSはStatement取り込み（Statement、損益計算書）とタグ・値が完全一致する
    // （`jpigp_cor:BasicEarningsLossPerShareIFRS`はrole=ConsolidatedStatementOfProfitOrLossIFRSで
    // 損益計算書本体のfactそのもの、同じ値がnotesにも出るのは意図的な重複でズレではない、
    // ユーザー確認済み）。BPSはどちらの会計基準でもStatement取り込みでは取得不可（role=BusinessResultsOfGroup
    // でBS/PL/CFいずれにも分類されない）。

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func goldenPerShareLaserTecJGAAP() throws {
        let result = StatementNotesResolver.resolvePerShareInformation(xbrlDir: Self.xbrlDir("S100JRT9"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let byTag = Dictionary(uniqueKeysWithValues: try #require(payload.items).map { ($0.tag, $0.value) })
        #expect(byTag["eps"] == 120.02)
        #expect(byTag["diluted_eps"] == 119.92)
        #expect(byTag["bps"] == 434.19)
    }

    @Test(.enabled(if: cacheAvailable("S100QZT0"), "XBRL cache S100QZT0 not available"))
    func goldenPerShareHitachiIFRS() throws {
        // BPSは誤タグ名(EquityToAssetRatioIFRSSummaryOfBusinessResults)経由。実データのHTML本文
        // ラベル「１株当たり親会社株主持分」と値5,271.97円が完全一致することをユーザーと確認済み。
        let result = StatementNotesResolver.resolvePerShareInformation(xbrlDir: Self.xbrlDir("S100QZT0"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let items = try #require(payload.items)
        let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0.value) })
        #expect(byTag["eps"] == 684.55)
        #expect(byTag["diluted_eps"] == 683.89)
        #expect(byTag["bps"] == 5271.97)
        #expect(items.first { $0.tag == "bps" }?.label == "１株当たり親会社株主持分")
        #expect(items.allSatisfy { $0.unit == "yen_per_share" })
    }

    // MARK: - capital_expenditures_overview golden（ユーザー実データ確認済み 2026-08-02）
    //
    // 単一セグメント企業（レーザーテック）は注記が自由記述の文章のみで、総額タグ
    // （`Xbrl.capexOverviewTags`）1本が唯一の数値源。複数セグメント企業は注記HTML内の
    // セグメント別テーブルをパースする（列数・ヘッダー文言・rowspanの使われ方が会社ごとに揺れる
    // ため `parseCapexTable` は内容ベースの列判定と rowspan 展開グリッドで対応、実装コメント参照）。
    //
    // コニカミノルタは「デジタルワークプレイス事業」「プロフェッショナルプリント事業」が
    // 同じ金額（rowspanで結合された1つのセル）を共有する結合開示で、注記自体が2セグメントを
    // 分けて開示していない。両行が同一investmentAmountを返すのは仕様どおりで、単純合計すると
    // 二重計上になる点はユーザー確認済み（golden化はせず特性として記録するに留める）。

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func goldenCapexLaserTecSingleSegmentFallsBackToTotalTag() throws {
        let result = StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: Self.xbrlDir("S100JRT9"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let segments = try #require(payload.capexSegments)
        #expect(segments.count == 1)
        #expect(segments[0].segmentName == nil)
        #expect(segments[0].investmentAmount == 510_000_000)
    }

    @Test(.enabled(if: cacheAvailable("S100QZT0"), "XBRL cache S100QZT0 not available"))
    func goldenCapexHitachiFourColumnTable() throws {
        let result = StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: Self.xbrlDir("S100QZT0"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let segments = try #require(payload.capexSegments)
        let byName = Dictionary(uniqueKeysWithValues: segments.map { ($0.segmentName ?? "", $0) })
        #expect(byName["デジタルシステム＆サービス"]?.investmentAmount == 64_900_000_000)
        #expect(byName["デジタルシステム＆サービス"]?.yoyPercent == 101)
        #expect(byName["デジタルシステム＆サービス"]?.description == "製品開発、データセンタの維持・更新")
        #expect(byName["日立金属"]?.investmentAmount == 20_100_000_000)
        let total = try #require(segments.first { $0.isTotal })
        #expect(total.investmentAmount == 349_700_000_000)
        #expect(segments.filter { !$0.isTotal }.count == 8)
    }

    @Test(.enabled(if: cacheAvailable("S100QZOM"), "XBRL cache S100QZOM not available"))
    func goldenCapexSoftBankGroupTwoColumnTableWithRowspanLabel() throws {
        // 先頭行に「報告セグメント」を1文字ずつ縦書き表示する rowspan セル（区分見出し）が入る。
        // これを除いた実データ列（セグメント名/金額）が正しく取れることを確認する
        // （実装当初のバグで先頭セグメント「持株会社投資事業」が欠落していた）。
        let result = StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: Self.xbrlDir("S100QZOM"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let segments = try #require(payload.capexSegments)
        let byName = Dictionary(uniqueKeysWithValues: segments.map { ($0.segmentName ?? "", $0) })
        #expect(byName["持株会社投資事業"]?.investmentAmount == 1_032_000_000)
        #expect(byName["ソフトバンク事業"]?.investmentAmount == 761_834_000_000)
        let total = try #require(segments.first { $0.isTotal })
        #expect(total.investmentAmount == 799_130_000_000)
        let sum = segments.filter { !$0.isTotal }.reduce(0.0) { $0 + ($1.investmentAmount ?? 0) }
        #expect(sum == total.investmentAmount)
    }

    @Test(.enabled(if: cacheAvailable("S100QYHM"), "XBRL cache S100QYHM not available"))
    func goldenCapexKobeSteelExcludesSubtotalFromSum() throws {
        // 「報告セグメント計」は他行（鉄鋼アルミ〜電力）の小計であり、isTotal=trueで区別する。
        // 個別セグメント行だけを合計すると合計行にほぼ一致する（実装当初のバグで小計を個別
        // セグメント扱いし二重計上していた）。原本の各行が百万円単位で丸められているため
        // 3,000,000円の残差が出る（実データ確認済み・丸め誤差、許容範囲内）。
        let result = StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: Self.xbrlDir("S100QYHM"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let segments = try #require(payload.capexSegments)
        #expect(segments.filter { $0.isTotal }.count == 2)
        let subtotal = try #require(segments.first { $0.segmentName == "報告セグメント計" })
        #expect(subtotal.investmentAmount == 93_903_000_000)
        let grandTotal = try #require(segments.last { $0.isTotal })
        #expect(grandTotal.investmentAmount == 97_302_000_000)
        let sum = segments.filter { !$0.isTotal }.reduce(0.0) { $0 + ($1.investmentAmount ?? 0) }
        #expect(abs(sum - grandTotal.investmentAmount!) <= 3_000_000)
    }

    // MARK: - issued_shares golden（ユーザー実データ確認済み 2026-08-02）
    //
    // `ChangesInNumberOfIssuedSharesStatedCapitalEtcTextBlock` 内の決議・イベント単位テーブルを
    // 直接抽出する。株数=株/千株、金額=千円/百万円と単位が会社ごとに揺れるため常に「株」「円」の
    // 生値へ正規化する。行の採否は「株数増減／資本金増減／資本準備金増減のいずれか1つでも実数」
    // で判定する（Notes は基本 XBRL からそのまま構造化し、なるべく行を省かない方針）。日立の
    // 「自◯至◯」期間ラベル行（3つの増減欄がすべて「－」の変動なし確認行）だけを除外する。

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func goldenIssuedSharesLaserTecStockSplitsOnly() throws {
        let result = StatementNotesResolver.resolveIssuedShares(xbrlDir: Self.xbrlDir("S100JRT9"))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        #expect(source == statementNoteSourceXbrlFacts)
        let events = try #require(payload.issuedSharesEvents)
        #expect(events.count == 2)
        #expect(events[0].sharesDelta == 23_571_600)
        #expect(events[0].sharesBalance == 47_143_200)
        #expect(events[0].capitalDelta == nil)
        #expect(events[1].sharesDelta == 47_143_200)
        #expect(events[1].sharesBalance == 94_286_400)
    }

    @Test(.enabled(if: cacheAvailable("S100QZT0"), "XBRL cache S100QZT0 not available"))
    func goldenIssuedSharesHitachiExcludesFiscalYearPlaceholderRows() throws {
        // 「自2018年４月１日 至2019年３月31日」等の期間ラベル行（変動なし確認用、増減欄が
        // すべて「－」）を挟むが、実イベント行（単発日付、5件）だけが残ることを確認する。
        // 2022/12/14は自己株式消却（△表記）で資本金・資本準備金の増減欄は「－」のまま。
        let result = StatementNotesResolver.resolveIssuedShares(xbrlDir: Self.xbrlDir("S100QZT0"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let events = try #require(payload.issuedSharesEvents)
        #expect(events.count == 5)
        #expect(events.allSatisfy { !$0.date.contains("自") })
        let retirement = try #require(events.last)
        #expect(retirement.sharesDelta == -30_488_800)
        #expect(retirement.sharesBalance == 938_083_077)
        #expect(retirement.capitalDelta == nil)
        let firstIssuance = events[0]
        #expect(firstIssuance.sharesDelta == 587_800)
        #expect(firstIssuance.capitalDelta == 1_072_000_000)
        #expect(firstIssuance.capitalReserveDelta == 1_072_000_000)
    }

    @Test(.enabled(if: cacheAvailable("S100QZOM"), "XBRL cache S100QZOM not available"))
    func goldenIssuedSharesSoftBankGroupThousandShareUnit() throws {
        // ヘッダーが「（千株）」表記のため、生値の1000倍が正しい株数（消却・分割イベント5件）。
        let result = StatementNotesResolver.resolveIssuedShares(xbrlDir: Self.xbrlDir("S100QZOM"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let events = try #require(payload.issuedSharesEvents)
        #expect(events.count == 5)
        #expect(events[0].sharesDelta == -55_753_000)
        #expect(events[0].sharesBalance == 1_044_907_000)
        #expect(events[1].sharesDelta == 1_044_907_000)
        #expect(events[1].sharesBalance == 2_089_814_000)
        #expect(events.last?.sharesBalance == 1_469_995_000)
    }

    @Test(.enabled(if: cacheAvailable("S100QYHM"), "XBRL cache S100QYHM not available"))
    func goldenIssuedSharesKobeSteelStockExchangeIssuance() throws {
        // 株式交換による新株発行1件のみ。資本金増減欄は「－」だが資本準備金は実額で増加
        // （株式交換型の新株発行が資本準備金側に計上された珍しいケース）。
        let result = StatementNotesResolver.resolveIssuedShares(xbrlDir: Self.xbrlDir("S100QYHM"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let events = try #require(payload.issuedSharesEvents)
        #expect(events.count == 1)
        #expect(events[0].sharesDelta == 31_981_753)
        #expect(events[0].sharesBalance == 396_345_963)
        #expect(events[0].capitalDelta == nil)
        #expect(events[0].capitalReserveDelta == 21_907_000_000)
    }

    @Test(.enabled(if: cacheAvailable("S100VH9B"), "XBRL cache S100VH9B not available"))
    func goldenIssuedSharesJTShareCountUnchangedOnlyCapitalReserveMoved() throws {
        // 会社法448条に基づく資本準備金→その他資本剰余金への振替。株数・資本金は不変
        // （増減欄が「－」）で資本準備金だけ実額で減少する行。株数増減欄だけで採否判定すると
        // この行自体が消えてしまうバグを実データで発見・修正した回帰。
        let result = StatementNotesResolver.resolveIssuedShares(xbrlDir: Self.xbrlDir("S100VH9B"))
        guard case .resolved(let payload, _, _) = result else {
            Issue.record("expected .resolved, got \(result)")
            return
        }
        let events = try #require(payload.issuedSharesEvents)
        #expect(events.count == 1)
        #expect(events[0].sharesDelta == nil)
        #expect(events[0].sharesBalance == 2_000_000_000)
        #expect(events[0].capitalDelta == nil)
        #expect(events[0].capitalReserveDelta == -100_000_000_000)
        #expect(events[0].capitalReserveBalance == 636_400_000_000)
    }
}
