// 財務ウォーターフォール分解ユーティリティ
// Python の blue_ticker/utils/{roe_waterfall,roic_waterfall,operating_profit_change}.py 相当

import Foundation

private let financialOPLabels: Set<String> = ["経常利益", "事業利益"]
private let financialSalesLabels: Set<String> = ["経常収益"]

// MARK: - Operating Profit Waterfall

/// 年次データに営業利益前年差分解（BusinessProfit, SGA, 3要因）を付与する。
///
/// 前提: years が fyEnd 順に既ソートされていること。入力順は問わない。
func applyOperatingProfitChangeToYears(_ years: inout [YearEntry]) {
    // Step 1: SGA・BusinessProfit を補完する
    for i in 0..<years.count {
        let cd = years[i].calculatedData
        let rd = years[i].rawData

        // SGA 未設定の場合: GrossProfit - OP で導出
        if cd.sellingGeneralAdministrativeExpenses == nil {
            if let gp = cd.grossProfit, let op = rd.op {
                years[i].calculatedData.sellingGeneralAdministrativeExpenses = gp - op
            }
        }

        // BusinessProfit 未設定の場合
        if cd.businessProfit == nil {
            let sga = years[i].calculatedData.sellingGeneralAdministrativeExpenses
            if let base = profitBase(cd, rd), let s = sga {
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
              let curSGA = curCD.sellingGeneralAdministrativeExpenses,
              let priorSGA = priorCD.sellingGeneralAdministrativeExpenses,
              curSales > 0, priorSales > 0 else { continue }

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

// MARK: - ROIC Waterfall

/// 年次データに ROIC 前年差分解（NOPATMargin・投下資本回転率の2要因）を付与する。
///
/// NOPATMargin と InvestedCapitalTurnover は IndividualAnalyzer.processDocument で
/// 既に設定済みであることを前提とする。
func applyRoicWaterfallToYears(_ years: inout [YearEntry]) {
    let sortedIndices = years.indices.sorted { (years[$0].fyEnd ?? "") < (years[$1].fyEnd ?? "") }

    for k in 1..<sortedIndices.count {
        let curIdx = sortedIndices[k]
        let priorIdx = sortedIndices[k - 1]

        guard years[curIdx].calculatedData.roicDelta == nil else { continue }

        let curCD = years[curIdx].calculatedData
        let priorCD = years[priorIdx].calculatedData

        // 金融機関（経常利益ベース）はスキップ
        if let label = curCD.opLabel, financialOPLabels.contains(label) { continue }

        guard let roicCurr = curCD.roic,
              let roicPrev = priorCD.roic,
              let nmCurr = curCD.nopatMargin,
              let nmPrev = priorCD.nopatMargin,
              let tCurr = curCD.investedCapitalTurnover,
              let tPrev = priorCD.investedCapitalTurnover else { continue }

        // nopatMargin は % 単位、turnover は倍率
        // marginEffect = (nm_curr - nm_prev) / 100 * t_prev * 100 = (nm_curr - nm_prev) * t_prev
        let roicDelta = roicCurr - roicPrev
        let marginEffect = (nmCurr - nmPrev) * tPrev
        let turnoverEffect = nmCurr * (tCurr - tPrev)

        years[curIdx].calculatedData.roicDelta = roicDelta
        years[curIdx].calculatedData.roicMarginEffect = marginEffect
        years[curIdx].calculatedData.roicTurnoverEffect = turnoverEffect
    }
}

// MARK: - ROE Waterfall

/// 年次データに ROE 前年差分解（デュポン3要因）を付与する。
///
/// TotalAssets・NetAssets が CalculatedData に設定済みであることを前提とする。
func applyRoeWaterfallToYears(_ years: inout [YearEntry]) {
    // Step 1: DuPont 構成要素を計算
    for i in 0..<years.count {
        let np = years[i].rawData.np
        let sales = years[i].rawData.sales
        let totalAssets = years[i].calculatedData.totalAssets
        let netAssets = years[i].calculatedData.netAssets

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

    // Step 2: 前年差を3要因に分解
    let sortedIndices = years.indices.sorted { (years[$0].fyEnd ?? "") < (years[$1].fyEnd ?? "") }

    for k in 1..<sortedIndices.count {
        let curIdx = sortedIndices[k]
        let priorIdx = sortedIndices[k - 1]

        guard years[curIdx].calculatedData.roeDelta == nil else { continue }

        let curCD = years[curIdx].calculatedData
        let priorCD = years[priorIdx].calculatedData

        guard let roeCurr = curCD.roe,
              let roePrev = priorCD.roe,
              let nmCurr = curCD.netMargin,
              let nmPrev = priorCD.netMargin,
              let atCurr = curCD.assetTurnover,
              let atPrev = priorCD.assetTurnover,
              let flCurr = curCD.financialLeverage,
              let flPrev = priorCD.financialLeverage else { continue }

        // netMargin は % 単位。チェーン分解式（ROIC と統一）:
        // nmEffect  = (nm_curr - nm_prev) / 100 * at_prev * fl_prev * 100 = (nm_curr - nm_prev) * at_prev * fl_prev
        // atEffect  = nm_curr / 100 * (at_curr - at_prev) * fl_prev * 100 = nm_curr * (at_curr - at_prev) * fl_prev
        // levEffect = nm_curr / 100 * at_curr * (fl_curr - fl_prev) * 100 = nm_curr * at_curr * (fl_curr - fl_prev)
        let roeDelta = roeCurr - roePrev
        let nmEffect = (nmCurr - nmPrev) * atPrev * flPrev
        let atEffect = nmCurr * (atCurr - atPrev) * flPrev
        let levEffect = nmCurr * atCurr * (flCurr - flPrev)

        years[curIdx].calculatedData.roeDelta = roeDelta
        years[curIdx].calculatedData.roeNetMarginEffect = nmEffect
        years[curIdx].calculatedData.roeAssetTurnoverEffect = atEffect
        years[curIdx].calculatedData.roeLeverageEffect = levEffect
    }
}
