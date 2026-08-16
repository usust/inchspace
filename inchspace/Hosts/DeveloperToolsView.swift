import SwiftUI

struct DeveloperToolsView: View {
    @State private var showsHosts = false

    var body: some View {
        if showsHosts {
            HostsView(onBack: { showsHosts = false })
        } else {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.075), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .background(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("开发工具").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("常用的本机开发与网络配置工具").foregroundStyle(.secondary)
                    }
                    Button { showsHosts = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "network").font(.system(size: 25)).foregroundStyle(Color.accentColor).frame(width: 54, height: 54).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                            VStack(alignment: .leading, spacing: 4) { Text("Hosts 管理").font(.headline); Text("查看和管理本机 /etc/hosts").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.18)) }.frame(maxWidth: 430)
                    Spacer()
                }.padding(34).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}
