import SwiftUI

/// スクロール末尾用。バージョンを置く。
struct VersionMarkFooter: View {
    var body: some View {
        Text(Self.versionLine)
            .font(.subheadline)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.bottom, 12)
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
