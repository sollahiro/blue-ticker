import SwiftUI
import UIKit

/// 数直線上の 2 ハンドルで範囲を選ぶ。`values` は `[下限, 上限]`。
struct DualRangeSlider: View {
    var rangeMin: Double
    var rangeMax: Double
    var step: Double
    @Binding var values: [Double]
    var formatValue: (Double) -> String
    var band: MetricBand = .none

    private let handleSize: CGFloat = 28
    private let hitSize: CGFloat = 44
    private let trackHeight: CGFloat = 6
    private let valueHeight: CGFloat = 16
    private let labelGap: CGFloat = 8

    private var span: Double { max(rangeMax - rangeMin, step) }

    private var lower: Double {
        snapped(values.count > 0 ? values[0] : rangeMin)
    }

    private var upper: Double {
        snapped(values.count > 1 ? values[1] : rangeMax)
    }

    private var controlHeight: CGFloat { hitSize + valueHeight + 4 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackY = geo.size.height - hitSize / 2
            let lowerX = x(for: lower, width: width)
            let upperX = x(for: upper, width: width)
            let lowerText = formatValue(lower)
            let upperText = formatValue(upper)
            let maxLabel = max((width - labelGap) / 2, 32)
            let lowerWidth = min(measuredWidth(lowerText), maxLabel)
            let upperWidth = min(measuredWidth(upperText), maxLabel)
            let labels = labelCenters(
                lowerX: lowerX,
                upperX: upperX,
                lowerWidth: lowerWidth,
                upperWidth: upperWidth,
                totalWidth: width
            )

            ZStack {
                Capsule()
                    .fill(LinearGradient(
                        stops: trackStops,
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .opacity(0.4)
                    .frame(width: width, height: trackHeight)
                    .position(x: width / 2, y: trackY)
                    .allowsHitTesting(false)

                Capsule()
                    .fill(LinearGradient(
                        colors: [band.color(for: lower), band.color(for: upper)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(upperX - lowerX, 0), height: trackHeight)
                    .position(x: (lowerX + upperX) / 2, y: trackY)
                    .allowsHitTesting(false)

                valueLabel(lowerText, color: band.color(for: lower), width: lowerWidth)
                    .position(x: labels.lower, y: valueHeight / 2)
                    .allowsHitTesting(false)
                valueLabel(upperText, color: band.color(for: upper), width: upperWidth)
                    .position(x: labels.upper, y: valueHeight / 2)
                    .allowsHitTesting(false)

                handle(isLower: true)
                    .position(x: lowerX, y: trackY)
                    .allowsHitTesting(false)
                handle(isLower: false)
                    .position(x: upperX, y: trackY)
                    .allowsHitTesting(false)

                DualRangeSliderHitOverlay(
                    lowerX: lowerX,
                    upperX: upperX,
                    trackY: trackY,
                    hitRadius: hitSize / 2,
                    rangeMin: rangeMin,
                    rangeMax: rangeMax,
                    step: step,
                    handleSize: handleSize,
                    sliderWidth: width,
                    lower: lower,
                    upper: upper,
                    onChange: { lo, hi in publish(lo, hi) }
                )
                .frame(width: width, height: geo.size.height)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(lowerText)から\(upperText)")
        }
        .frame(height: controlHeight)
        .onAppear { publish(lower, upper) }
    }

    private var trackStops: [Gradient.Stop] {
        let steps = 12
        return (0...steps).map { index in
            let t = Double(index) / Double(steps)
            let value = rangeMin + t * span
            return Gradient.Stop(color: band.color(for: value), location: CGFloat(t))
        }
    }

    private func handle(isLower: Bool) -> some View {
        let value = isLower ? lower : upper
        let fill = band.color(for: value)
        return Circle()
            .fill(fill)
            .shadow(color: fill.opacity(0.45), radius: 3, y: 1)
            .frame(width: handleSize, height: handleSize)
            .accessibilityLabel(isLower ? "下限" : "上限")
            .accessibilityValue(formatValue(value))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? step : -step
                if isLower {
                    publish(min(lower + delta, upper), upper)
                } else {
                    publish(lower, max(upper + delta, lower))
                }
            }
    }

    private func valueLabel(_ text: String, color: Color, width: CGFloat) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: width, height: valueHeight)
            .accessibilityHidden(true)
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        DualRangeSliderLayout.x(
            for: value,
            rangeMin: rangeMin,
            span: span,
            handleSize: handleSize,
            width: width
        )
    }

    private func snapped(_ value: Double) -> Double {
        DualRangeSliderLayout.snapped(
            value, rangeMin: rangeMin, rangeMax: rangeMax, step: step)
    }

    private func publish(_ newLower: Double, _ newUpper: Double) {
        let lo = snapped(min(newLower, newUpper))
        let hi = snapped(max(newLower, newUpper))
        let next = [lo, hi]
        if values != next {
            values = next
        }
    }

    private func measuredWidth(_ text: String) -> CGFloat {
        let base = UIFont.preferredFont(forTextStyle: .caption2)
        let font = UIFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }

    private func labelCenters(
        lowerX: CGFloat,
        upperX: CGFloat,
        lowerWidth: CGFloat,
        upperWidth: CGFloat,
        totalWidth: CGFloat
    ) -> (lower: CGFloat, upper: CGFloat) {
        let loHalf = lowerWidth / 2
        let hiHalf = upperWidth / 2
        var lo = min(max(lowerX, loHalf), totalWidth - loHalf)
        var hi = min(max(upperX, hiHalf), totalWidth - hiHalf)
        let overlap = (lo + loHalf + labelGap) - (hi - hiHalf)
        if overlap > 0 {
            lo -= overlap / 2
            hi += overlap / 2
            if lo < loHalf {
                hi += loHalf - lo
                lo = loHalf
            }
            if hi > totalWidth - hiHalf {
                lo -= hi - (totalWidth - hiHalf)
                hi = totalWidth - hiHalf
                lo = max(lo, loHalf)
            }
        }
        return (lo, hi)
    }
}

private enum DualRangeSliderLayout {
    static func x(
        for value: Double,
        rangeMin: Double,
        span: Double,
        handleSize: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        let usable = max(width - handleSize, 1)
        return handleSize / 2 + CGFloat((value - rangeMin) / span) * usable
    }

    static func value(
        forX rawX: CGFloat,
        rangeMin: Double,
        rangeMax: Double,
        step: Double,
        handleSize: CGFloat,
        width: CGFloat
    ) -> Double {
        let span = max(rangeMax - rangeMin, step)
        let usable = max(width - handleSize, 1)
        let ratio = Double((rawX - handleSize / 2) / usable)
        return snapped(rangeMin + min(max(ratio, 0), 1) * span,
                       rangeMin: rangeMin, rangeMax: rangeMax, step: step)
    }

    static func snapped(
        _ value: Double,
        rangeMin: Double,
        rangeMax: Double,
        step: Double
    ) -> Double {
        let clamped = min(max(value, rangeMin), rangeMax)
        guard step > 0 else { return clamped }
        let steps = ((clamped - rangeMin) / step).rounded()
        return min(max(rangeMin + steps * step, rangeMin), rangeMax)
    }
}

/// ハンドル上の横ドラッグだけ取る。縦は Form へ渡し、重なり時は動ける側を選ぶ。
private struct DualRangeSliderHitOverlay: UIViewRepresentable {
    var lowerX: CGFloat
    var upperX: CGFloat
    var trackY: CGFloat
    var hitRadius: CGFloat
    var rangeMin: Double
    var rangeMax: Double
    var step: Double
    var handleSize: CGFloat
    var sliderWidth: CGFloat
    var lower: Double
    var upper: Double
    var onChange: (Double, Double) -> Void

    func makeUIView(context: Context) -> DualRangeSliderHitView {
        DualRangeSliderHitView()
    }

    func updateUIView(_ uiView: DualRangeSliderHitView, context: Context) {
        uiView.lowerX = lowerX
        uiView.upperX = upperX
        uiView.trackY = trackY
        uiView.hitRadius = hitRadius
        uiView.rangeMin = rangeMin
        uiView.rangeMax = rangeMax
        uiView.step = step
        uiView.handleSize = handleSize
        uiView.sliderWidth = sliderWidth
        uiView.lower = lower
        uiView.upper = upper
        uiView.onChange = onChange
    }
}

private final class DualRangeSliderHitView: UIView, UIGestureRecognizerDelegate {
    var lowerX: CGFloat = 0
    var upperX: CGFloat = 0
    var trackY: CGFloat = 0
    var hitRadius: CGFloat = 22
    var rangeMin: Double = 0
    var rangeMax: Double = 1
    var step: Double = 1
    var handleSize: CGFloat = 28
    var sliderWidth: CGFloat = 1
    var lower: Double = 0
    var upper: Double = 1
    var onChange: ((Double, Double) -> Void)?

    private enum Handle {
        case lower
        case upper
    }

    private var active: Handle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isOpaque = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        nearHandle(point)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: self)
        guard abs(velocity.x) >= abs(velocity.y) else { return false }
        return nearHandle(pan.location(in: self))
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let x = pan.location(in: self).x
        switch pan.state {
        case .began:
            active = pickHandle(at: x, velocityX: pan.velocity(in: self).x)
            apply(x)
        case .changed:
            apply(x)
        default:
            active = nil
        }
    }

    private func apply(_ x: CGFloat) {
        guard let active else { return }
        let next = DualRangeSliderLayout.value(
            forX: x,
            rangeMin: rangeMin,
            rangeMax: rangeMax,
            step: step,
            handleSize: handleSize,
            width: sliderWidth
        )
        switch active {
        case .lower:
            onChange?(min(next, upper), upper)
        case .upper:
            onChange?(lower, max(next, lower))
        }
    }

    private func nearHandle(_ point: CGPoint) -> Bool {
        near(point, handleX: lowerX) || near(point, handleX: upperX)
    }

    private func near(_ point: CGPoint, handleX: CGFloat) -> Bool {
        abs(point.x - handleX) <= hitRadius && abs(point.y - trackY) <= hitRadius
    }

    private func pickHandle(at x: CGFloat, velocityX: CGFloat) -> Handle {
        let nearLower = abs(x - lowerX) <= hitRadius
        let nearUpper = abs(x - upperX) <= hitRadius
        if nearLower && nearUpper {
            if lower <= rangeMin && upper <= rangeMin {
                return .upper
            }
            if lower >= rangeMax && upper >= rangeMax {
                return .lower
            }
            return velocityX < 0 ? .lower : .upper
        }
        if nearLower { return .lower }
        if nearUpper { return .upper }
        return abs(x - lowerX) <= abs(x - upperX) ? .lower : .upper
    }
}
