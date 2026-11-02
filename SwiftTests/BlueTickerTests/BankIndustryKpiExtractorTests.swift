// 銀行業種 KPI（預貸率・OHR）の L0: FieldSet / 合成 XBRL から式と出所を固定する。
// 実書類の円単位は Spec/Oracle/RealXbrlBankIndustryKpiTests。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct BankIndustryKpiExtractorTests {
    private let million = Financial.millionYen

    @Test func chibaStyleLDRAndOHRFromTagElements() throws {
        let tags: XbrlTagElements = [
            "DepositsLiabilitiesBNK": ["CurrentYearInstant": 16_830_424 * million],
            "NegotiableCertificatesOfDepositLiabilitiesBNK": [
                "CurrentYearInstant": 180_766 * million
            ],
            "LoansAndBillsDiscountedAssetsBNK": ["CurrentYearInstant": 14_082_336 * million],
            "InterestIncomeOIBNK": ["CurrentYearDuration": 200_000 * million],
            "InterestExpensesOEBNK": ["CurrentYearDuration": 50_000 * million],
            "FeesAndCommissionsOIBNK": ["CurrentYearDuration": 80_000 * million],
            "FeesAndCommissionsPaymentsOEBNK": ["CurrentYearDuration": 10_000 * million],
            "TradingIncomeOIBNK": ["CurrentYearDuration": 5_000 * million],
            "OtherOrdinaryIncomeOIBNK": ["CurrentYearDuration": 4_000 * million],
            "OtherOrdinaryExpensesOEBNK": ["CurrentYearDuration": 6_000 * million],
            "GeneralAndAdministrativeExpensesOEBNK": ["CurrentYearDuration": 104_888 * million],
        ]
        guard case .resolved(let payload, let source, _) =
            BankIndustryKpiExtractor.resolve(tagElements: tags)
        else {
            Issue.record("expected resolved bank KPI snapshot")
            return
        }
        #expect(source == industryKpiSourceXbrlFacts)
        #expect(payload.industryGroup == industryKpiGroupBank)
        let scope = industryKpiScopeConsolidated
        #expect(payload.fact(key: industryKpiKeyDeposits, scope: scope)?.value == 16_830_424 * million)
        #expect(payload.fact(key: industryKpiKeyNegotiableCDs, scope: scope)?.value == 180_766 * million)
        #expect(payload.fact(key: industryKpiKeyLoans, scope: scope)?.value == 14_082_336 * million)
        #expect(payload.fact(key: industryKpiKeyNetInterestIncome, scope: scope)?.value == 150_000 * million)
        #expect(payload.fact(key: industryKpiKeyOperatingExpenses, scope: scope)?.value == 104_888 * million)
        let gp = try #require(payload.fact(key: industryKpiKeyGrossBusinessProfit, scope: scope)?.value)
        #expect(gp == 223_000 * million)
        let ldr = try #require(payload.fact(key: industryKpiKeyLDR, scope: scope))
        #expect(round2(ldr.value) == 82.78)
        #expect(ldr.unit == AmountUnit.Code.percent.rawValue)
        #expect(ldr.periodBasis == industryKpiPeriodBasisPeriodEnd)
        #expect(ldr.sourceKind == industryKpiSourceKindDerived)
        let ohr = try #require(payload.fact(key: industryKpiKeyOHR, scope: scope))
        #expect(round2(ohr.value) == round2(104_888 / 223_000 * 100))
        #expect(ohr.periodBasis == industryKpiPeriodBasisDuration)
        #expect(
            payload.fact(key: industryKpiKeyDeposits, scope: scope)?.sourceRef
                == "DepositsLiabilitiesBNK")
    }

    @Test func missingNegotiableCDsTreatsDenominatorAsDepositsOnly() throws {
        let tags: XbrlTagElements = [
            "DepositsLiabilitiesBNK": ["CurrentYearInstant": 100 * million],
            "LoansAndBillsDiscountedAssetsBNK": ["CurrentYearInstant": 80 * million],
            "GeneralAndAdministrativeExpensesOEBNK": ["CurrentYearDuration": 10 * million],
            "InterestIncomeOIBNK": ["CurrentYearDuration": 20 * million],
        ]
        guard case .resolved(let payload, _, _) =
            BankIndustryKpiExtractor.resolve(tagElements: tags)
        else {
            Issue.record("expected resolved")
            return
        }
        #expect(payload.fact(key: industryKpiKeyNegotiableCDs, scope: industryKpiScopeConsolidated) == nil)
        let ldr = try #require(payload.fact(key: industryKpiKeyLDR, scope: industryKpiScopeConsolidated))
        #expect(ldr.value == 80)
    }

    @Test func filerAndConsolidatedAreBothEmittedWhenDualContextsExist() throws {
        let tags: XbrlTagElements = [
            "DepositsLiabilitiesBNK": [
                "CurrentYearInstant": 200 * million,
                "CurrentYearInstant_NonConsolidatedMember": 150 * million,
            ],
            "LoansAndBillsDiscountedAssetsBNK": [
                "CurrentYearInstant": 100 * million,
                "CurrentYearInstant_NonConsolidatedMember": 90 * million,
            ],
        ]
        guard case .resolved(let payload, _, _) =
            BankIndustryKpiExtractor.resolve(tagElements: tags)
        else {
            Issue.record("expected resolved")
            return
        }
        let consLDR = try #require(
            payload.fact(key: industryKpiKeyLDR, scope: industryKpiScopeConsolidated))
        let filerLDR = try #require(
            payload.fact(key: industryKpiKeyLDR, scope: industryKpiScopeFiler))
        #expect(consLDR.value == 50)
        #expect(filerLDR.value == 60)
    }

    @Test func nonBankTagSetIsNotApplicable() {
        let tags: XbrlTagElements = [
            "NetSales": ["CurrentYearDuration": 1_000 * million]
        ]
        guard case .notApplicable(let reason) =
            BankIndustryKpiExtractor.resolve(tagElements: tags)
        else {
            Issue.record("expected not_bank")
            return
        }
        #expect(reason == industryKpiNotApplicableNotBank)
    }

    @Test func xmlInstanceExtractsDepositsLoansAndOHR() {
        let xml = XBRLTestSupport.makeXbrlDurationAndInstant("""
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY" decimals="-6">16830424000000</jppfs_cor:DepositsLiabilitiesBNK>
            <jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY" decimals="-6">180766000000</jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK>
            <jppfs_cor:LoansAndBillsDiscountedAssetsBNK contextRef="CurrentYearInstant"
                unitRef="JPY" decimals="-6">14082336000000</jppfs_cor:LoansAndBillsDiscountedAssetsBNK>
            <jppfs_cor:InterestIncomeOIBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">223274000000</jppfs_cor:InterestIncomeOIBNK>
            <jppfs_cor:GeneralAndAdministrativeExpensesOEBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">104888000000</jppfs_cor:GeneralAndAdministrativeExpensesOEBNK>
            """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            guard case .resolved(let payload, _, _) =
                BankIndustryKpiExtractor.resolve(xbrlDir: dir)
            else {
                Issue.record("expected resolved from synthetic XBRL")
                return
            }
            let scope = industryKpiScopeConsolidated
            #expect(payload.fact(key: industryKpiKeyLoans, scope: scope)?.value == 14_082_336 * million)
            let ldr = payload.fact(key: industryKpiKeyLDR, scope: scope)
            #expect(ldr.map { round2($0.value) } == 82.78)
            let ohr = payload.fact(key: industryKpiKeyOHR, scope: scope)
            let gp = payload.fact(key: industryKpiKeyGrossBusinessProfit, scope: scope)?.value
            let opex = payload.fact(key: industryKpiKeyOperatingExpenses, scope: scope)?.value
            if let ohr, let gp, let opex, gp != 0 {
                #expect(round2(ohr.value) == round2(opex / gp * 100))
            } else {
                Issue.record("expected OHR from synthetic XBRL")
            }
        }
    }

    @Test func payloadUsesSnakeCaseKeys() throws {
        let fact = IndustryKpiFactValue(
            kpiKey: industryKpiKeyLDR, value: 82.78,
            unit: AmountUnit.Code.percent.rawValue,
            periodBasis: industryKpiPeriodBasisPeriodEnd,
            scope: industryKpiScopeConsolidated,
            sourceKind: industryKpiSourceKindDerived,
            sourceRef: "LoansAndBillsDiscountedAssetsBNK/(DepositsLiabilitiesBNK+NegotiableCertificatesOfDepositLiabilitiesBNK)")
        let payload = IndustryKpiSnapshotPayload(
            industryGroup: industryKpiGroupBank, facts: [fact])
        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["industry_group"] as? String == industryKpiGroupBank)
        let facts = try #require(obj?["facts"] as? [[String: Any]])
        #expect(facts.first?["kpi_key"] as? String == industryKpiKeyLDR)
        #expect(facts.first?["period_basis"] as? String == industryKpiPeriodBasisPeriodEnd)
        #expect(facts.first?["source_kind"] as? String == industryKpiSourceKindDerived)
        #expect(facts.first?["source_ref"] as? String != nil)
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
