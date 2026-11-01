import HingeCtlAppKit
import SwiftUI

struct RootView: View {
    @Bindable var store: DeviceStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let detail = store.detail {
                DeviceDetailView(detail: detail, log: store.log)
                    .id(detail.entry.id)
            } else {
                ContentUnavailableView(Strings.selectDevice, systemImage: "iphone")
            }
        }
    }
}
