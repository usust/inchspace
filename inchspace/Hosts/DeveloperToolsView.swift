import SwiftUI

struct DeveloperToolsView: View {
    @State private var showsHosts = false

    var body: some View {
        if showsHosts {
            HostsView(onBack: { showsHosts = false })
        } else {
            VStack(spacing: 0) {
                AppFeatureTitle("开发工具")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appFeatureHeaderBackground()

                VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                    Button { showsHosts = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "network")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            Text("Hosts 管理")
                            Text("/etc/hosts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appSurface()
                    .help("查看和管理本机 /etc/hosts")
                }
                .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .leading)
                .padding(AppLayout.pagePadding)
                .frame(maxWidth: .infinity)
                Spacer()
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
