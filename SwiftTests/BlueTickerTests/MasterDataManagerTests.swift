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
}
