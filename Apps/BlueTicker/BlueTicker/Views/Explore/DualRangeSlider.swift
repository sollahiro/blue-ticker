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
    private let trackHeight: CGFloat = 6
    private let valueHeight: CGFloat = 16
    private let labelGap: CGFloat = 8

    @State private var dragging: Handle?

    private enum Handle {
        case lower
        case upper
    }

    private var span: Double { max(rangeMax - rangeMin, step) }

    private var lower: Double {
        snapped(values.count > 0 ? values[0] : rangeMin)
    }

    private var upper: Double {
        snapped(values.count > 1 ? values[1] : rangeMax)
    }

    private var controlHeight: CGFloat { handleSize + valueHeight + 4 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackY = geo.size.height - handleSize / 2
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

                Capsule()
                    .fill(LinearGradient(
                        colors: [band.color(for: lower), band.color(for: upper)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(upperX - lowerX, 0), height: trackHeight)
                    .position(x: (lowerX + upperX) / 2, y: trackY)

                valueLabel(lowerText, color: band.color(for: lower), width: lowerWidth)
                    .position(x: labels.lower, y: valueHeight / 2)
                valueLabel(upperText, color: band.color(for: upper), width: upperWidth)
                    .position(x: labels.upper, y: valueHeight / 2)

                handle(isLower: true)
                    .position(x: lowerX, y: trackY)
                handle(isLower: false)
                    .position(x: upperX, y: trackY)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(dragGesture(width: width))
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

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let handle = dragging ?? nearestHandle(at: drag.startLocation.x, width: width)
                if dragging == nil {
                    dragging = handle
                }
                let next = value(forX: drag.location.x, width: width)
                switch handle {
                case .lower:
                    publish(min(next, upper), upper)
                case .upper:
                    publish(lower, max(next, lower))
                }
            }
            .onEnded { _ in
                dragging = nil
            }
    }

    private func nearestHandle(at rawX: CGFloat, width: CGFloat) -> Handle {
        let lowerX = x(for: lower, width: width)
        let upperX = x(for: upper, width: width)
        if abs(rawX - lowerX) == abs(rawX - upperX) {
            return rawX <= lowerX ? .lower : .upper
        }
        return abs(rawX - lowerX) < abs(rawX - upperX) ? .lower : .upper
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        let usable = max(width - handleSize, 1)
        return handleSize / 2 + CGFloat((value - rangeMin) / span) * usable
    }

    private func value(forX rawX: CGFloat, width: CGFloat) -> Double {
        let usable = max(width - handleSize, 1)
        let ratio = Double((rawX - handleSize / 2) / usable)
        return snapped(rangeMin + min(max(ratio, 0), 1) * span)
    }

    private func snapped(_ value: Double) -> Double {
        let clamped = min(max(value, rangeMin), rangeMax)
        guard step > 0 else { return clamped }
        let steps = ((clamped - rangeMin) / step).rounded()
        return min(max(rangeMin + steps * step, rangeMin), rangeMax)
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
