import SwiftUI

enum AppLayout {
    static let featureHeaderHorizontalPadding: CGFloat = 24
    static let featureHeaderVerticalPadding: CGFloat = 15
    static let featureHeaderSpacing: CGFloat = 10
}

struct AppFeatureTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    func appFeatureHeaderBackground(opacity: Double = 0.56) -> some View {
        padding(.horizontal, AppLayout.featureHeaderHorizontalPadding)
            .padding(.vertical, AppLayout.featureHeaderVerticalPadding)
            .background(.ultraThinMaterial.opacity(opacity))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.055))
                    .frame(height: 1)
            }
    }
}
