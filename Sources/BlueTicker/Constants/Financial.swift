enum Financial {
    /// HTML 表の列見出し等の小さい数値を除外する閾値（百万円単位 = 2 億円）。
    static let htmlTableMinAbsMillionYen: Double = 200

    static let percent: Double = 100
    static let millionYen: Double = 1_000_000
    static let daysInYear: Double = 365
    static let bpsPerShareMinValue: Double = 1.0
    static let nopatFallbackTaxRate: Double = 0.35
    static let nopatMinNormalTaxRate: Double = 0.0
    static let nopatMaxNormalTaxRate: Double = 0.5
    static let bpsSplitAdjustmentRelTolerance: Double = 0.01
}
