import SwiftUI
import UIKit

enum Theme {
    /// 指標の黒（`control`）より白寄りのグレー。紺はやめる。
    static let shell = Color(red: 0.47, green: 0.49, blue: 0.52)
    static let elevated = Color(red: 0.38, green: 0.40, blue: 0.43)
    static let text = Color(red: 0.98, green: 0.98, blue: 0.99)
    static let textMuted = Color(red: 0.86, green: 0.87, blue: 0.89)
    static let accent = Color(red: 0.35, green: 0.70, blue: 0.95)
    static let idleTab = Color(red: 0.40, green: 0.42, blue: 0.45)
    /// 指標スライダー。シェルより黒寄り。
    static let control = Color(red: 16 / 255, green: 20 / 255, blue: 26 / 255)
    /// 銘柄カード。条件検索の指標と同じ黒。
    static let card = control
    static let positive = Color(red: 0.30, green: 0.62, blue: 0.92)
    static let negative = Color(red: 0.88, green: 0.32, blue: 0.36)
    static let ratioGreen = Color(red: 0.28, green: 0.78, blue: 0.42)
    static let margin = Color(red: 0.35, green: 0.78, blue: 0.82)

    static let bandLow = SIMD3<Double>(0.95, 0.08, 0.08)
    static let bandMid = SIMD3<Double>(0.98, 0.82, 0.12)
    static let bandHigh = SIMD3<Double>(0.18, 0.78, 0.28)

    static var bandLowColor: Color { color(bandLow) }
    static var bandMidColor: Color { color(bandMid) }
    static var bandHighColor: Color { color(bandHigh) }

    static func applyChrome() {
        let textColor = UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1)
        let muted = UIColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1)
        let shell = UIColor(red: 0.47, green: 0.49, blue: 0.52, alpha: 1)
        let elevated = UIColor(red: 0.38, green: 0.40, blue: 0.43, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = shell
        bar.titleTextAttributes = attrs
        bar.largeTitleTextAttributes = attrs
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        UINavigationBar.appearance().tintColor = textColor
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundColor = .clear
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().unselectedItemTintColor = muted
        UITabBar.appearance().tintColor = UIColor(red: 0.35, green: 0.70, blue: 0.95, alpha: 1)
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).defaultTextAttributes = attrs
        UISearchBar.appearance().tintColor = textColor
        UINavigationBar.appearance().prefersLargeTitles = false
        UITableView.appearance().backgroundColor = shell
        UICollectionView.appearance().backgroundColor = shell
        UITableViewCell.appearance().backgroundColor = elevated
        UITableView.appearance().sectionHeaderTopPadding = 0
    }

    static func sectorColor(_ sector: String) -> Color {
        switch sector {
        case "建設業":
            return Color(red: 0.70, green: 0.28, blue: 0.32)
        case "サービス業":
            return Color(red: 0.35, green: 0.52, blue: 0.68)
        case "電気機器":
            return Color(red: 0.22, green: 0.48, blue: 0.62)
        case "食料品":
            return Color(red: 0.22, green: 0.42, blue: 0.72)
        case "化学":
            return Color(red: 0.22, green: 0.55, blue: 0.62)
        default:
            let hash = abs(sector.hashValue)
            return Color(
                hue: Double(hash % 360) / 360.0,
                saturation: 0.45,
                brightness: 0.48
            )
        }
    }

    static func bandColor(quality: Double) -> Color {
        let q = min(max(quality, 0), 1)
        if q <= 0.5 {
            return color(mix(bandLow, bandMid, t: q / 0.5))
        }
        return color(mix(bandMid, bandHigh, t: (q - 0.5) / 0.5))
    }

    static func color(_ rgb: SIMD3<Double>) -> Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double) -> SIMD3<Double> {
        let u = min(max(t, 0), 1)
        return a + (b - a) * u
    }
}

enum MetricBand {
    case none
    /// 値が大きいほど優良。`lowBelow` 未満が Low、`midFrom...midTo` が Mid、`highFrom` 以上が High。
    case higherBetter(lowBelow: Double, midFrom: Double, midTo: Double, highFrom: Double)
    /// 値が小さいほど優良。`highBelow` 未満が High、`midFrom...midTo` が Mid、`lowFrom` 以上が Low。
    case lowerBetter(highBelow: Double, midFrom: Double, midTo: Double, lowFrom: Double)
    /// 閾値未満は黄、以上は緑。
    case yellowThenGreen(greenFrom: Double)

    func quality(_ value: Double) -> Double {
        switch self {
        case .none:
            return 0.5
        case .yellowThenGreen(let greenFrom):
            return value >= greenFrom ? 1 : 0.5
        case .higherBetter(let lowBelow, let midFrom, let midTo, let highFrom):
            if value < lowBelow { return 0 }
            if value >= highFrom { return 1 }
            if value < midFrom {
                return 0.5 * (value - lowBelow) / max(midFrom - lowBelow, .ulpOfOne)
            }
            if value <= midTo { return 0.5 }
            return 0.5 + 0.5 * (value - midTo) / max(highFrom - midTo, .ulpOfOne)
        case .lowerBetter(let highBelow, let midFrom, let midTo, let lowFrom):
            if value < highBelow { return 1 }
            if value >= lowFrom { return 0 }
            if value >= midFrom && value <= midTo { return 0.5 }
            if value < midFrom {
                return 1 - 0.5 * (value - highBelow) / max(midFrom - highBelow, .ulpOfOne)
            }
            return 0.5 - 0.5 * (value - midTo) / max(lowFrom - midTo, .ulpOfOne)
        }
    }

    func color(for value: Double) -> Color {
        switch self {
        case .none:
            return Theme.accent
        default:
            return Theme.bandColor(quality: quality(value))
        }
    }
}

enum TSESector {
    static let catalog: [String] = [
        "水産・農林業", "鉱業", "建設業", "食料品", "繊維製品", "パルプ・紙", "化学",
        "医薬品", "石油・石炭製品", "ゴム製品", "ガラス・土石製品", "鉄鋼", "非鉄金属",
        "金属製品", "機械", "電気機器", "輸送用機器", "精密機器", "その他製品",
        "電気・ガス業", "陸運業", "海運業", "空運業", "倉庫・運輸関連業", "情報・通信業",
        "卸売業", "小売業", "銀行業", "証券、商品先物取引業", "保険業", "その他金融業",
        "不動産業", "サービス業",
    ]
}

extension View {
    func bltChrome() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.shell)
            .foregroundStyle(Theme.text)
            .tint(Theme.accent)
            .toolbarBackground(Theme.shell, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
            .scrollEdgeEffectHidden(true, for: .top)
    }
}

