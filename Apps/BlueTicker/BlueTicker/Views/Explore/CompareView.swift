import SwiftUI

/// 比較タブから push する画面。銘柄は `CompanyRef` で積む。
enum CompareRoute: Hashable {
    case group(String)
}

/// 比較タブ。公開している業種だけを並べ、選ぶとその業種のランキングへ進む。
struct CompareView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("比較したい業種を選択")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(BenchmarkCatalog.groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Divider().overlay(Color.white.opacity(0.08))
                        }
                        NavigationLink(value: CompareRoute.group(group.id)) {
                            HStack(spacing: 12) {
                                Image(systemName: group.symbol)
                                    .font(.title3)
                                    .frame(width: 36, height: 36)
                                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .accessibilityHidden(true)
                                Text(group.title)
                                    .font(.headline)
                                    .foregroundStyle(Theme.text)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.idleTab)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.cardContentInset)
                .bltCardSurface()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            VersionMarkFooter()
        }
        .bltChrome("比較")
    }
}
