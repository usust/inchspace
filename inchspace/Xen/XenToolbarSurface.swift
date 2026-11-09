import SwiftUI

struct XenToolbarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if reduceTransparency || contrast == .increased {
                    RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .controlBackgroundColor))
                        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color(nsColor: .separatorColor)) }
                }
            }
            .glassEffect(reduceTransparency || contrast == .increased ? .identity : .regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }
}
