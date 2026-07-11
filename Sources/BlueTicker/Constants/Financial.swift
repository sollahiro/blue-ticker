enum Financial {
    /// HTML 表の列見出し等の小さい数値を除外する閾値（百万円単位 = 2 億円）。
    static let htmlTableMinAbsMillionYen: Double = 200

    static let percent: Double = 100
    static let millionYen: Double = 1_000_000
    static let daysInYear: Double = 365
    static let bpsPerShareMinValue: Double = 1.0
    /// 実効税率が取得できない場合の NOPAT フォールバック税率。
    static let nopatFallbackTaxRate: Double = 0.3
    /// NOPAT 計算で実効税率をクランプする下限（異常に低い税率を弾く）。
    static let nopatMinNormalTaxRate: Double = 0.2
    /// NOPAT 計算で実効税率をクランプする上限（異常に高い税率を弾く）。
    static let nopatMaxNormalTaxRate: Double = 0.45
    static let bpsSplitAdjustmentRelTolerance: Double = 0.01
}
