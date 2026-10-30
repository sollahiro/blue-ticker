import SwiftUI
import UIKit

enum Theme {
    /// 背景は黒。カードは濃いグレー。
    static let shell = Color(red: 0.03, green: 0.03, blue: 0.04)
    static let elevated = Color(red: 0.20, green: 0.21, blue: 0.22)
    static let text = Color(red: 0.98, green: 0.98, blue: 0.99)
    static let textMuted = Color(red: 0.70, green: 0.72, blue: 0.75)
    static let accent = Color(red: 0.35, green: 0.70, blue: 0.95)
    static let idleTab = Color(red: 0.35, green: 0.36, blue: 0.38)
    /// リスト行・コントロール背景。カードより黒寄り。
    static let control = Color(red: 0.08, green: 0.08, blue: 0.09)
    /// 銘柄カード・概要カード。背景から浮かぶ濃いグレー。
    static let card = Color(red: 0.13, green: 0.14, blue: 0.15)
    /// 銘柄ヘッダのアイコン（ナビゲーションバー左端、社名の左）。
    static let headerIconSize: CGFloat = 30
    /// ピル内側の水平余白。アイコン左と社名右に足す（カプセル自体の余白とは別）。
    static let headerPillHorizontalPadding: CGFloat = 14
    /// ピル内側の垂直余白。1行のときは隣接カプセルに近い高さになる。
    static let headerPillVerticalPadding: CGFloat = 5
    /// iOS 26 の inset grouped セクションに近い連続円弧。業種セクションの外側。
    static let groupedCornerRadius: CGFloat = 26
    /// セクション枠と見切れマスクのあいだ。内側半径は `groupedCornerRadius - groupedContentInset`。
    static let groupedContentInset: CGFloat = 12
    /// 銘柄カードの角。セクション枠と同じ連続円弧。
    static let cardCornerRadius: CGFloat = groupedCornerRadius
    /// カード内テキストの規定 padding。四辺同じ。内側の角丸マスクは掛けない。
    static let cardContentInset: CGFloat = groupedContentInset

    static var groupedInnerCornerRadius: CGFloat {
        max(groupedCornerRadius - groupedContentInset, 0)
    }
    static let positive = Color(red: 0.28, green: 0.78, blue: 0.42)
    static var sectorFill: Color { positive.opacity(0.22) }
    static let negative = Color(red: 0.92, green: 0.28, blue: 0.32)
    /// 条件検索「成長」ラベルのオレンジ。
    static let growthTint = Color(red: 0.98, green: 0.62, blue: 0.25)
    /// 条件検索「高CF」ラベルのティール。
    static let highCfTint = Color(red: 0.25, green: 0.80, blue: 0.75)
    /// 条件検索「改善」ラベルのゴールド。
    static let improvingTint = Color(red: 0.95, green: 0.78, blue: 0.25)
    /// 条件検索「高還元」ラベルのパープル。
    static let payoutTint = Color(red: 0.70, green: 0.55, blue: 0.95)
    static let ratioGreen = Color(red: 0.28, green: 0.78, blue: 0.42)

    static let bandLow = SIMD3<Double>(0.95, 0.08, 0.08)
    static let bandMid = SIMD3<Double>(0.98, 0.82, 0.12)
    static let bandHigh = SIMD3<Double>(0.28, 0.78, 0.42)

    static var bandLowColor: Color { color(bandLow) }
    static var bandMidColor: Color { color(bandMid) }
    static var bandHighColor: Color { color(bandHigh) }

    static func applyChrome() {
        let textColor = UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1)
        let muted = UIColor(red: 0.70, green: 0.72, blue: 0.75, alpha: 1)
        let shell = UIColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
        let elevated = UIColor(red: 0.20, green: 0.21, blue: 0.22, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]
        let bar = UINavigationBarAppearance()
        bar.configureWithTransparentBackground()
        bar.backgroundColor = .clear
        bar.shadowColor = .clear
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

    func quality(_ value: Double) -> Double {
        switch self {
        case .none:
            return 0.5
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

/// 業種は TOPIX-17 で見せる。API の `sector` は EDINET の東証 33 業種名のままなので、
/// 表示と業種フィルタはここで 17 業種に振り分け、検索には配下の 33 業種名を渡す。
enum TOPIX17Sector: String, CaseIterable, Identifiable, Hashable {
    case foods
    case energy
    case construction
    case materials
    case pharmaceutical
    case automobiles
    case steel
    case machinery
    case electronics
    case itServices
    case utilities
    case transportation
    case trading
    case retail
    case banks
    case financials
    case realEstate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .foods: "食品"
        case .energy: "エネルギー資源"
        case .construction: "建設・資材"
        case .materials: "素材・化学"
        case .pharmaceutical: "医薬品"
        case .automobiles: "自動車・輸送機"
        case .steel: "鉄鋼・非鉄"
        case .machinery: "機械"
        case .electronics: "電機・精密"
        case .itServices: "情報通信・サービス他"
        case .utilities: "電力・ガス"
        case .transportation: "運輸・物流"
        case .trading: "商社・卸売"
        case .retail: "小売"
        case .banks: "銀行"
        case .financials: "金融（除く銀行）"
        case .realEstate: "不動産"
        }
    }

    /// SF Symbols。
    var symbol: String {
        switch self {
        case .foods: "fork.knife"
        case .energy: "flame"
        case .construction: "hammer"
        case .materials: "flask"
        case .pharmaceutical: "pills"
        case .automobiles: "car"
        case .steel: "cube.fill"
        case .machinery: "gearshape.2"
        case .electronics: "cpu"
        case .itServices: "person.2"
        case .utilities: "bolt"
        case .transportation: "truck.box"
        case .trading: "globe.asia.australia"
        case .retail: "bag"
        case .banks: "building.columns"
        case .financials: "chart.line.uptrend.xyaxis"
        case .realEstate: "house"
        }
    }

    /// 配下の東証 33 業種。表記は API（EDINET コードリスト）に合わせる。
    var tseSectors: [String] {
        switch self {
        case .foods: ["水産・農林業", "食料品"]
        case .energy: ["鉱業", "石油・石炭製品"]
        case .construction: ["建設業", "ガラス・土石製品", "金属製品"]
        case .materials: ["繊維製品", "パルプ・紙", "化学"]
        case .pharmaceutical: ["医薬品"]
        case .automobiles: ["ゴム製品", "輸送用機器"]
        case .steel: ["鉄鋼", "非鉄金属"]
        case .machinery: ["機械"]
        case .electronics: ["電気機器", "精密機器"]
        case .itServices: ["情報・通信業", "サービス業", "その他製品"]
        case .utilities: ["電気・ガス業"]
        case .transportation: ["陸運業", "海運業", "空運業", "倉庫・運輸関連"]
        case .trading: ["卸売業"]
        case .retail: ["小売業"]
        case .banks: ["銀行業"]
        case .financials: ["証券、商品先物取引業", "保険業", "その他金融業"]
        case .realEstate: ["不動産業"]
        }
    }

    private static let byTSESector: [String: TOPIX17Sector] = {
        var map: [String: TOPIX17Sector] = [:]
        for group in allCases {
            for sector in group.tseSectors {
                map[sector] = group
            }
        }
        return map
    }()

    /// 33 業種名から引く。末尾の「業」の有無の揺れ（「倉庫・運輸関連業」など）も受ける。
    init?(tseSector: String) {
        let name = tseSector.trimmingCharacters(in: .whitespaces)
        if let group = Self.byTSESector[name] {
            self = group
        } else if name.hasSuffix("業"), let group = Self.byTSESector[String(name.dropLast())] {
            self = group
        } else if let group = Self.byTSESector[name + "業"] {
            self = group
        } else {
            return nil
        }
    }

    /// 33 業種名を 17 業種の表示名にする。振り分けられない名前（外国法人など）はそのまま返す。
    static func displayName(for tseSector: String) -> String {
        TOPIX17Sector(tseSector: tseSector)?.title ?? tseSector
    }
}

extension View {
    func bltChrome(_ title: String) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.shell)
            .foregroundStyle(Theme.text)
            .tint(Theme.accent)
            .navigationTitle(title)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
    }

    func bltCardSurface() -> some View {
        self
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
    }

    func bltCard() -> some View {
        self
            .bltCardSurface()
            .padding(.horizontal, Theme.cardContentInset)
            .padding(.top, Theme.cardContentInset)
    }

    func bltCardScroll() -> some View {
        self
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectHidden(true)
            .contentMargins(.all, 0, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bltCard()
    }
}

