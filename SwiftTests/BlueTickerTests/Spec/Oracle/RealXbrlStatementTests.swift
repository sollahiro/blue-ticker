// 実 EDINET XBRL キャッシュ（analysis_cache）での Statement 取り込み Statement 抽出の golden 回帰テスト。
//
// 対象（2026-07-31 実データ検証で確定した値）:
// - 7203 トヨタ自動車 S100VWVY（IFRS連結、2025-03期）
// - 6902 デンソー S100VWHL（IFRS連結、2025-03期。デンソーは `LiabilitiesIFRS` の直接の親が
//   負債・純資産を束ねる `LiabilitiesAndEquityIFRSAbstract` であり、区分判定バグの回帰対象）
// - 7974 任天堂 S100W73A（J-GAAP連結、2025-03期）
//
// 2026-08-09、smoke（`smoke/smoke_expected/*.json`、SmokeTests.swift）が対象とする固定11社
// セットのうち US-GAAP2社を除く9社**全件**を、statement 側の床として追加（AGENTS.md「テスト」節・
// docs/test-spec-assets.md「既知のギャップ」参照。SmokeTests.swift 自体は Extractors.swift 経由の
// 抽出器のみを検証しており StatementAnalyzer は通らないため、床を広げるにはここへ追加する）。
// 追加した9社は「同一区分内で他行の components からも参照されていない isTotal 行」（＝各区分の
// 最上位合計）を構造的に特定した上で、smoke_expected の既存 golden 値（total_assets/net_assets/
// sales/cfo/cfi）と突合して一致を確認済み（2026-08-09）:
// - 2802 味の素 S100VXJA（IFRS連結、2025-03期）
// - 2871 ニチレイ S100VYA0（J-GAAP連結、2025-03期）
// - 3490 AZplanning S100VU4O（J-GAAP連結、2025-02期、小規模企業）
// - 6103 オークマ S100W043（J-GAAP連結、2025-03期）
// - 6326 クボタ S100XR0M（IFRS連結、2025-12期）
// - 7269 スズキ S100W4MT（IFRS連結、2025-03期）
// - 7422 東邦レマック S100XRD8（J-GAAP連結、2025-12-20期。小規模企業・決算期末が月中）
// - 8306 三菱UFJフィナンシャル・グループ S100W4FB（J-GAAP連結・銀行、2025-03期。流動/非流動の
//   区分を持たない銀行特有のBS構造の回帰対象）
// - 8316 三井住友フィナンシャルグループ S100W0S7（J-GAAP連結・銀行、2025-03期）
// smoke の US-GAAP2社（4901 富士フイルム S100W3XJ、7751 キヤノン S100XTLJ）は下記
// 「US-GAAP（HTML 経路）」で golden 化（0105010 HTML→行。`USGAAPStatementHtml`）。
        // 金額は当期優先・「－」=0、キヤノン型 `components`（合計直後の内訳が親と一致）を含む。
        // 富士フイルムは内訳→合計型のため同規則では `components` なし。
        // 2026-08-22、最新年度で HTML 本表が空/部分欠測だった US-GAAP 4社を追加
        // （野村 S100YC5C、オムロン S100YG81、小松 S100YD25、オリックス S100YG5L）。
        // 野村 SS は連結資本勘定変動表の全行（label / section / value / is_total）を golden 化。
        // オムロンは BS/PL/CF/SS 全行（CF は operating/investing/financing、SS は科目横で section=nil）。
//
// smoke 由来の9社は `ensureAvailable`（`BLT_EDINET_API_KEY` があれば自動取得）で、
// Toyota/Denso/Nintendo 他の既存分は `.enabled(if:)` で自動 SKIP（`swift test` は鍵なしでも緑）。
// ラベルの標準タクソノミ補完（`assets/taxonomy`、git 管理外）が無い環境でもここで検証する
// 数値・区分・is_total/components は独立して成立する（ラベル解決率自体はここでは検証しない）。
//
// 2026-08-09、SS（`changes_in_equity`）も上記9社＋トヨタへ golden を追加（合計列のみ・
// 期首/期末の別 order・連結での stray `ProfitLoss` 非混入。個別のみの東邦レマックは
// `ProfitLoss` を正当な行として残す）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlStatementTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlRoot.appendingPathComponent("\(docID)_xbrl").path)
    }

    /// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、それでも無ければ SKIP する
    /// （`RealXbrlBreakdownTests.swift` と同型。smoke 由来の企業セットで採用し、CI・新規
    /// checkout でもキャッシュ未取得のまま無条件 SKIP にならないようにする）。
    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard cacheAvailable(docID) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func analyzer() -> StatementAnalyzer {
        let cacheDir = defaultUserDataPath().appendingPathComponent("analysis_cache", isDirectory: true)
        return StatementAnalyzer(edinetClient: EdinetAPIClient(cacheDir: cacheDir))
    }

    private static func requireResolved(_ result: StatementDocResolveResult) throws -> StatementYear {
        guard case .resolved(let year) = result else {
            Issue.record("expected .resolved, got \(result)")
            struct ExpectationFailed: Error {}
            throw ExpectationFailed()
        }
        return year
    }

    /// `assets/taxonomy`（EDINET 公式タクソノミ、ユーザーが配置。git 管理外）が無い環境では
    /// 標準タグのラベルは解決できない（`XBRLUtils.loadStandardTaxonomyLabels` 参照）。
    /// ラベル文言に依存するテストはこれで追加ガードし、値・区分・is_total/components の検証
    /// （taxonomy 非依存）とは環境依存性を切り分ける。
    private static var taxonomyAvailable: Bool {
        resolveAssetFileURL(filename: "taxonomy") != nil
    }

    /// SS の期首/期末残高行: 値が一致し、期首 order < 期末 order（開示の読み順）。
    private static func expectOpeningClosing(
        _ items: [StatementLineItem], tag: String, opening: Double, closing: Double
    ) {
        let rows = items.filter { $0.tag == tag }
        #expect(rows.count == 2)
        #expect(rows.map(\.value) == [opening, closing])
        let orders = rows.compactMap(\.order)
        #expect(orders.count == 2)
        #expect(orders[0] < orders[1])
        #expect(items.allSatisfy { $0.order != nil })
    }

    // MARK: - トヨタ自動車 S100VWVY

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaBalanceSheetTotalsMatchPublicFiguresWithCalculationComponents() async throws {
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        // 公表値と一致（2026-07-30 実データ検証済み）。
        #expect(byTag["AssetsIFRS"]?.value == 93_601_350_000_000)
        #expect(byTag["LiabilitiesIFRS"]?.value == 56_722_437_000_000)
        #expect(byTag["EquityIFRS"]?.value == 36_878_913_000_000)

        // 区分（presentation linkbase 祖先由来）。
        #expect(byTag["AssetsIFRS"]?.section == .assets)
        #expect(byTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(byTag["EquityIFRS"]?.section == .netAssets)
        // 複数区分にまたがるグランドトータルは section=nil のまま。
        #expect(byTag["LiabilitiesAndEquityIFRS"]?.section == nil)

        // 合計行の構成要素（計算リンクベース由来）。
        #expect(byTag["AssetsIFRS"]?.isTotal == true)
        #expect(
            Set(byTag["AssetsIFRS"]?.components?.map(\.tag) ?? [])
                == ["CurrentAssetsIFRS", "NonCurrentAssetsIFRS"])
        // section が nil のグランドトータルでも is_total/components は独立して取得できる。
        #expect(byTag["LiabilitiesAndEquityIFRS"]?.isTotal == true)
        #expect(
            Set(byTag["LiabilitiesAndEquityIFRS"]?.components?.map(\.tag) ?? [])
                == ["LiabilitiesIFRS", "EquityIFRS"])
    }

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaIncomeStatementMatchesPublicFigures() async throws {
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.incomeStatement]))
        let byTag = Dictionary(uniqueKeysWithValues: year.incomeStatement.map { ($0.tag, $0) })

        #expect(byTag["TotalNetRevenuesIFRS"]?.value == 48_036_704_000_000)
        #expect(byTag["ProfitLossAttributableToOwnersOfParentIFRS"]?.value == 4_765_086_000_000)
        // 損益計算書には section を付けない（2026-07-30 合意）。
        #expect(byTag["TotalNetRevenuesIFRS"]?.section == nil)
        // financials 組立の sales は本表の収益合計行を採用する。
        let financials = StatementFinancialsResolver.resolve(
            xbrlDir: Self.xbrlRoot.appendingPathComponent("S100VWVY_xbrl"))
        #expect(financials?.sales == 48_036_704_000_000)
        #expect(financials?.salesLabel == "売上収益")
        // 控除項目は weight=-1（例: 売上原価並びに販管費合計 = 売上原価 + 金融費用 + 販管費）。
        #expect(byTag["OperatingProfitLossIFRS"]?.isTotal == true)
    }

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaCashFlowIncludesDistinctPeriodStartAndEndCashReconciliation() async throws {
        // 回帰テスト: CF の Instant/Duration 混在バグ修正（現金及び現金同等物の期首/期末残高が
        // 一時期 CF から欠落していた）と、期首/期末で異なる preferredLabel バリアントを
        // 選び直すロジックの両方を検証する。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.cashFlow]))
        let cashRows = year.cashFlow.filter { $0.tag == "CashAndCashEquivalentsIFRS" }

        #expect(cashRows.count == 2)
        #expect(Set(cashRows.map(\.value)) == [8_982_404_000_000, 9_412_060_000_000])
        // 期首（PriorInstant）→期末（Instant）の順（同一 order のタイブレーク）。
        #expect(cashRows.map(\.value) == [9_412_060_000_000, 8_982_404_000_000])
        // 期首・期末で異なるラベルが選ばれ、同じラベルに収束していない。
        #expect(Set(cashRows.compactMap(\.label)).count == 2)

        // 回帰テスト: 出力順が実行のたびに入れ替わらないこと（Opus 監査で発見・修正、
        // 2026-07-31。期首/期末残高は同一タグ・同一 order のため、fact の contextRef を
        // 決定的なタイブレークキーに使う前は入力の走査順に依存していた）。
        let secondRun = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.cashFlow]))
        let secondCashRows = secondRun.cashFlow.filter { $0.tag == "CashAndCashEquivalentsIFRS" }
        #expect(cashRows.map(\.value) == secondCashRows.map(\.value))
    }

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaChangesInEquityTotalsMatchPublicFiguresWithOpeningClosingBalances() async throws {
        // 持分変動計算書（SS）: 合計列のみ。自己株式の取得・包括利益・資本の期首/期末残高。
        // 実データ検証: トヨタ7203 S100VWVY（2026-08-09）。期首 order < 期末 order。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.changesInEquity]))
        #expect(!year.changesInEquity.isEmpty)
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "EquityIFRS",
            opening: 35_239_338_000_000, closing: 36_878_913_000_000)

        #expect(
            year.changesInEquity.contains {
                $0.tag == "PurchaseOfTreasurySharesSSIFRS" && $0.value == -1_179_043_000_000
            })
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ComprehensiveIncomeIFRS" && $0.value == 4_043_724_000_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })

        let second = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.changesInEquity]))
        #expect(year.changesInEquity.map(\.value) == second.changesInEquity.map(\.value))
        #expect(year.changesInEquity.map(\.tag) == second.changesInEquity.map(\.tag))
        #expect(year.changesInEquity.map(\.order) == second.changesInEquity.map(\.order))
    }

    @Test(
        .enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"),
        .enabled(if: taxonomyAvailable, "assets/taxonomy not available")
    )
    func toyotaBalanceSheetTotalRowsUseTotalLabelNotPeriodEndLabel() async throws {
        // 回帰テスト（Opus 監査で発見・修正、2026-07-31）: BS の合計行が標準タクソノミの
        // periodEndLabel を持つ場合（`EquityIFRS` 等）、期首/期末残高の区別ロジックが CF に
        // 限定されていなかったため `preferredLabel=totalLabel`（「資本合計」）が無視され
        // 常に「期末残高」になっていた（キャッシュ済み実XBRL 140件中136件で発生）。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(byTag["EquityIFRS"]?.label == "資本合計")
        #expect(byTag["EquityIFRS"]?.label?.contains("残高") == false)
    }

    // MARK: - デンソー S100VWHL

    @Test(.enabled(if: cacheAvailable("S100VWHL"), "XBRL cache S100VWHL not available"))
    func densoLiabilitiesTotalIsClassifiedAsLiabilitiesDespiteAmbiguousParentHeader() async throws {
        // 回帰テスト: `LiabilitiesIFRS` の直接の親 `LiabilitiesAndEquityIFRSAbstract` は
        // 負債・純資産両方のキーワードに一致し曖昧なため、優先順位だけで確定させると
        // 誤って純資産に分類されていた（2026-07-30 発見・修正）。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWHL", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(byTag["LiabilitiesIFRS"]?.value == 2_936_082_000_000)
        #expect(byTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(byTag["AssetsIFRS"]?.value == 8_125_000_000_000)

        // 回帰テスト: 上記修正の副作用として、無関係な部分文字列（"EquityMethod" の "Equity"、
        // "AssetsHeldForSale" の "Asset"）を含む明細タグが誤分類されないことも確認する。
        #expect(byTag["InvestmentsAccountedForUsingEquityMethodIFRS"]?.section == .assets)
        #expect(byTag["OtherComprehensiveIncomeRelatedToAssetsHeldForSaleIFRS"]?.section == .netAssets)
    }

    @Test(.enabled(if: cacheAvailable("S100VWHL"), "XBRL cache S100VWHL not available"))
    func densoIncomeStatementMatchesPublicFigures() async throws {
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWHL", statementTypes: [.incomeStatement]))
        let byTag = Dictionary(uniqueKeysWithValues: year.incomeStatement.map { ($0.tag, $0) })

        // issue #157 記載値・公表値と一致。
        #expect(byTag["RevenueIFRS"]?.value == 7_161_777_000_000)
        #expect(byTag["ProfitLossAttributableToOwnersOfParentIFRS"]?.value == 419_081_000_000)
    }

    // MARK: - 任天堂 S100W73A

    @Test(.enabled(if: cacheAvailable("S100W73A"), "XBRL cache S100W73A not available"))
    func nintendoBalanceSheetTotalsChainThroughMultipleLevels() async throws {
        // 回帰テスト: 明細→小計→中計→総合計の多段階の積み上げが計算リンクベース経由で
        // 正しく連鎖することを確認する（J-GAAP、IFRS とはタグ体系が異なる）。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W73A", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(byTag["Assets"]?.value == 3_398_515_000_000)
        #expect(Set(byTag["Assets"]?.components?.map(\.tag) ?? []) == ["CurrentAssets", "NoncurrentAssets"])
        #expect(
            Set(byTag["NoncurrentAssets"]?.components?.map(\.tag) ?? [])
                == ["PropertyPlantAndEquipment", "IntangibleAssets", "InvestmentsAndOtherAssets"])

        // 複数区分にまたがるグランドトータルも is_total/components は独立して取得できる。
        #expect(byTag["LiabilitiesAndNetAssets"]?.section == nil)
        #expect(byTag["LiabilitiesAndNetAssets"]?.isTotal == true)
        #expect(
            Set(byTag["LiabilitiesAndNetAssets"]?.components?.map(\.tag) ?? [])
                == ["Liabilities", "NetAssets"])
    }

    @Test(
        .enabled(if: cacheAvailable("S100W73A"), "XBRL cache S100W73A not available"),
        .enabled(if: taxonomyAvailable, "assets/taxonomy not available")
    )
    func nintendoValuationAndTranslationAdjustmentsUsesTotalLabelVariant() async throws {
        // 回帰テスト: `preferredLabel=totalLabel` により通常ラベル「評価・換算差額等」ではなく
        // 合計ラベル（「…合計」）を使うべきケース。標準タグのラベル解決は `assets/taxonomy`
        // （git 管理外）が無い環境では成立しないため、値/区分/is_total とは別テストに分離する。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W73A", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })
        #expect(byTag["ValuationAndTranslationAdjustments"]?.label?.contains("合計") == true)
    }

    @Test(.enabled(if: cacheAvailable("S100W73A"), "XBRL cache S100W73A not available"))
    func nintendoIncomeStatementMatchesPublicFigures() async throws {
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W73A", statementTypes: [.incomeStatement]))
        let byTag = Dictionary(uniqueKeysWithValues: year.incomeStatement.map { ($0.tag, $0) })

        #expect(byTag["NetSales"]?.value == 1_164_922_000_000)
        #expect(byTag["ProfitLossAttributableToOwnersOfParent"]?.value == 278_806_000_000)
    }

    // MARK: - smoke 企業セット（US-GAAP除く7社、床の拡張。2026-08-09）

    /// 同一 section 内で他行の components からも参照されていない isTotal 行 = その区分の
    /// 最上位合計（根）。参照元を同一 section 内に限定するのは、複数区分を跨ぐグランドトータル
    /// （section=nil、例: LiabilitiesAndNetAssets）が Liabilities/NetAssets を参照することで
    /// 区分内の本来の root が誤って「参照済み」判定されるのを防ぐため。
    private static func rootTotal(_ items: [StatementLineItem], section: StatementLineSection) -> StatementLineItem? {
        let inSection = items.filter { $0.section == section }
        let referenced = Set(inSection.compactMap(\.components).flatMap { $0.map(\.tag) })
        let roots = inSection.filter { $0.isTotal && !referenced.contains($0.tag) }
        return roots.count == 1 ? roots.first : nil
    }

    /// 貸借対照表の会計等式（資産=負債+純資産）。上記 `rootTotal` で3行を抽出結果から
    /// 実行時に構造的に特定して検証する（固定タグ名を再掲するだけの重複チェックにしない）。
    /// 開示側の百万円/千円丸めにより厳密には一致しない場合があるため、絶対誤差2,000,000円まで
    /// は許容する（実データ検証: 7社中の最大の乖離は1,000,000円）。
    private static func expectBalanceSheetIdentity(_ balanceSheet: [StatementLineItem]) {
        guard let assets = rootTotal(balanceSheet, section: .assets),
            let liabilities = rootTotal(balanceSheet, section: .liabilities),
            let netAssets = rootTotal(balanceSheet, section: .netAssets)
        else {
            Issue.record("could not structurally locate assets/liabilities/netAssets root totals")
            return
        }
        #expect(abs(assets.value - (liabilities.value + netAssets.value)) <= 2_000_000)
    }

    // MARK: - 味の素 S100VXJA

    @Test
    func ajinomotoStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100VXJA") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100VXJA", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["AssetsIFRS"]?.value == 1_721_131_000_000)
        #expect(bsByTag["LiabilitiesIFRS"]?.value == 907_858_000_000)
        #expect(bsByTag["EquityIFRS"]?.value == 813_273_000_000)
        #expect(bsByTag["AssetsIFRS"]?.section == .assets)
        #expect(bsByTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(bsByTag["EquityIFRS"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSalesIFRS" }?.value == 1_530_556_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })?.value == 209_898_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })?.section == .operating)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestingActivitiesIFRS" })?.value == -77_382_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestingActivitiesIFRS" })?.section == .investing)
    }

    // MARK: - ニチレイ S100VYA0

    @Test
    func nichireiStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100VYA0") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100VYA0", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 499_221_000_000)
        #expect(bsByTag["Liabilities"]?.value == 223_255_000_000)
        #expect(bsByTag["NetAssets"]?.value == 275_966_000_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSales" }?.value == 702_080_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == 53_194_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.section == .operating)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -32_403_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.section == .investing)
    }

    // MARK: - AZplanning S100VU4O（小規模企業。純資産合計の構成要素が株主資本のみの単純ケース）

    @Test
    func azPlanningStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100VU4O") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100VU4O", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 13_239_919_000)
        #expect(bsByTag["Liabilities"]?.value == 10_281_752_000)
        #expect(bsByTag["NetAssets"]?.value == 2_958_166_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        #expect(Set(bsByTag["NetAssets"]?.components?.map(\.tag) ?? []) == ["ShareholdersEquity"])
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSales" }?.value == 12_430_301_000)

        // 回帰対象: CFO がマイナスの小規模企業ケース。
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == -2_014_514_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.section == .operating)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -68_814_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.section == .investing)
    }

    // MARK: - オークマ S100W043

    @Test
    func okumaStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100W043") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W043", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 298_168_000_000)
        #expect(bsByTag["Liabilities"]?.value == 60_103_000_000)
        #expect(bsByTag["NetAssets"]?.value == 238_065_000_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSales" }?.value == 206_822_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == 17_802_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -15_257_000_000)
    }

    // MARK: - クボタ S100XR0M

    @Test
    func kubotaStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100XR0M") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100XR0M", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["AssetsIFRS"]?.value == 6_204_909_000_000)
        #expect(bsByTag["LiabilitiesIFRS"]?.value == 3_331_885_000_000)
        #expect(bsByTag["EquityIFRS"]?.value == 2_873_024_000_000)
        #expect(bsByTag["AssetsIFRS"]?.section == .assets)
        #expect(bsByTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(bsByTag["EquityIFRS"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSalesIFRS" }?.value == 3_018_891_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })?.value == 327_901_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestingActivitiesIFRS" })?.value == -163_726_000_000)
    }

    // MARK: - スズキ S100W4MT

    @Test
    func suzukiStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100W4MT") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W4MT", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["AssetsIFRS"]?.value == 5_993_657_000_000)
        #expect(bsByTag["LiabilitiesIFRS"]?.value == 2_305_586_000_000)
        #expect(bsByTag["EquityIFRS"]?.value == 3_688_070_000_000)
        #expect(bsByTag["AssetsIFRS"]?.section == .assets)
        #expect(bsByTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(bsByTag["EquityIFRS"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "RevenueIFRS" }?.value == 5_825_161_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })?.value == 669_784_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestingActivitiesIFRS" })?.value == -475_605_000_000)
    }

    // MARK: - 東邦レマック S100XRD8（小規模企業・決算期末が月中）

    @Test
    func tohoRemacStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100XRD8") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100XRD8", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 6_705_070_000)
        #expect(bsByTag["Liabilities"]?.value == 2_183_375_000)
        #expect(bsByTag["NetAssets"]?.value == 4_521_695_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSales" }?.value == 4_547_599_000)

        // 回帰対象: CFO/CFI ともにマイナスの小規模企業ケース。
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == -482_098_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -306_697_000)
    }

    // MARK: - 三菱UFJフィナンシャル・グループ S100W4FB（銀行。流動/非流動の区分を持たないBS構造）

    @Test
    func mufgStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W4FB", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 413_113_501_000_000)
        #expect(bsByTag["Liabilities"]?.value == 391_385_368_000_000)
        #expect(bsByTag["NetAssets"]?.value == 21_728_132_000_000)
        // 回帰対象: 流動/非流動の区分を持たない銀行特有のBS構造でも section 判定が正しいこと。
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        #expect(
            Set(bsByTag["NetAssets"]?.components?.map(\.tag) ?? [])
                == ["ShareholdersEquity", "ValuationAndTranslationAdjustments", "SubscriptionRightsToShares", "NonControllingInterests"])
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        // 銀行は「売上高」の代わりに経常収益（OrdinaryIncomeBNK）が損益計算書内で最大値の行になる。
        #expect(year.incomeStatement.first { $0.tag == "OrdinaryIncomeBNK" }?.value == 13_629_997_000_000)
        #expect(year.incomeStatement.first { $0.tag == "OrdinaryIncomeBNK" }?.isTotal == true)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == 6_415_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -186_948_000_000)
    }

    // MARK: - 三井住友フィナンシャルグループ S100W0S7（銀行）

    @Test
    func smfgStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100W0S7") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W0S7", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 306_282_015_000_000)
        #expect(bsByTag["Liabilities"]?.value == 291_440_506_000_000)
        #expect(bsByTag["NetAssets"]?.value == 14_841_509_000_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        #expect(
            Set(bsByTag["NetAssets"]?.components?.map(\.tag) ?? [])
                == ["ShareholdersEquity", "ValuationAndTranslationAdjustments", "SubscriptionRightsToShares", "NonControllingInterests"])
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "OrdinaryIncomeBNK" }?.value == 10_174_894_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == 4_848_464_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -4_512_943_000_000)
    }

    // MARK: - smoke 9社 SS（changes_in_equity）golden
    //
    // 実データ検証: 2026-08-09。合計列のみ・期首/期末の別 order・連結での stray ProfitLoss 非混入。

    @Test
    func ajinomotoChangesInEquityMatchesSmokeTotalsWithOpeningClosingOrder() async throws {
        guard await Self.ensureAvailable("S100VXJA") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VXJA", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "EquityIFRS",
            opening: 884_448_000_000, closing: 813_273_000_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ComprehensiveIncomeIFRS" && $0.value == 72_537_000_000
            })
        #expect(
            year.changesInEquity.contains {
                $0.tag == "PurchaseOfTreasurySharesSSIFRS" && $0.value == -90_695_000_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })
    }

    @Test
    func nichireiChangesInEquityMatchesSmokeTotalsAndExcludesStrayProfitLoss() async throws {
        guard await Self.ensureAvailable("S100VYA0") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VYA0", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "NetAssets",
            opening: 265_942_000_000, closing: 275_966_000_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ProfitLossAttributableToOwnersOfParent" && $0.value == 24_731_000_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })
    }

    @Test
    func azPlanningChangesInEquityMatchesSmokeTotalsAndExcludesStrayProfitLoss() async throws {
        guard await Self.ensureAvailable("S100VU4O") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VU4O", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "NetAssets",
            opening: 2_495_050_000, closing: 2_958_166_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ProfitLossAttributableToOwnersOfParent" && $0.value == 461_965_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })
    }

    @Test
    func okumaChangesInEquityMatchesSmokeTotalsAndExcludesStrayProfitLoss() async throws {
        guard await Self.ensureAvailable("S100W043") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W043", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "NetAssets",
            opening: 237_846_000_000, closing: 238_065_000_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ProfitLossAttributableToOwnersOfParent" && $0.value == 9_590_000_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })
    }

    @Test
    func kubotaChangesInEquityMatchesSmokeTotalsWithOpeningClosingOrder() async throws {
        guard await Self.ensureAvailable("S100XR0M") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100XR0M", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "EquityIFRS",
            opening: 2_739_766_000_000, closing: 2_873_024_000_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ComprehensiveIncomeIFRS" && $0.value == 252_670_000_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })
    }

    @Test
    func suzukiChangesInEquityMatchesSmokeTotalsWithOpeningClosingOrder() async throws {
        guard await Self.ensureAvailable("S100W4MT") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W4MT", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "EquityIFRS",
            opening: 3_384_427_000_000, closing: 3_688_070_000_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ComprehensiveIncomeIFRS" && $0.value == 416_753_000_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })
    }

    @Test
    func tohoRemacChangesInEquityKeepsNonConsolidatedProfitLossRow() async throws {
        // 東邦レマックは個別SSのため `ProfitLoss`（当期純利益）が正当な行。
        guard await Self.ensureAvailable("S100XRD8") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100XRD8", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "NetAssets",
            opening: 4_669_512_000, closing: 4_521_695_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ProfitLoss" && $0.value == 17_478_000
            })
    }

    @Test
    func mufgChangesInEquityMatchesSmokeTotalsAndExcludesStrayProfitLoss() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W4FB", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "NetAssets",
            opening: 20_746_978_000_000, closing: 21_728_132_000_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ProfitLossAttributableToOwnersOfParent" && $0.value == 1_862_946_000_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })
    }

    @Test
    func smfgChangesInEquityMatchesSmokeTotalsAndExcludesStrayProfitLoss() async throws {
        guard await Self.ensureAvailable("S100W0S7") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W0S7", statementTypes: [.changesInEquity]))
        Self.expectOpeningClosing(
            year.changesInEquity, tag: "NetAssets",
            opening: 14_799_967_000_000, closing: 14_841_509_000_000)
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ProfitLossAttributableToOwnersOfParent" && $0.value == 1_177_996_000_000
            })
        #expect(!year.changesInEquity.contains { $0.tag == "ProfitLoss" })
    }

    // MARK: - US-GAAP（HTML 経路。富士フイルム S100W3XJ は 2026-08-22 目視済み）

    private static func labelValue(
        _ items: [StatementLineItem], containing: String
    ) -> Double? {
        items.first { ($0.label ?? "").contains(containing) }?.value
    }

    /// 部分一致で「流動資産合計」等が先に当たるのを避けるため、正規化ラベルの完全一致を優先する。
    private static func exactLabelValue(
        _ items: [StatementLineItem], _ label: String
    ) -> Double? {
        items.first { $0.label == label }?.value
    }

    private static func labelValues(
        _ items: [StatementLineItem], containing: String
    ) -> [Double] {
        items.compactMap { item in
            guard (item.label ?? "").contains(containing) else { return nil }
            return item.value
        }
    }

    /// HTML 経路の `order`: 全行非 nil・セクション内で厳密単調増加・0 始まり。
    private static func expectHTMLReadingOrder(_ items: [StatementLineItem]) {
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.order != nil })
        let orders = items.compactMap(\.order)
        #expect(orders.count == items.count)
        #expect(orders.first == 0)
        #expect(zip(orders, orders.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// US-GAAP HTML の golden 行（label / section / 円 / is_total）。
    /// 科目縦 SS は group 名、CF は operating/investing/financing、科目横 SS は nil。
    private struct StatementGoldenRow: Equatable {
        var label: String
        var section: String?
        var value: Double
        var isTotal: Bool
    }

    private static func statementGoldenRows(_ items: [StatementLineItem]) -> [StatementGoldenRow] {
        items.map {
            StatementGoldenRow(
                label: $0.label ?? "", section: $0.section?.rawValue,
                value: $0.value, isTotal: $0.isTotal)
        }
    }

    @Test
    func fujifilmUSGAAPStatementMatchesSmokeTotals() async throws {
        guard await Self.ensureAvailable("S100W3XJ") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W3XJ",
                statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]))

        Self.expectHTMLReadingOrder(year.balanceSheet)
        Self.expectHTMLReadingOrder(year.incomeStatement)
        Self.expectHTMLReadingOrder(year.cashFlow)
        Self.expectHTMLReadingOrder(year.changesInEquity)

        #expect(Self.exactLabelValue(year.balanceSheet, "資産合計") == 5_249_908_000_000)
        #expect(Self.exactLabelValue(year.balanceSheet, "純資産合計") == 3_352_682_000_000)
        #expect(Self.exactLabelValue(year.balanceSheet, "流動資産合計") == 1_581_681_000_000)
        #expect(year.balanceSheet.contains { $0.label == "資産合計" && $0.section == .assets })
        #expect(year.balanceSheet.contains { $0.label == "負債合計" && $0.section == .liabilities })
        #expect(year.balanceSheet.contains { $0.label == "純資産合計" && $0.section == .netAssets })

        #expect(Self.exactLabelValue(year.incomeStatement, "売上高") == 3_195_828_000_000)
        #expect(Self.exactLabelValue(year.incomeStatement, "営業利益") == 330_155_000_000)
        #expect(Self.exactLabelValue(year.incomeStatement, "当社株主帰属当期純利益") == 260_951_000_000)

        #expect(
            Self.exactLabelValue(year.cashFlow, "営業活動によるキャッシュ・フロー")
                == 428_162_000_000)
        #expect(
            Self.exactLabelValue(year.cashFlow, "投資活動によるキャッシュ・フロー")
                == -541_953_000_000)
        #expect(year.cashFlow.contains {
            $0.label == "営業活動によるキャッシュ・フロー" && $0.section == .operating
        })
        // CF 現金: 期首 order < 期末 order（HTML 読み順）
        let cfOpen = year.cashFlow.first { ($0.label ?? "").contains("期首残高") }
        let cfClose = year.cashFlow.first { ($0.label ?? "").contains("期末残高") }
        #expect(cfOpen?.order != nil && cfClose?.order != nil)
        #expect(cfOpen!.order! < cfClose!.order!)

        #expect(!year.changesInEquity.isEmpty)
        #expect(year.changesInEquity.contains { ($0.label ?? "").contains("現在残高") })
        #expect(
            Self.labelValues(year.changesInEquity, containing: "2025年３月31日")
                .contains(3_352_682_000_000))
        // SS: 当期期首（2024年３月31日）order < 当期期末（2025年３月31日）
        let ssOpen = year.changesInEquity.first { ($0.label ?? "").contains("2024年３月31日") }
        let ssClose = year.changesInEquity.first { ($0.label ?? "").contains("2025年３月31日") }
        #expect(ssOpen?.order != nil && ssClose?.order != nil)
        #expect(ssOpen!.order! < ssClose!.order!)
        // SS 合計列に当社株主配当が載る（△72,289）。financials は符号反転して正のキャッシュアウト。
        #expect(
            Self.labelValues(year.changesInEquity, containing: "当社株主への")
                .contains(-72_289_000_000))

        // 2026-08-10 レビュー指摘: 入れ子行は当該科目（左）を取り、親小計（右）を取らない。
        // 前期のみの値や SS 合計列の「－」も当期に持ち込まない。足し算だけの空番号親は行にしない。
        #expect(
            year.balanceSheet.contains {
                $0.label == "信用損失引当金" && $0.value == -15_841_000_000
            })
        #expect(Self.exactLabelValue(year.balanceSheet, "関連会社等に対する債務") == 1_672_000_000)
        #expect(!year.balanceSheet.contains { $0.label == "受取債権" })
        #expect(!year.balanceSheet.contains { $0.label == "支払債務" })
        #expect(
            year.balanceSheet.contains { $0.label == "営業債権" && $0.value == 680_635_000_000 })
        #expect(Self.exactLabelValue(year.incomeStatement, "研究開発費") == 163_399_000_000)
        #expect(Self.exactLabelValue(year.incomeStatement, "その他損益・純額") == 12_827_000_000)
        // 法人税等の合計行は無く、当期税＋繰延が親合計（77,595）になる（入れ子右セルは行値にしない）。
        #expect(Self.exactLabelValue(year.incomeStatement, "法人税・住民税及び事業税") == 81_809_000_000)
        #expect(Self.exactLabelValue(year.incomeStatement, "法人税等調整額") == -4_214_000_000)
        #expect(
            year.cashFlow.contains { $0.label == "その他" && $0.value == -21_377_000_000 })
        #expect(
            Self.labelValue(year.cashFlow, containing: "関連会社投融資") == -42_000_000)
        #expect(Self.labelValue(year.cashFlow, containing: "事業の売却") == 0)
        // 2026-08-10 監査指摘: 「現金及び現金同等物」を含む投資区分の明細行が誤って
        // section=nil（期首/期末残高等の tail 扱い）にならないことを実データで固定する。
        #expect(Self.labelValue(year.cashFlow, containing: "事業の買収") == -3_873_000_000)
        #expect(
            year.cashFlow.contains {
                ($0.label ?? "").contains("事業の買収") && $0.section == .investing
            })
        #expect(
            year.cashFlow.contains {
                ($0.label ?? "").contains("事業の売却") && $0.section == .investing
            })
        // 2026-08-10 監査指摘: 空セル+「注」セルの2連続を剥がして正しい当期値を回復できる
        // ことを実データで固定する（前は行ごと消失していた）。
        #expect(
            Self.labelValue(year.balanceSheet, containing: "短期オペレーティング・リース負債")
                == 31_582_000_000)
        // 「Ⅸ 利益剰余金から...」は前期(2023/4→2024/3)分の行のため、SS年度分離修正
        // （2026-08-10）後は year.changesInEquity（当期のみ）に含まれない。
        #expect(
            Self.labelValue(year.changesInEquity, containing: "資本剰余金から") == 0)

        // 富士フイルムは内訳→合計型。キヤノン型 components も空番号親の復元も無い。
        #expect(year.balanceSheet.allSatisfy { $0.components == nil })
        #expect(year.incomeStatement.allSatisfy { $0.components == nil })
        #expect(year.cashFlow.allSatisfy { $0.components == nil })
    }

    @Test
    func canonUSGAAPStatementMatchesSmokeTotals() async throws {
        guard await Self.ensureAvailable("S100XTLJ") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100XTLJ",
                statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]))

        Self.expectHTMLReadingOrder(year.balanceSheet)
        Self.expectHTMLReadingOrder(year.incomeStatement)
        Self.expectHTMLReadingOrder(year.cashFlow)
        Self.expectHTMLReadingOrder(year.changesInEquity)

        #expect(Self.exactLabelValue(year.balanceSheet, "資産合計") == 6_135_044_000_000)
        #expect(Self.exactLabelValue(year.balanceSheet, "純資産合計") == 3_774_128_000_000)
        #expect(year.balanceSheet.contains { $0.label == "資産合計" && $0.section == .assets })
        #expect(year.balanceSheet.contains { $0.label == "負債合計" && $0.section == .liabilities })
        #expect(year.balanceSheet.contains { $0.label == "純資産合計" && $0.section == .netAssets })

        // キヤノン PL は製品/サービス内訳のあと「合計」が売上高。営業利益は一意。
        #expect(Self.exactLabelValue(year.incomeStatement, "営業利益") == 455_390_000_000)
        #expect(
            Self.labelValue(year.incomeStatement, containing: "当社株主に帰属する")
                == 332_053_000_000)
        // 当期「-」→ 0（前期 165,100 百万円を拾わない）
        #expect(Self.exactLabelValue(year.incomeStatement, "のれんの減損損失") == 0)
        // 2026-08-10 監査指摘: EPS 行（実データ確認: 367.48円/367.25円）が円建てのまま
        // （百万円換算されず）unit=JPYPerShares・isTotal=false で出ることを実データで固定する。
        #expect(
            year.incomeStatement.contains {
                $0.label == "基本的" && $0.value == 367.48 && $0.unit == "JPYPerShares"
                    && $0.isTotal == false
            })
        #expect(
            year.incomeStatement.contains {
                $0.label == "希薄化後" && $0.value == 367.25 && $0.unit == "JPYPerShares"
                    && $0.isTotal == false
            })

        #expect(
            Self.exactLabelValue(year.cashFlow, "営業活動によるキャッシュ・フロー")
                == 475_903_000_000)
        #expect(
            Self.exactLabelValue(year.cashFlow, "投資活動によるキャッシュ・フロー")
                == -237_450_000_000)
        #expect(Self.exactLabelValue(year.cashFlow, "のれんの減損損失") == 0)
        let cfOpen = year.cashFlow.first { ($0.label ?? "").contains("期首残高") }
        let cfClose = year.cashFlow.first { ($0.label ?? "").contains("期末残高") }
        #expect(cfOpen?.order != nil && cfClose?.order != nil)
        #expect(cfOpen!.order! < cfClose!.order!)

        #expect(!year.changesInEquity.isEmpty)
        let closings = Self.labelValues(year.changesInEquity, containing: "2025年12月31日現在残高")
        #expect(closings.contains(3_774_128_000_000))
        // 純資産合計列は「-」→ 0（内訳の △494 を合計として拾わない）
        #expect(Self.exactLabelValue(year.changesInEquity, "利益準備金への振替") == 0)
        let ssOpen = year.changesInEquity.first { ($0.label ?? "").contains("2024年12月31日") }
        let ssClose = year.changesInEquity.first { ($0.label ?? "").contains("2025年12月31日") }
        #expect(ssOpen?.order != nil && ssClose?.order != nil)
        #expect(ssOpen!.order! < ssClose!.order!)
        #expect(
            Self.labelValues(year.changesInEquity, containing: "当社株主への配当金")
                .contains(-147_644_000_000))

        // 短期借入の内訳はキヤノン型 components（直後2行・合計一致）
        let stTotal = try #require(
            year.balanceSheet.first {
                ($0.label ?? "").contains("短期借入金及び１年以内に返済する長期債務合計")
            })
        #expect(stTotal.isTotal == true)
        #expect(stTotal.value == 511_139_000_000)
        let comps = try #require(stTotal.components)
        #expect(comps.map(\.weight) == [1, 1])
        let childRows = year.balanceSheet.filter {
            ($0.label ?? "").contains("金融サービスに係る短")
                || ($0.label ?? "").contains("その他の短期借入金")
        }
        #expect(childRows.count == 2)
        #expect(Set(comps.map(\.tag)) == Set(childRows.map(\.tag)))
        #expect(childRows.map(\.value).reduce(0, +) == stTotal.value)
        #expect(
            year.balanceSheet.contains {
                ($0.label ?? "").contains("金融サービスに係る短") && $0.value == 38_100_000_000
                    && $0.order == (stTotal.order ?? -1) + 1
            })
        #expect(
            year.balanceSheet.contains {
                ($0.label ?? "").contains("その他の短期借入金") && $0.value == 473_039_000_000
                    && $0.order == (stTotal.order ?? -1) + 2
            })
        // キヤノン本表でキヤノン型 components が付くのはこの1行のみ
        #expect(year.balanceSheet.filter { $0.components != nil }.map(\.tag) == [stTotal.tag])
        #expect(year.incomeStatement.allSatisfy { $0.components == nil })
        #expect(year.cashFlow.allSatisfy { $0.components == nil })
        #expect(year.changesInEquity.allSatisfy { $0.components == nil })
        // 内訳が前に来るセクション合計はキヤノン型対象外
        #expect(year.balanceSheet.first { $0.label == "流動資産合計" }?.components == nil)
    }

    @Test
    func nomuraUSGAAPStatementExtractsBrokerDealerPrimaryStatements() async throws {
        guard await Self.ensureAvailable("S100YC5C") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100YC5C",
                statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]))

        Self.expectHTMLReadingOrder(year.balanceSheet)
        Self.expectHTMLReadingOrder(year.incomeStatement)
        Self.expectHTMLReadingOrder(year.cashFlow)

        let cashGroup = try #require(year.balanceSheet.first { $0.label == "計" })
        #expect(cashGroup.value == 5_648_974_000_000)
        #expect(cashGroup.isTotal == true)
        #expect(cashGroup.section == .assets)
        #expect(cashGroup.components == nil)
        let keiRows = year.balanceSheet.filter { $0.label == "計" }
        let keiAllTotal = !keiRows.isEmpty && keiRows.allSatisfy { $0.isTotal }
        #expect(keiAllTotal)
        #expect(Self.exactLabelValue(year.balanceSheet, "資産合計") == 62_645_925_000_000)
        #expect(Self.exactLabelValue(year.balanceSheet, "資本合計") == 3_854_915_000_000)
        #expect(year.balanceSheet.contains { $0.label == "資産合計" && $0.section == .assets })
        #expect(year.balanceSheet.contains { $0.label == "負債合計" && $0.section == .liabilities })
        #expect(year.balanceSheet.contains { $0.label == "資本合計" && $0.section == .netAssets })
        #expect(
            year.balanceSheet.contains {
                $0.label == "負債および資本合計" && $0.value == 62_645_925_000_000
                    && $0.isTotal && $0.section == nil
            })

        #expect(Self.exactLabelValue(year.incomeStatement, "収益合計") == 4_758_486_000_000)
        #expect(
            year.incomeStatement.contains {
                $0.label == "金融費用以外の費用計" && $0.value == 1_627_892_000_000 && $0.isTotal
            })
        #expect(
            Self.exactLabelValue(year.incomeStatement, "当社株主に帰属する当期純利益")
                == 362_129_000_000)

        #expect(
            Self.exactLabelValue(year.cashFlow, "営業活動に使用された現金（純額）")
                == -842_960_000_000)
        #expect(
            year.cashFlow.contains {
                $0.label == "営業活動に使用された現金（純額）" && $0.section == .operating
                    && $0.isTotal && $0.value == -842_960_000_000
            })
        #expect(
            year.cashFlow.contains {
                ($0.label ?? "").contains("投資活動に使用された現金") && $0.section == .investing
                    && $0.isTotal && $0.value == -1_498_923_000_000
            })
        #expect(
            year.cashFlow.contains {
                ($0.label ?? "").contains("財務活動から得た現金") && $0.section == .financing
                    && $0.isTotal && $0.value == 2_095_851_000_000
            })
        let cfOpen = year.cashFlow.first { ($0.label ?? "").contains("期首残高") }
        let cfClose = year.cashFlow.first { ($0.label ?? "").contains("期末残高") }
        #expect(cfOpen?.section == nil && cfClose?.section == nil)
        #expect(cfOpen?.order != nil && cfClose?.order != nil)
        #expect(cfOpen!.order! < cfClose!.order!)

        Self.expectHTMLReadingOrder(year.changesInEquity)
        let expectedSS: [StatementGoldenRow] = [
            .init(label: "期首残高", section: "資本金", value: 594_493_000_000, isTotal: true),
            .init(label: "期末残高", section: "資本金", value: 594_493_000_000, isTotal: true),
            .init(label: "期首残高", section: "資本剰余金", value: 704_877_000_000, isTotal: true),
            .init(label: "株式に基づく報酬取引", section: "資本剰余金", value: 1_400_000_000, isTotal: false),
            .init(label: "子会社に対する持分変動", section: "資本剰余金", value: 0, isTotal: false),
            .init(label: "関連会社に対する持分変動", section: "資本剰余金", value: -16_000_000, isTotal: false),
            .init(label: "期末残高", section: "資本剰余金", value: 706_261_000_000, isTotal: true),
            .init(label: "期首残高", section: "利益剰余金", value: 1_867_379_000_000, isTotal: true),
            .init(label: "当社株主に帰属する当期純利益", section: "利益剰余金", value: 362_129_000_000, isTotal: false),
            .init(label: "現金配当金", section: "利益剰余金", value: -148_840_000_000, isTotal: false),
            .init(label: "自己株式処分損益", section: "利益剰余金", value: -9_016_000_000, isTotal: false),
            .init(label: "自己株式の消却", section: "利益剰余金", value: -57_666_000_000, isTotal: false),
            .init(label: "期末残高", section: "利益剰余金", value: 2_013_986_000_000, isTotal: true),
            .init(label: "期首残高", section: "為替換算調整額", value: 407_977_000_000, isTotal: true),
            .init(label: "当期純変動額", section: "為替換算調整額", value: 142_524_000_000, isTotal: false),
            .init(label: "期末残高", section: "為替換算調整額", value: 550_501_000_000, isTotal: true),
            .init(label: "期首残高", section: "確定給付年金制度", value: -7_105_000_000, isTotal: true),
            .init(label: "年金債務調整額", section: "確定給付年金制度", value: 6_983_000_000, isTotal: false),
            .init(label: "期末残高", section: "確定給付年金制度", value: -122_000_000, isTotal: true),
            .init(label: "期首残高", section: "トレーディング目的以外の負債証券", value: -1_147_000_000, isTotal: true),
            .init(
                label: "トレーディング目的以外の負債証券の未実現損益",
                section: "トレーディング目的以外の負債証券", value: -2_215_000_000, isTotal: false),
            .init(label: "期末残高", section: "トレーディング目的以外の負債証券", value: -3_362_000_000, isTotal: true),
            .init(label: "期首残高", section: "自己クレジット調整額", value: 48_083_000_000, isTotal: true),
            .init(label: "自己クレジット調整額", section: "自己クレジット調整額", value: -46_879_000_000, isTotal: false),
            .init(label: "期末残高", section: "自己クレジット調整額", value: 1_204_000_000, isTotal: true),
            .init(label: "期末残高", section: "累積的その他の包括利益", value: 548_221_000_000, isTotal: true),
            .init(label: "期首残高", section: "自己株式", value: -143_678_000_000, isTotal: true),
            .init(label: "取得", section: "自己株式", value: -101_499_000_000, isTotal: false),
            .init(label: "売却", section: "自己株式", value: 0, isTotal: false),
            .init(label: "従業員に対する発行株式", section: "自己株式", value: 32_418_000_000, isTotal: false),
            .init(label: "消却", section: "自己株式", value: 57_666_000_000, isTotal: false),
            .init(label: "期末残高", section: "自己株式", value: -155_093_000_000, isTotal: true),
            .init(label: "期末残高", section: "当社株主資本合計", value: 3_707_868_000_000, isTotal: true),
            .init(label: "期首残高", section: "非支配持分", value: 110_120_000_000, isTotal: true),
            .init(label: "現金配当金", section: "非支配持分", value: -21_056_000_000, isTotal: false),
            .init(label: "非支配持分に帰属する当期純利益", section: "非支配持分", value: 12_253_000_000, isTotal: false),
            .init(
                label: "為替換算調整額", section: "非支配持分に帰属する累積的その他の包括利益",
                value: 5_214_000_000, isTotal: false),
            .init(label: "非支配持分保有者との取引(純額)", section: "非支配持分", value: 44_694_000_000, isTotal: false),
            .init(label: "その他の増減（純額）", section: "非支配持分", value: -4_178_000_000, isTotal: false),
            .init(label: "期末残高", section: "非支配持分", value: 147_047_000_000, isTotal: true),
            .init(label: "期末残高", section: "資本合計", value: 3_854_915_000_000, isTotal: true),
        ]
        #expect(Self.statementGoldenRows(year.changesInEquity) == expectedSS)
    }

    @Test
    func omronUSGAAPStatementExtractsIncomeAndEquityWithoutOperatingProfitLine() async throws {
        guard await Self.ensureAvailable("S100YG81") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100YG81",
                statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]))

        Self.expectHTMLReadingOrder(year.balanceSheet)
        Self.expectHTMLReadingOrder(year.incomeStatement)
        Self.expectHTMLReadingOrder(year.cashFlow)
        Self.expectHTMLReadingOrder(year.changesInEquity)

        let expectedBS: [StatementGoldenRow] = [
            .init(label: "現金及び現金同等物", section: "assets", value: 166_541_000_000, isTotal: false),
            .init(label: "受取手形及び売掛金", section: "assets", value: 169_633_000_000, isTotal: false),
            .init(label: "貸倒引当金", section: "assets", value: -1_047_000_000, isTotal: false),
            .init(label: "棚卸資産", section: "assets", value: 154_215_000_000, isTotal: false),
            .init(label: "非継続事業流動資産", section: "assets", value: 127_242_000_000, isTotal: false),
            .init(label: "その他の流動資産", section: "assets", value: 59_524_000_000, isTotal: false),
            .init(label: "流動資産合計", section: "assets", value: 676_108_000_000, isTotal: true),
            .init(label: "有形固定資産", section: "assets", value: 103_072_000_000, isTotal: false),
            .init(label: "オペレーティング・リース使用権資産", section: "assets", value: 44_649_000_000, isTotal: false),
            .init(label: "のれん", section: "assets", value: 374_211_000_000, isTotal: false),
            .init(label: "その他の無形資産", section: "assets", value: 130_375_000_000, isTotal: false),
            .init(label: "関連会社に対する投資及び貸付金", section: "assets", value: 13_034_000_000, isTotal: false),
            .init(label: "投資有価証券", section: "assets", value: 48_665_000_000, isTotal: false),
            .init(label: "施設借用保証金", section: "assets", value: 7_110_000_000, isTotal: false),
            .init(label: "前払年金費用", section: "assets", value: 97_218_000_000, isTotal: false),
            .init(label: "繰延税金", section: "assets", value: 14_067_000_000, isTotal: false),
            .init(label: "非継続事業固定資産", section: "assets", value: 0, isTotal: false),
            .init(label: "その他の資産", section: "assets", value: 7_754_000_000, isTotal: false),
            .init(label: "投資その他の資産合計", section: "assets", value: 737_083_000_000, isTotal: true),
            .init(label: "資産合計", section: "assets", value: 1_516_263_000_000, isTotal: true),
            .init(label: "支払手形及び買掛金・未払金", section: "liabilities", value: 86_677_000_000, isTotal: false),
            .init(label: "短期債務", section: "liabilities", value: 121_668_000_000, isTotal: false),
            .init(label: "未払費用", section: "liabilities", value: 44_120_000_000, isTotal: false),
            .init(label: "未払税金", section: "liabilities", value: 10_063_000_000, isTotal: false),
            .init(label: "短期オペレーティング・リース負債", section: "liabilities", value: 12_521_000_000, isTotal: false),
            .init(label: "非継続事業流動負債", section: "liabilities", value: 40_553_000_000, isTotal: false),
            .init(label: "その他の流動負債", section: "liabilities", value: 54_647_000_000, isTotal: false),
            .init(label: "流動負債合計", section: "liabilities", value: 370_249_000_000, isTotal: true),
            .init(label: "繰延税金", section: "liabilities", value: 14_403_000_000, isTotal: false),
            .init(label: "退職給付引当金", section: "liabilities", value: 4_952_000_000, isTotal: false),
            .init(label: "長期債務", section: "liabilities", value: 75_910_000_000, isTotal: false),
            .init(label: "長期オペレーティング・リース負債", section: "liabilities", value: 31_110_000_000, isTotal: false),
            .init(label: "非継続事業固定負債", section: "liabilities", value: 0, isTotal: false),
            .init(label: "その他の固定負債", section: "liabilities", value: 19_077_000_000, isTotal: false),
            .init(label: "負債合計", section: "liabilities", value: 515_701_000_000, isTotal: true),
            .init(label: "資本金", section: "net_assets", value: 64_100_000_000, isTotal: false),
            .init(label: "資本剰余金", section: "net_assets", value: 99_932_000_000, isTotal: false),
            .init(label: "利益準備金", section: "net_assets", value: 32_313_000_000, isTotal: false),
            .init(label: "その他の剰余金", section: "net_assets", value: 555_680_000_000, isTotal: false),
            .init(label: "その他の包括利益累計額", section: "net_assets", value: 154_358_000_000, isTotal: false),
            .init(label: "自己株式 （注）", section: "net_assets", value: -70_498_000_000, isTotal: false),
            .init(label: "株主資本合計", section: "net_assets", value: 835_885_000_000, isTotal: true),
            .init(label: "非支配持分", section: "net_assets", value: 164_677_000_000, isTotal: false),
            .init(label: "純資産合計", section: "net_assets", value: 1_000_562_000_000, isTotal: true),
            .init(label: "負債及び純資産合計", section: nil, value: 1_516_263_000_000, isTotal: true),
        ]
        #expect(Self.statementGoldenRows(year.balanceSheet) == expectedBS)

        let expectedPL: [StatementGoldenRow] = [
            .init(label: "売上高", section: nil, value: 767_351_000_000, isTotal: false),
            .init(label: "売上原価", section: nil, value: 416_350_000_000, isTotal: false),
            .init(label: "販売費及び一般管理費", section: nil, value: 245_398_000_000, isTotal: false),
            .init(label: "試験研究開発費", section: nil, value: 45_668_000_000, isTotal: false),
            .init(label: "構造改革費用", section: nil, value: 2_617_000_000, isTotal: false),
            .init(label: "のれんの減損損失", section: nil, value: 0, isTotal: false),
            .init(label: "その他費用（△収益）―純額―", section: nil, value: 4_747_000_000, isTotal: false),
            .init(label: "継続事業からの法人税等、持分法投資損益控除前当期純利益", section: nil, value: 52_571_000_000, isTotal: true),
            .init(label: "法人税等", section: nil, value: 13_466_000_000, isTotal: false),
            .init(label: "持分法投資損益", section: nil, value: 2_123_000_000, isTotal: false),
            .init(label: "継続事業からの当期純利益", section: nil, value: 36_982_000_000, isTotal: true),
            .init(label: "非継続事業からの当期純損失", section: nil, value: -5_705_000_000, isTotal: false),
            .init(label: "当期純利益", section: nil, value: 31_277_000_000, isTotal: true),
            .init(label: "非支配持分帰属利益（△損失）", section: nil, value: 2_790_000_000, isTotal: false),
            .init(label: "当社株主に帰属する当期純利益", section: nil, value: 28_487_000_000, isTotal: true),
            .init(label: "継続事業からの当社株主に帰属する当期純利益", section: nil, value: 173.8, isTotal: false),
            .init(label: "非継続事業からの当社株主に帰属する当期純損失", section: nil, value: -29.0, isTotal: false),
            .init(label: "当社株主に帰属する当期純利益", section: nil, value: 144.8, isTotal: false),
            .init(label: "継続事業からの当社株主に帰属する当期純利益", section: nil, value: 0, isTotal: false),
            .init(label: "非継続事業からの当社株主に帰属する当期純損失", section: nil, value: 0, isTotal: false),
            .init(label: "当社株主に帰属する 当期純利益", section: nil, value: 0, isTotal: false),
        ]
        #expect(Self.statementGoldenRows(year.incomeStatement) == expectedPL)

        let expectedCF: [StatementGoldenRow] = [
            .init(label: "当期純利益", section: "operating", value: 31_277_000_000, isTotal: false),
            .init(label: "減価償却費", section: "operating", value: 33_778_000_000, isTotal: false),
            .init(label: "株式報酬費用", section: "operating", value: 685_000_000, isTotal: false),
            .init(label: "固定資産除売却損（純額）", section: "operating", value: 1_312_000_000, isTotal: false),
            .init(label: "投資有価証券評価損（△益）（純額）", section: "operating", value: 271_000_000, isTotal: false),
            .init(label: "のれんの減損損失", section: "operating", value: 0, isTotal: false),
            .init(label: "長期性資産の減損", section: "operating", value: 4_416_000_000, isTotal: false),
            .init(label: "事業譲渡に関連する損失（△利益）（純額）", section: "operating", value: 4_470_000_000, isTotal: false),
            .init(label: "退職給付引当金及び前払年金費用", section: "operating", value: -2_106_000_000, isTotal: false),
            .init(label: "繰延税額", section: "operating", value: -7_844_000_000, isTotal: false),
            .init(label: "持分法投資損益", section: "operating", value: 2_123_000_000, isTotal: false),
            .init(label: "受取手形及び売掛金の増加", section: "operating", value: -4_076_000_000, isTotal: false),
            .init(label: "棚卸資産の増加", section: "operating", value: -6_401_000_000, isTotal: false),
            .init(label: "その他の資産の減少（△増加）", section: "operating", value: -8_416_000_000, isTotal: false),
            .init(label: "支払手形及び買掛金・未払金の増加", section: "operating", value: 5_990_000_000, isTotal: false),
            .init(label: "未払税金の増加", section: "operating", value: 3_777_000_000, isTotal: false),
            .init(label: "未払費用及びその他流動負債の増加", section: "operating", value: 2_687_000_000, isTotal: false),
            .init(label: "その他（純額）", section: "operating", value: -1_024_000_000, isTotal: false),
            .init(label: "営業活動によるキャッシュ・フロー", section: "operating", value: 60_919_000_000, isTotal: true),
            .init(label: "投資有価証券の売却による収入", section: "investing", value: 664_000_000, isTotal: false),
            .init(label: "投資有価証券の取得", section: "investing", value: -4_018_000_000, isTotal: false),
            .init(label: "資本的支出", section: "investing", value: -53_105_000_000, isTotal: false),
            .init(label: "事業・会社の買収（現金取得額との純額）", section: "investing", value: -12_377_000_000, isTotal: false),
            .init(label: "有形固定資産の売却による収入", section: "investing", value: 617_000_000, isTotal: false),
            .init(label: "貸付けによる支出", section: "investing", value: -786_000_000, isTotal: false),
            .init(label: "貸付金の回収による収入", section: "investing", value: 1_366_000_000, isTotal: false),
            .init(label: "関連会社に対する投資の増加", section: "investing", value: -1_008_000_000, isTotal: false),
            .init(label: "事業・会社の売却（現金流出額との純額）", section: "investing", value: -2_264_000_000, isTotal: false),
            .init(label: "その他(純額)", section: "investing", value: 840_000_000, isTotal: false),
            .init(label: "投資活動によるキャッシュ・フロー", section: "investing", value: -70_071_000_000, isTotal: true),
            .init(label: "満期日が3ヶ月以内の短期債務の増加（純額）", section: "financing", value: 54_262_000_000, isTotal: false),
            .init(label: "満期日が3ヶ月超の短期債務による収入", section: "financing", value: 1_160_000_000, isTotal: false),
            .init(label: "満期日が3ヶ月超の短期債務による支出", section: "financing", value: -1_210_000_000, isTotal: false),
            .init(label: "長期債務による収入", section: "financing", value: 5_745_000_000, isTotal: false),
            .init(label: "長期債務による支出", section: "financing", value: -4_773_000_000, isTotal: false),
            .init(label: "親会社の支払配当金", section: "financing", value: -20_462_000_000, isTotal: false),
            .init(label: "非支配株主への支払配当金", section: "financing", value: -1_268_000_000, isTotal: false),
            .init(label: "自己株式の売却による収入", section: "financing", value: 263_000_000, isTotal: false),
            .init(label: "自己株式の取得による支出", section: "financing", value: -1_322_000_000, isTotal: false),
            .init(label: "その他(純額)", section: "financing", value: -33_000_000, isTotal: false),
            .init(label: "財務活動によるキャッシュ・フロー", section: "financing", value: 32_362_000_000, isTotal: true),
            .init(label: "換算レート変動の影響", section: "financing", value: 11_106_000_000, isTotal: false),
            .init(label: "現金及び現金同等物の増減額", section: "financing", value: 34_316_000_000, isTotal: false),
            .init(label: "期首現金及び現金同等物残高", section: "financing", value: 149_023_000_000, isTotal: false),
            .init(label: "期末現金及び現金同等物残高", section: "financing", value: 183_339_000_000, isTotal: false),
            .init(label: "非継続事業に係る期末現金及び現金同等物残高（控除）", section: "financing", value: 16_798_000_000, isTotal: false),
            .init(label: "継続事業に係る期末現金及び現金同等物残高", section: "financing", value: 166_541_000_000, isTotal: false),
            .init(label: "支払利息の支払額", section: "operating", value: 1_925_000_000, isTotal: false),
            .init(label: "当期税金の支払額", section: "operating", value: 20_845_000_000, isTotal: false),
            .init(label: "資本的支出に関連する債務", section: "operating", value: 7_502_000_000, isTotal: false),
        ]
        #expect(Self.statementGoldenRows(year.cashFlow) == expectedCF)

        let expectedSS: [StatementGoldenRow] = [
            .init(label: "第88期末現在", section: nil, value: 934_432_000_000, isTotal: true),
            .init(label: "当期純利益", section: nil, value: 31_277_000_000, isTotal: false),
            .init(label: "当社株主への 配当金(注)", section: nil, value: -20_450_000_000, isTotal: false),
            .init(label: "非支配株主への配当金", section: nil, value: -1_268_000_000, isTotal: false),
            .init(label: "非支配株主との資本取引等", section: nil, value: 32_000_000, isTotal: false),
            .init(label: "連結子会社の増加による 非支配持分の増加", section: nil, value: 134_000_000, isTotal: false),
            .init(label: "株式に基づく 報酬", section: nil, value: 703_000_000, isTotal: false),
            .init(label: "利益準備金 繰入", section: nil, value: 0, isTotal: false),
            .init(label: "その他の 包括利益", section: nil, value: 57_025_000_000, isTotal: false),
            .init(label: "自己株式の 取得およびその他", section: nil, value: -1_323_000_000, isTotal: false),
            .init(label: "第89期末現在", section: nil, value: 1_000_562_000_000, isTotal: true),
        ]
        #expect(Self.statementGoldenRows(year.changesInEquity) == expectedSS)
    }

    @Test
    func komatsuUSGAAPStatementExtractsEquityOpenAndCloseBalances() async throws {
        guard await Self.ensureAvailable("S100YD25") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100YD25",
                statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]))

        Self.expectHTMLReadingOrder(year.changesInEquity)
        #expect(Self.exactLabelValue(year.balanceSheet, "資産合計") == 6_423_941_000_000)
        #expect(Self.exactLabelValue(year.changesInEquity, "期末残高") == 3_708_427_000_000)
        let ssOpen = year.changesInEquity.first { $0.label == "期首残高" }
        let ssClose = year.changesInEquity.first { $0.label == "期末残高" }
        #expect(ssOpen?.order != nil && ssClose?.order != nil)
        #expect(ssOpen!.order! < ssClose!.order!)
    }

    @Test
    func orixUSGAAPStatementExtractsDatedEquityBalances() async throws {
        guard await Self.ensureAvailable("S100YG5L") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100YG5L",
                statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]))

        Self.expectHTMLReadingOrder(year.changesInEquity)
        #expect(Self.exactLabelValue(year.balanceSheet, "資産合計") == 18_002_776_000_000)
        #expect(
            year.changesInEquity.contains {
                ($0.label ?? "").contains("2026年３月31日") && $0.value == 4_573_068_000_000
            })
        let ssOpen = year.changesInEquity.first { ($0.label ?? "").contains("2025年３月31日") }
        let ssClose = year.changesInEquity.first { ($0.label ?? "").contains("2026年３月31日") }
        #expect(ssOpen?.order != nil && ssClose?.order != nil)
        #expect(ssOpen!.order! < ssClose!.order!)
    }
}
