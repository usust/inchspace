import SwiftUI

enum AppLayout {
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 24
    static let contentMaxWidth: CGFloat = 1120
    static let cardRadius: CGFloat = 18
    static let featureHeaderHorizontalPadding: CGFloat = 20
    static let featureHeaderVerticalPadding: CGFloat = 16
    static let featureHeaderSpacing: CGFloat = 12
}

enum AppMotion {
    static let feedback = Animation.easeOut(duration: 0.16)
    static let transition = Animation.spring(response: 0.28, dampingFraction: 0.9)
}

struct AppPageBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

struct AppFeatureTitle: View {
    let title: String
    let subtitle: String?
    let subtitleLineLimit: Int?

    init(_ title: String, subtitle: String? = nil, subtitleLineLimit: Int? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleLineLimit = subtitleLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AppFeatureHeaderModifier: ViewModifier {
    let opacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppLayout.featureHeaderHorizontalPadding)
            .padding(.vertical, AppLayout.featureHeaderVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(opacity * 0.35))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1 : 0.35))
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }
}

private struct AppSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1 : 0.4),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(contrast == .increased ? 0 : (colorScheme == .dark ? 0.12 : 0.035)), radius: 8, y: 3)
    }
}

/// Apply only to actionable cards; informational surfaces must not imply a click action.
struct AppCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, reduceMotion: reduceMotion)
    }

    private struct CardBody: View {
        let configuration: ButtonStyle.Configuration
        let reduceMotion: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: AppLayout.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: AppLayout.cardRadius)
                        .strokeBorder(
                            Color.accentColor.opacity(isEnabled && (isHovered || isFocused) ? (isFocused ? 1 : 0.55) : 0),
                            lineWidth: isFocused ? 2 : 1
                        )
                        .allowsHitTesting(false)
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.5)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : AppMotion.feedback, value: isHovered)
                .animation(reduceMotion ? nil : AppMotion.feedback, value: configuration.isPressed)
        }
    }
}

struct AppIconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    func appFeatureHeaderBackground(opacity: Double = 0.56) -> some View {
        modifier(AppFeatureHeaderModifier(opacity: opacity))
    }

    func appSurface(cornerRadius: CGFloat = AppLayout.cardRadius) -> some View {
        modifier(AppSurfaceModifier(cornerRadius: cornerRadius))
    }
}
