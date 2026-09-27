import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct StandardTaxonomyLabelsTests {

    private static func memberLabelLinkbase(tag: String, japanese: String, prefix: String = "jpcrp_cor")
        -> String
    {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <link:linkbase xmlns:link="http://www.xbrl.org/2003/linkbase" xmlns:xlink="http://www.w3.org/1999/xlink">
          <link:labelLink xlink:type="extended" xlink:role="http://www.xbrl.org/2003/role/link">
            <link:loc xlink:type="locator" xlink:href="\(prefix).xsd#\(prefix)_\(tag)" xlink:label="loc_\(tag)"/>
            <link:label xlink:type="resource" xlink:label="label_\(tag)" xlink:role="http://www.xbrl.org/2003/role/label" xml:lang="ja">\(japanese)</link:label>
            <link:labelArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/concept-label" xlink:from="loc_\(tag)" xlink:to="label_\(tag)"/>
          </link:labelLink>
        </link:linkbase>
        """
    }

    private static let coveredStandardMembers: [String] = [
        "OtherReportableSegmentsMember",
        "ReportableSegmentsMember",
        "ReconcilingItemsMember",
        "CorporateSharedMember",
        "UnallocatedAmountsAndEliminationMember",
        "TotalOfReportableSegmentsAndOthersMember",
        "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
        "OtherOperatingSegmentsAxisMember",
        "EntityTotalMember",
        Xbrl.entityTotalMemberName,
    ]

    @Test func companyPackageLabelWinsOverStandardJpcrpLabel() throws {
        try XBRLTestSupport.withXbrlDir(
            nil,
            extraFiles: [
                "company_lab.xml": Self.memberLabelLinkbase(
                    tag: "OtherReportableSegmentsMember", japanese: "当社その他事業")
            ]
        ) { dir in
            let labels = XBRLUtils.loadLabelsByTag(in: dir)
            #expect(labels["OtherReportableSegmentsMember"] == "当社その他事業")
            #expect(XBRLUtils.loadStandardTaxonomyLabels()["OtherReportableSegmentsMember"] == "その他")
        }
    }

    @Test func standardJpcrpLabelFillsWhenCompanyPackageOmitsMember() throws {
        try XBRLTestSupport.withXbrlDir(
            nil,
            extraFiles: [
                "company_lab.xml": Self.memberLabelLinkbase(tag: "NetSales", japanese: "売上高", prefix: "jppfs_cor")
            ]
        ) { dir in
            let labels = XBRLUtils.loadLabelsByTag(in: dir)
            #expect(labels["OtherReportableSegmentsMember"] == "その他")
            #expect(labels["ReconcilingItemsMember"] == "調整項目")
            #expect(labels["ReportableSegmentsMember"] == "報告セグメント")
            #expect(labels["CorporateSharedMember"] == "全社（共通）")
            #expect(labels["NetSales"] == "売上高")
        }
    }

    @Test func coveredStandardMembersDoNotLeakRawEnglishMemberNames() throws {
        let standard = XBRLUtils.loadStandardTaxonomyLabels()
        #expect(!standard.isEmpty, "assets/taxonomy/labels が見つからない CWD=\(FileManager.default.currentDirectoryPath)")
        for member in Self.coveredStandardMembers {
            let label = try #require(standard[member], "missing standard label for \(member)")
            #expect(!label.isEmpty)
            #expect(label != member)
            #expect(!label.contains("Member"), "\(member) leaked as \(label)")
        }
        #expect(standard[Xbrl.entityTotalMemberName] == "連結合計又は会社合計")
        #expect(standard["NetSales"] == "売上高")
        #expect(standard["CashAndDeposits"] == "現金及び預金")
        #expect(standard["OperatingProfitLossIFRS"] == "営業利益（△損失）")
    }
}
