import BlueTickerCore
import Fluent
import FluentSQLiteDriver
import Testing
import Vapor

@testable import BltServerCore

private func withMigratedApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(AddParentDocIDToEdinetDocuments())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func seed(
    _ docID: String, type: String, edinet: String = "E03614", sec: String = "83160",
    periodEnd: String? = nil, parent: String? = nil, submit: String, desc: String?,
    db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = edinet
    model.secCode = sec
    model.filerName = "テスト株式会社"
    model.docTypeCode = type
    model.ordinanceCode = Api.ordinanceCompanyDisclosure
    model.periodEnd = periodEnd
    model.parentDocID = parent
    model.submitDateTime = submit
    model.docDescription = desc
    try await model.create(on: db)
}

@Suite struct XbrlAmendmentLookupTests {
    @Test func mapsOriginalToLatestMatchingCorrections() async throws {
        try await withMigratedApp { app in
            try await seed(
                "S100W0S7", type: "120", periodEnd: "2025-03-31",
                submit: "2025-06-20 15:37",
                desc: "有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100WRZH", type: "130", parent: "S100W0S7",
                submit: "2025-09-30 15:38",
                desc: "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100X7DX", type: "130", parent: "S100W0S7",
                submit: "2025-11-28 14:52",
                desc: "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100X7DT", type: "130", parent: "S100R1RG",
                submit: "2025-11-28 14:35",
                desc: "訂正有価証券報告書－第21期(2022/04/01－2023/03/31)", db: app.db)

            let map = try await loadAnnualXbrlCorrectionIDsByOriginal(
                db: app.db, originalDocIDs: ["S100W0S7"])
            #expect(map["S100W0S7"] == ["S100X7DX", "S100WRZH"])
            #expect(map["S100R1RG"] == nil)
        }
    }

    @Test func queryIsScopedToInFlightOriginalDocIDs() async throws {
        try await withMigratedApp { app in
            try await seed(
                "S100W0S7", type: "120", periodEnd: "2025-03-31",
                submit: "2025-06-20 15:37",
                desc: "有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100WRZH", type: "130", parent: "S100W0S7",
                submit: "2025-09-30 15:38",
                desc: "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100AAAA", type: "120", edinet: "E00001", sec: "72030",
                periodEnd: "2025-03-31", submit: "2025-06-20 15:00",
                desc: "有価証券報告書－第121期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100BBBB", type: "130", edinet: "E00001", sec: "72030", parent: "S100AAAA",
                submit: "2025-09-30 12:00",
                desc: "訂正有価証券報告書－第121期(2024/04/01－2025/03/31)", db: app.db)

            let map = try await loadAnnualXbrlCorrectionIDsByOriginal(
                db: app.db, originalDocIDs: ["S100W0S7"])
            #expect(map["S100W0S7"] == ["S100WRZH"])
            #expect(map["S100AAAA"] == nil)
            #expect(map.count == 1)
        }
    }

    @Test func queryIsScopedToInFlightListedCodes() async throws {
        try await withMigratedApp { app in
            try await seed(
                "S100W0S7", type: "120", periodEnd: "2025-03-31",
                submit: "2025-06-20 15:37",
                desc: "有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100WRZH", type: "130", parent: "S100W0S7",
                submit: "2025-09-30 15:38",
                desc: "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100AAAA", type: "120", edinet: "E00001", sec: "72030",
                periodEnd: "2025-03-31", submit: "2025-06-20 15:00",
                desc: "有価証券報告書－第121期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100BBBB", type: "130", edinet: "E00001", sec: "72030", parent: "S100AAAA",
                submit: "2025-09-30 12:00",
                desc: "訂正有価証券報告書－第121期(2024/04/01－2025/03/31)", db: app.db)

            let map = try await loadAnnualXbrlCorrectionIDsByOriginal(
                db: app.db, listedCodes: ["8316"])
            #expect(map["S100W0S7"] == ["S100WRZH"])
            #expect(map["S100AAAA"] == nil)
            #expect(map.count == 1)
        }
    }

    @Test func emptyScopeDoesNotLoadFleetCorrections() async throws {
        try await withMigratedApp { app in
            try await seed(
                "S100W0S7", type: "120", periodEnd: "2025-03-31",
                submit: "2025-06-20 15:37",
                desc: "有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100WRZH", type: "130", parent: "S100W0S7",
                submit: "2025-09-30 15:38",
                desc: "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)

            let map = try await loadAnnualXbrlCorrectionIDsByOriginal(db: app.db)
            #expect(map.isEmpty)
        }
    }

    @Test func nullParentMatchesByEdinetCodeAndPeriod() async throws {
        try await withMigratedApp { app in
            try await seed(
                "S100W0S7", type: "120", periodEnd: "2025-03-31",
                submit: "2025-06-20 15:37",
                desc: "有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100WRZH", type: "130", parent: nil,
                submit: "2025-09-30 15:38",
                desc: "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100X7DT", type: "130", parent: nil,
                submit: "2025-11-28 14:35",
                desc: "訂正有価証券報告書－第21期(2022/04/01－2023/03/31)", db: app.db)

            let map = try await loadAnnualXbrlCorrectionIDsByOriginal(
                db: app.db, originalDocIDs: ["S100W0S7"])
            #expect(map["S100W0S7"] == ["S100WRZH"])
        }
    }

    @Test func parentPointingAtPriorCorrectionStillMapsSamePeriod() async throws {
        try await withMigratedApp { app in
            try await seed(
                "S100W0S7", type: "120", periodEnd: "2025-03-31",
                submit: "2025-06-20 15:37",
                desc: "有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100WRZH", type: "130", parent: "S100W0S7",
                submit: "2025-09-30 15:38",
                desc: "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)
            try await seed(
                "S100X7DX", type: "130", parent: "S100WRZH",
                submit: "2025-11-28 14:52",
                desc: "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)", db: app.db)

            let map = try await loadAnnualXbrlCorrectionIDsByOriginal(
                db: app.db, originalDocIDs: ["S100W0S7"])
            #expect(map["S100W0S7"] == ["S100X7DX", "S100WRZH"])
        }
    }
}
