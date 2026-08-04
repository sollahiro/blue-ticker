import SwiftUI

/// 立体的財務分析エクスプローラ(`docs/ios-app-concept.md`)。正面=結果/側面=推移/上面=ロジックの
/// 3面を、スワイプで面を回転させる操作で切り替える。3面は常に同じ分析対象(選択中の年度・項目)を指す。
struct CubeView: View {
    var company: CompanySearchResult
    var client: APIClient

    private enum Face { case front, side, top }

    @State private var waterfall: WaterfallResponse?
    @State private var errorMessage: String?
    @State private var isLoading = false

    @State private var face: Face = .front
    @State private var selectedYearIndex = 0
    @State private var selectedMetric: WaterfallMetric = .businessProfit
    @State private var flipAngle: Double = 0
    @State private var flipAxis: (x: CGFloat, y: CGFloat, z: CGFloat) = (0, 1, 0)

    var body: some View {
        VStack(spacing: 12) {
            if let waterfall, !waterfall.years.isEmpty {
                yearPicker(years: waterfall.years)
                faceIndicator

                faceContent(waterfall: waterfall)
                    .rotation3DEffect(
                        .degrees(flipAngle), axis: flipAxis, perspective: 0.3
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)

                Text("スワイプ: 左右=推移面 / 上=ロジック面")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if isLoading {
                ProgressView("読み込み中…")
            } else {
                ContentUnavailableView(
                    "データがありません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "waterfall データが未算出です。"))
            }
        }
        .padding()
        .navigationTitle(company.name)
        .task { await load() }
        .onAppear {
            // スクリーンショット検証用の一時的なデバッグフック(later removed)。
            switch ProcessInfo.processInfo.environment["BLT_DEBUG_SEED_FACE"] {
            case "side": face = .side
            case "top": face = .top
            default: break
            }
        }
    }

    // MARK: - データ取得

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            waterfall = try await client.waterfall(code: company.code)
        } catch {
            errorMessage = "取得に失敗しました: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - 年度セレクタ(正面用)

    private func yearPicker(years: [WaterfallYear]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(years.indices, id: \.self) { index in
                    let year = years[index]
                    Button(year.financialPeriod ?? year.fyEnd ?? "-") {
                        selectedYearIndex = index
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        index == selectedYearIndex ? Color.accentColor : Color(.tertiarySystemFill),
                        in: Capsule()
                    )
                    .foregroundStyle(index == selectedYearIndex ? .white : .primary)
                }
            }
        }
    }

    private var faceIndicator: some View {
        HStack(spacing: 16) {
            faceLabel("正面(結果)", isActive: face == .front)
            faceLabel("側面(推移)", isActive: face == .side)
            faceLabel("上面(ロジック)", isActive: face == .top)
        }
        .font(.caption)
    }

    private func faceLabel(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .fontWeight(isActive ? .bold : .regular)
    }

    // MARK: - 面の中身

    @ViewBuilder
    private func faceContent(waterfall: WaterfallResponse) -> some View {
        let year = waterfall.years[min(selectedYearIndex, waterfall.years.count - 1)]
        switch face {
        case .front:
            FrontFaceView(year: year) { metric in
                selectedMetric = metric
                rotate(to: .side, axis: (0, 1, 0))
            }
        case .side:
            SideFaceView(metric: selectedMetric, response: waterfall)
        case .top:
            TopFaceView(year: year) { metric in
                selectedMetric = metric
                rotate(to: .side, axis: (0, 1, 0))
            }
        }
    }

    // MARK: - 回転操作

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    if face == .front, dx < 0 { rotate(to: .side, axis: (0, 1, 0)) }
                    else if face == .side, dx > 0 { rotate(to: .front, axis: (0, 1, 0)) }
                } else {
                    if face == .front, dy < 0 { rotate(to: .top, axis: (1, 0, 0)) }
                    else if face == .top, dy > 0 { rotate(to: .front, axis: (1, 0, 0)) }
                }
            }
    }

    private func rotate(to newFace: Face, axis: (x: CGFloat, y: CGFloat, z: CGFloat)) {
        guard newFace != face else { return }
        flipAxis = axis
        withAnimation(.easeIn(duration: 0.18)) {
            flipAngle = 90
        } completion: {
            face = newFace
            flipAngle = -90
            withAnimation(.easeOut(duration: 0.18)) {
                flipAngle = 0
            }
        }
    }
}
