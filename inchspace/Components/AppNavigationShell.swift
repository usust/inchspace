import SwiftUI

struct AppNavigationShell<Detail: View>: View {
    @Binding var selection: SidebarDestination?
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $selection)
        } detail: {
            GeometryReader { geometry in
                // Page minimum sizes must not participate in the outer split view's sizing.
                detail()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
