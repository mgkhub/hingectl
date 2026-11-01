import HingeCtlAppKit
import HingeCtlCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: DeviceStore

    var body: some View {
        List(selection: $store.selectedID) {
            ForEach(store.entries, id: \.id) { entry in
                DeviceRow(entry: entry)
                    .tag(entry.id)
                    // つながらない(経路が無い)デバイスは、選べない
                    .selectionDisabled(!entry.isConnected && !entry.isWakeable)
            }
        }
        .overlay {
            if store.entries.isEmpty {
                if let error = store.listError {
                    ContentUnavailableView("Cannot list devices", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if store.hasLoaded {
                    ContentUnavailableView(Strings.noDevices, systemImage: "iphone.slash", description: Text(Strings.noDevicesHint))
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button(Strings.refresh, systemImage: "arrow.clockwise") { Task { await store.manualRefresh() } }
                    .disabled(store.isManualRefreshing)
            }
        }
    }
}

private struct DeviceRow: View {
    let entry: DeviceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                Text(entry.name).font(.headline)
                if entry.isSimulator {
                    Text(Strings.simulator)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: Capsule())
                }
            }
            // 接続状態と OS(一覧に OS が無いデバイスは、接続状態だけ)
            Text([entry.connectionState.text, entry.osText].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.udid)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch entry.connectionState {
        case .connected: .green
        case .disconnected: .orange
        default: .gray
        }
    }
}
