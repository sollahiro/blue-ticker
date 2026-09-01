import SwiftUI

struct BrandMark: View {
    var body: some View {
        Image("BBMark")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(height: 28)
            .accessibilityLabel("Blue Ticker")
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

