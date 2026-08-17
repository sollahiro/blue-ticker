// BorrowingsSchedule.hasLeaseDebtRowLabel / isLeaseDebtScheduleRowLabel の区分ラベル判定。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct BorrowingsScheduleLeaseLabelTests {
    @Test func leaseDebtRowLabelsAreAccepted() {
        #expect(BorrowingsSchedule.isLeaseDebtScheduleRowLabel("１年以内に返済予定のリース債務"))
        #expect(BorrowingsSchedule.isLeaseDebtScheduleRowLabel("リース債務(１年以内返済予定のものを除く。)"))
        #expect(BorrowingsSchedule.isLeaseDebtScheduleRowLabel("リース債務"))
        #expect(BorrowingsSchedule.isLeaseDebtScheduleRowLabel("リース負債"))
        #expect(BorrowingsSchedule.isLeaseDebtScheduleRowLabel("短期リース負債"))
    }

    @Test func exclusionOfLeaseFromOtherCategoryIsRejected() {
        #expect(!BorrowingsSchedule.isLeaseDebtScheduleRowLabel("借入金（リース債務を除く）"))
        #expect(!BorrowingsSchedule.isLeaseDebtScheduleRowLabel("有利子負債（リース負債を除く）"))
        #expect(!BorrowingsSchedule.isLeaseDebtScheduleRowLabel("長期借入金（リース債務を含まない）"))
        #expect(!BorrowingsSchedule.isLeaseDebtScheduleRowLabel("借用金（リース債務等を除く）"))
    }

    @Test func nonLeaseLabelsAreRejected() {
        #expect(!BorrowingsSchedule.isLeaseDebtScheduleRowLabel("短期借入金"))
        #expect(!BorrowingsSchedule.isLeaseDebtScheduleRowLabel("合計"))
        #expect(!BorrowingsSchedule.isLeaseDebtScheduleRowLabel(""))
        #expect(!BorrowingsSchedule.isLeaseDebtScheduleRowLabel("ファイナンス・リース取引"))
    }

    @Test func smokeCompaniesWithLeaseDebtRowsMatchLabelGate() async throws {
        let withLeaseRow = ["S100W043", "S100XRD8", "S100W4FB", "S100W0S7", "S100VYA0", "S100VU4O"]
        let store = EdinetCacheStore(cacheDir: SmokeCacheSupport.cacheDir)
        for docID in withLeaseRow {
            await SmokeCacheSupport.ensureCached([docID])
            guard store.hasXbrlDir(docID) else { continue }
            let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
            #expect(
                BorrowingsSchedule.hasLeaseDebtRowLabel(xbrlDir: dir),
                "expected lease debt row label for \(docID)")
        }
    }
}
