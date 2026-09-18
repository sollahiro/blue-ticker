import SwiftUI

struct BrandMark: View {
    var height: CGFloat = 28

    var body: some View {
        Image("BBMark")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("Blue Ticker")
    }
}

/// スクロール末尾用。B マークの下にバージョンを置く。
struct VersionMarkFooter: View {
    var body: some View {
        VStack(spacing: 12) {
            BrandMark(height: 44)
            Text(Self.versionLine)
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    static var versionLine: String {
        let short =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty {
            return "バージョン \(short) (ビルド \(build))"
        }
        return "バージョン \(short)"
    }
}

