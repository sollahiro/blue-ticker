import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct MasterDataManagerTests {

    @Test func testResolveEdinetCSVURLUsesEnvPathFirst() {
        let existing = "/opt/blue-ticker-assets/EdinetcodeDlInfo.csv"
        let url = resolveEdinetCSVURL(
            environment: ["BLUE_TICKER_ASSETS_PATH": "/opt/blue-ticker-assets"],
            currentDirectoryPath: "/repo",
            executableURL: URL(fileURLWithPath: "/usr/local/bin/ticker"),
            fileExists: { $0 == existing }
        )

        #expect(url?.path == existing)
    }

    @Test func testResolveEdinetCSVURLUsesCurrentDirectoryAssets() {
        let existing = "/repo/assets/EdinetcodeDlInfo.csv"
        let url = resolveEdinetCSVURL(
            environment: [:],
            currentDirectoryPath: "/repo",
            executableURL: URL(fileURLWithPath: "/usr/local/bin/ticker"),
            fileExists: { $0 == existing }
        )

        #expect(url?.path == existing)
    }

    @Test func testResolveEdinetCSVURLUsesExecutableAdjacentAssets() {
        let existing = "/tmp/blue-ticker/assets/EdinetcodeDlInfo.csv"
        let url = resolveEdinetCSVURL(
            environment: [:],
            currentDirectoryPath: "/repo",
            executableURL: URL(fileURLWithPath: "/tmp/blue-ticker/ticker"),
            fileExists: { $0 == existing }
        )

        #expect(url?.path == existing)
    }

    @Test func testResolveEdinetCSVURLUsesHomebrewPkgshareAssets() {
        let existing = "/opt/homebrew/Cellar/blue-ticker/26.5.3/share/blue-ticker/assets/EdinetcodeDlInfo.csv"
        let url = resolveEdinetCSVURL(
            environment: [:],
            currentDirectoryPath: "/repo",
            executableURL: URL(fileURLWithPath: "/opt/homebrew/Cellar/blue-ticker/26.5.3/bin/ticker"),
            fileExists: { $0 == existing }
        )

        #expect(url?.path == existing)
    }

    @Test func testResolveEdinetCSVWriteURLUsesEnvPathEvenWhenFileMissing() {
        let url = resolveEdinetCSVWriteURL(
            environment: ["BLUE_TICKER_ASSETS_PATH": "/opt/blue-ticker-assets"],
            currentDirectoryPath: "/repo",
            executableURL: URL(fileURLWithPath: "/usr/local/bin/ticker"),
            fileExists: { _ in false }
        )

        #expect(url?.path == "/opt/blue-ticker-assets/EdinetcodeDlInfo.csv")
    }

    @Test func testResolveEdinetCSVWriteURLFallsBackToExistingReadPathWithoutEnv() {
        let existing = "/repo/assets/EdinetcodeDlInfo.csv"
        let url = resolveEdinetCSVWriteURL(
            environment: [:],
            currentDirectoryPath: "/repo",
            executableURL: URL(fileURLWithPath: "/usr/local/bin/ticker"),
            fileExists: { $0 == existing }
        )

        #expect(url?.path == existing)
    }

    @Test func testResolveEdinetCSVWriteURLReturnsNilWithoutEnvOrExistingFile() {
        let url = resolveEdinetCSVWriteURL(
            environment: [:],
            currentDirectoryPath: "/repo",
            executableURL: URL(fileURLWithPath: "/usr/local/bin/ticker"),
            fileExists: { _ in false }
        )

        #expect(url == nil)
    }

    @Test func testCurrentEdinetCSVLoadsListedCompanyName() async throws {
        let manager = MasterDataManager()
        let stock = try #require(await manager.getByCode("6501"), "6501 が CSV に見つからない — EdinetcodeDlInfo.csv が欠落しているかコード検索が壊れている")

        #expect(stock.coName == "株式会社日立製作所")
        #expect(stock.s33nm == "電気機器")
        #expect(stock.mktNm == "上場")
    }

    @Test func testCurrentEdinetCSVLoadsAlphanumericSecurityCode() async throws {
        let manager = MasterDataManager()
        let stock = try #require(await manager.getByCode("477A"), "477A が CSV に見つからない — EdinetcodeDlInfo.csv が欠落しているか英数字コードのパースが壊れている")

        #expect(!stock.coName.isEmpty)
    }

    @Test func testListedCodesExcludesForeignFilerEvenWhenListed() async throws {
        let manager = MasterDataManager()
        // 1773（ワイ・ティー・エル・コーポレーション・バーハッド）は上場区分「上場」だが
        // 提出者種別が「外国法人・組合」。listedCodes() は国内法人向けユニバースのため除外する。
        let stock = try #require(await manager.getByCode("1773"))
        #expect(stock.mktNm == "上場")
        #expect(stock.filerType == "外国法人・組合")

        let listed = await manager.listedCodes()
        #expect(!listed.contains("1773"))
        #expect(listed.contains("6501"))
    }

    @Test func parseCSVRowKeepsCommasInsideQuotes() {
        let fields = parseCSVRow(#"72030,"株式会社 ""例"" 商会",製造業"#)
        #expect(fields.count == 3)
        #expect(fields[0] == "72030")
        #expect(fields[1] == #"株式会社 "例" 商会"#)
        #expect(fields[2] == "製造業")
    }

    @Test func parseCSVRowDoesNotSplitOnQuotedComma() {
        let fields = parseCSVRow(#"477A0,"Foo, Bar K.K.",情報・通信業"#)
        #expect(fields == ["477A0", "Foo, Bar K.K.", "情報・通信業"])
    }
}
