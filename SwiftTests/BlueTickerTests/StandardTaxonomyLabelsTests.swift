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

    private static func mixedRoleMemberLinkbase(tag: String, japanese: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <link:linkbase xmlns:link="http://www.xbrl.org/2003/linkbase" xmlns:xlink="http://www.w3.org/1999/xlink">
          <link:labelLink xlink:type="extended" xlink:role="http://www.xbrl.org/2003/role/link">
            <link:loc xlink:type="locator" xlink:href="jpcrp_cor.xsd#jpcrp_cor_\(tag)" xlink:label="loc_\(tag)"/>
            <link:label xlink:type="resource" xlink:label="label_\(tag)_dep" xlink:role="http://www.xbrl.org/2009/role/deprecatedLabel" xml:lang="ja">2019年版更新</link:label>
            <link:labelArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/concept-label" xlink:from="loc_\(tag)" xlink:to="label_\(tag)_dep"/>
            <link:label xlink:type="resource" xlink:label="label_\(tag)" xlink:role="http://www.xbrl.org/2003/role/label" xml:lang="ja">\(japanese)</link:label>
            <link:labelArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/concept-label" xlink:from="loc_\(tag)" xlink:to="label_\(tag)"/>
          </link:labelLink>
        </link:linkbase>
        """
    }

    private static func totalLabelOnlyLinkbase(tag: String, japanese: String, prefix: String = "jppfs_cor")
        -> String
    {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <link:linkbase xmlns:link="http://www.xbrl.org/2003/linkbase" xmlns:xlink="http://www.w3.org/1999/xlink">
          <link:labelLink xlink:type="extended" xlink:role="http://www.xbrl.org/2003/role/link">
            <link:loc xlink:type="locator" xlink:href="\(prefix).xsd#\(prefix)_\(tag)" xlink:label="loc_\(tag)"/>
            <link:label xlink:type="resource" xlink:label="label_\(tag)" xlink:role="http://www.xbrl.org/2003/role/totalLabel" xml:lang="ja">\(japanese)</link:label>
            <link:labelArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/concept-label" xlink:from="loc_\(tag)" xlink:to="label_\(tag)"/>
          </link:labelLink>
        </link:linkbase>
        """
    }

    private static func deprecatedOnlyMemberLinkbase(tag: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <link:linkbase xmlns:link="http://www.xbrl.org/2003/linkbase" xmlns:xlink="http://www.w3.org/1999/xlink">
          <link:labelLink xlink:type="extended" xlink:role="http://www.xbrl.org/2003/role/link">
            <link:loc xlink:type="locator" xlink:href="jpcrp_cor.xsd#jpcrp_cor_\(tag)" xlink:label="loc_\(tag)"/>
            <link:label xlink:type="resource" xlink:label="label_\(tag)" xlink:role="http://www.xbrl.org/2009/role/deprecatedLabel" xml:lang="ja">2019年版更新</link:label>
            <link:labelArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/concept-label" xlink:from="loc_\(tag)" xlink:to="label_\(tag)"/>
            <link:label xlink:type="resource" xlink:label="label_\(tag)_date" xlink:role="http://www.xbrl.org/2009/role/deprecatedDateLabel" xml:lang="ja">2019-02-28</link:label>
            <link:labelArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/concept-label" xlink:from="loc_\(tag)" xlink:to="label_\(tag)_date"/>
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
            #expect(labels["SellingGeneralAndAdministrativeExpenses"] == nil)
        }
    }

    @Test func standardAccountLabelsDoNotFillWhenCompanyOmitsThem() throws {
        try XBRLTestSupport.withXbrlDir(nil, extraFiles: [:]) { dir in
            let labels = XBRLUtils.loadLabelsByTag(in: dir)
            #expect(labels["OtherReportableSegmentsMember"] == "その他")
            #expect(labels["SellingGeneralAndAdministrativeExpenses"] == nil)
            #expect(labels["CompensationsSalariesAndAllowancesSGA"] == nil)
            #expect(labels["FreightageAndPackingExpensesSGA"] == nil)
            #expect(labels["TravelingAndCommunicationExpensesSGA"] == nil)
        }
    }

    @Test func companyTotalLabelIsNotReplacedByStandardPlainLabel() throws {
        try XBRLTestSupport.withXbrlDir(
            nil,
            extraFiles: [
                "company_lab.xml": Self.totalLabelOnlyLinkbase(
                    tag: "SellingGeneralAndAdministrativeExpenses",
                    japanese: "販売費及び一般管理費合計")
            ]
        ) { dir in
            let labels = XBRLUtils.loadLabelsByTag(in: dir)
            #expect(labels["SellingGeneralAndAdministrativeExpenses"] == "販売費及び一般管理費合計")
            let variants = XBRLUtils.loadLabelRoleVariants(in: dir)
            #expect(
                variants["SellingGeneralAndAdministrativeExpenses"]?[
                    "http://www.xbrl.org/2003/role/totalLabel"]
                    == "販売費及び一般管理費合計")
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
        #expect(standard["OtherOperatingSegmentsMember"] == nil)
        for (tag, label) in standard {
            #expect(!label.contains("年版更新"), "\(tag) leaked deprecated label \(label)")
            #expect(label != "2019-02-28", "\(tag) leaked deprecated date")
        }
    }

    @Test func deprecatedOnlyMemberDoesNotTakeDeprecatedOrDateLabel() throws {
        try XBRLTestSupport.withXbrlDir(
            nil,
            extraFiles: [
                "only_deprecated_lab.xml": Self.deprecatedOnlyMemberLinkbase(
                    tag: "OtherOperatingSegmentsMember"),
                "jpcrp_dep_fake_lab.xml": Self.deprecatedOnlyMemberLinkbase(
                    tag: "ShouldIgnoreDepFileMember"),
                "mixed_roles_lab.xml": Self.mixedRoleMemberLinkbase(
                    tag: "MixedRoleMember", japanese: "混在ロールの標準"),
            ]
        ) { dir in
            let parsed = XBRLUtils.parseTaxonomyLabels(in: dir)
            #expect(parsed.collapsed["OtherOperatingSegmentsMember"] == nil)
            #expect(parsed.variants["OtherOperatingSegmentsMember"] == nil)
            #expect(parsed.collapsed["ShouldIgnoreDepFileMember"] == nil)
            #expect(parsed.variants["ShouldIgnoreDepFileMember"] == nil)
            #expect(parsed.collapsed["MixedRoleMember"] == "混在ロールの標準")
            #expect(parsed.variants["MixedRoleMember"]?["http://www.xbrl.org/2009/role/deprecatedLabel"] == nil)
            #expect(
                parsed.variants["MixedRoleMember"]?["http://www.xbrl.org/2003/role/label"]
                    == "混在ロールの標準")

            let labels = XBRLUtils.loadLabelsByTag(in: dir)
            let leaked = labels["OtherOperatingSegmentsMember"]
            #expect(leaked != "2019年版更新")
            #expect(leaked != "2019-02-28")
            if let leaked {
                #expect(!leaked.contains("年版更新"))
            }
        }
    }
}
