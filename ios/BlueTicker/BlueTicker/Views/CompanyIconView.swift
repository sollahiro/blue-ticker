import SwiftUI

/// 企業アイコン(`icon_url`)の表示。未格納・取得失敗時は社名の頭文字を表示する(`company_icons`は
/// R2格納済みfaviconのバッチlookupのため、null/失敗はエラーではなく通常状態)。
struct CompanyIconView: View {
    var url: URL?
    var name: String
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        // 白背景で統一する: favicon には白背景込みのものと透過マークのみのものが混在しており、
        // 統一しないと一覧内で見た目がバラつく(ユーザー指示)。ダークモードでも白固定。
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
    }

    private var placeholder: some View {
        Text(name.prefix(1))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
