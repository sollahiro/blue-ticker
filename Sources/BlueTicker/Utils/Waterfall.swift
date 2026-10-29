// 財務ウォーターフォール分解ユーティリティ

import Foundation

private let financialOPLabels: Set<String> = ["経常利益", "事業利益"]
private let financialSalesLabels: Set<String> = ["経常収益"]

// MARK: - Operating Profit Waterfall

/// 年次データに営業利益前年差分解（BusinessProfit, SGA, 3要因）を付与する。
///
/// 販管費が無い年は GrossProfit − OP をウォーターフォール内でだけ使う。その差額は
/// `sellingGeneralAdministrativeExpenses`（公開 `sga`）へ書き戻さない。
/// 銀行（業務純益経路）は BusinessProfit = 業務粗利益 − 営業経費 = 業務純益（Summary OP と同値）で、
/// 既存の3スロットをそのまま使う: 売上差 = 経常収益差、粗利率差 = 業務粗利益率（業務粗利益 ÷ 経常収益）差、
/// 販管費差 = 営業経費差。3要因の和は Δ業務純益 に一致する（差額項なし）。
/// どちらかの期が銀行で、両期の経常収益・業務粗利益・営業経費（開示値）が揃わないときは前年差を出さない。
///
/// 前提: years が fyEnd 順に既ソートされていること。入力順は問わない。
func applyOperatingProfitChangeToYears(_ years: inout [YearEntry]) {
    // Step 1: BusinessProfit を補完する
    for i in 0..<years.count {
        let cd = years[i].calculatedData
        let rd = years[i].rawData

        // BusinessProfit 未設定の場合
        if cd.businessProfit == nil {
            if let base = profitBase(cd, rd), let s = waterfallSGA(cd, rd) {
                years[i].calculatedData.businessProfit = base - s
            }
        }

        // BusinessProfitMargin（Python に合わせて金融機関も計算対象）
        if years[i].calculatedData.businessProfitMargin == nil,
           let bp = years[i].calculatedData.businessProfit,
           let s = rd.sales, s > 0 {
            years[i].calculatedData.businessProfitMargin = (bp / s) * 100.0
        }
    }

    // Step 2: 時系列昇順インデックス
    let sortedIndices = years.indices.sorted { (years[$0].fyEnd ?? "") < (years[$1].fyEnd ?? "") }
    guard sortedIndices.count > 1 else { return }  // 前年差は2期以上必要

    for k in 1..<sortedIndices.count {
        let curIdx = sortedIndices[k]
        let priorIdx = sortedIndices[k - 1]

        guard years[curIdx].calculatedData.businessProfitChange == nil else { continue }

        let curCD = years[curIdx].calculatedData
        let priorCD = years[priorIdx].calculatedData
        let curRD = years[curIdx].rawData
        let priorRD = years[priorIdx].rawData

        guard let curSales = curRD.sales,
              let priorSales = priorRD.sales,
              let curBP = curCD.businessProfit,
              let priorBP = priorCD.businessProfit,
              let curSGA = waterfallSGA(curCD, curRD),
              let priorSGA = waterfallSGA(priorCD, priorRD),
              curSales > 0, priorSales > 0 else { continue }

        // 銀行: 差額の販管費や非銀行年との混在で埋めない（fail closed）。
        if isBankNetBusinessProfit(curCD) || isBankNetBusinessProfit(priorCD) {
            guard isBankNetBusinessProfit(curCD), isBankNetBusinessProfit(priorCD),
                  curCD.grossProfit != nil, priorCD.grossProfit != nil,
                  curCD.sellingGeneralAdministrativeExpenses != nil,
                  priorCD.sellingGeneralAdministrativeExpenses != nil else { continue }
        }

        // 粗利ベース（GrossProfit または BP+SGA）
        let curBase = curCD.grossProfit ?? (curBP + curSGA)
        let priorBase = priorCD.grossProfit ?? (priorBP + priorSGA)

        let curMargin = curBase / curSales
        let priorMargin = priorBase / priorSales

        let opChange = curBP - priorBP
        let salesImpact = (curSales - priorSales) * priorMargin
        let gmImpact = curSales * (curMargin - priorMargin)
        let sgaImpact = -(curSGA - priorSGA)

        years[curIdx].calculatedData.businessProfitChange = opChange
        years[curIdx].calculatedData.salesChangeImpact = salesImpact
        years[curIdx].calculatedData.grossMarginChangeImpact = gmImpact
        years[curIdx].calculatedData.sgaChangeImpact = sgaImpact
    }
}

/// 銀行業務純益経路の年か（Summary op_label が「業務純益」）。
private func isBankNetBusinessProfit(_ cd: CalculatedData) -> Bool {
    cd.opLabel == StatementFinancialsResolver.bankNetBusinessProfitLabel
}

/// ウォーターフォールで使う販管費。開示値が無い年は GrossProfit − OP の差額（ここでだけ使い、公開 `sga` には書かない）。
private func waterfallSGA(_ cd: CalculatedData, _ rd: RawData) -> Double? {
    if let sga = cd.sellingGeneralAdministrativeExpenses { return sga }
    guard let gp = cd.grossProfit, let op = rd.op else { return nil }
    return gp - op
}

/// GrossProfit または金融機関の Sales を利益ベースとして返す。
private func profitBase(_ cd: CalculatedData, _ rd: RawData) -> Double? {
    if let gp = cd.grossProfit { return gp }
    if let opLabel = cd.opLabel, let salesLabel = rd.salesLabel,
       financialOPLabels.contains(opLabel),
       financialSalesLabels.contains(salesLabel) {
        return rd.sales
    }
    return nil
}

// MARK: - Working Capital & CCC

/// 各年度に運転資本（売掛金+棚卸資産−買掛金）と CCC 構成（DSO/DIO/DPO/CCC）を付与する。
///
/// 前年差は単純な隣接年度差分のため表示側で算出する（ここでは水準値のみ）。
/// 売上原価 = 売上高 − 売上総利益。売上総利益が取れない場合 DIO/DPO/CCC は nil。
func applyWorkingCapitalAndCCCToYears(_ years: inout [YearEntry]) {
    for i in 0..<years.count {
        let cd = years[i].calculatedData
        let rd = years[i].rawData

        // 運転資本（3要素すべて揃う場合のみ）
        if cd.workingCapital == nil,
           let ar = cd.accountsReceivable,
           let inv = cd.inventory,
           let ap = cd.accountsPayable {
            years[i].calculatedData.workingCapital = ar + inv - ap
        }

        // DSO: 売掛金 ÷ 売上高 × 365
        if cd.dso == nil, let ar = cd.accountsReceivable,
           let sales = rd.sales, sales > 0 {
            years[i].calculatedData.dso = ar / sales * Financial.daysInYear
        }

        // 売上原価 = 売上高 − 売上総利益
        guard let sales = rd.sales, let gp = cd.grossProfit else { continue }
        let cogs = sales - gp
        guard cogs > 0 else { continue }

        // DIO: 棚卸資産 ÷ 売上原価 × 365
        if cd.dio == nil, let inv = cd.inventory {
            years[i].calculatedData.dio = inv / cogs * Financial.daysInYear
        }
        // DPO: 買掛金 ÷ 売上原価 × 365
        if cd.dpo == nil, let ap = cd.accountsPayable {
            years[i].calculatedData.dpo = ap / cogs * Financial.daysInYear
        }
        // CCC = DSO + DIO − DPO（3要素すべて揃う場合のみ）
        if cd.ccc == nil,
           let dso = years[i].calculatedData.dso,
           let dio = years[i].calculatedData.dio,
           let dpo = years[i].calculatedData.dpo {
            years[i].calculatedData.ccc = dso + dio - dpo
        }
    }
}

// MARK: - ROE DuPont

/// 年次データに ROE のデュポン3要素（純利益率・総資産回転率・財務レバレッジ）の水準を付与する。
/// 前年差の要因分解は持たない（2026-10-28 廃止）。
///
/// TotalAssets・親会社持分が設定済みであることを前提とする。
func applyRoeDuPontToYears(_ years: inout [YearEntry]) {
    for i in 0..<years.count {
        let np = years[i].rawData.np
        let sales = years[i].rawData.sales
        let totalAssets = years[i].calculatedData.totalAssets
        // レバレッジの分母は ROE と同じ期末の親会社持分（純利益率 × 回転率 × レバレッジ = ROE）。
        let netAssets = years[i].rawData.parentEquity

        guard let npV = np, let salesV = sales, let taV = totalAssets, let naV = netAssets,
              salesV != 0, taV != 0, naV > 0 else { continue }

        if years[i].calculatedData.netMargin == nil {
            years[i].calculatedData.netMargin = (npV / salesV) * 100.0
        }
        if years[i].calculatedData.assetTurnover == nil {
            years[i].calculatedData.assetTurnover = salesV / taV
        }
        if years[i].calculatedData.financialLeverage == nil {
            years[i].calculatedData.financialLeverage = taV / naV
        }
    }
}
