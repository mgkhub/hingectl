import Foundation
import HingeCtlCore
import Observation

/// デバイス一覧と、選択中のデバイス。一覧は一定間隔で取り直す(接続状態の変化が分かる)。
@MainActor @Observable
public final class DeviceStore {
    public private(set) var entries: [DeviceEntry] = []
    public private(set) var listError: String?
    /// 取得処理が実行中か(自動ポーリング・手動更新共通の排他)
    public private(set) var isRefreshing = false
    /// 手動リフレッシュ中か(UI のボタン disabled 用)
    public private(set) var isManualRefreshing = false
    /// 初回の一覧取得が完了したか
    public private(set) var hasLoaded = false
    public private(set) var detail: DeviceDetailStore?
    public var selectedID: String? {
        didSet { if selectedID != oldValue { selectionChanged() } }
    }

    public let log: AppLog
    private let backend: any HingeBackend
    private var pollTask: Task<Void, Never>?
    private var activeRefreshTask: Task<Void, Never>?

    public init(backend: any HingeBackend, log: AppLog) {
        self.backend = backend
        self.log = log
    }

    /// 手動で一覧を取り直す(ボタンを disabled にして完了を待つ)。
    public func manualRefresh() async {
        isManualRefreshing = true
        defer { isManualRefreshing = false }
        await refresh()
    }

    /// 一覧を取り直す。選択中のデバイスの状態も更新する。一覧から消えたデバイスは、選択を外す。
    /// 既に取得処理が走っている場合は、その完了を待つ。
    public func refresh() async {
        if let ongoing = activeRefreshTask {
            await ongoing.value
            return
        }
        let task = Task { @MainActor in
            isRefreshing = true
            defer {
                isRefreshing = false
                hasLoaded = true
                activeRefreshTask = nil
            }
            do {
                let latest = try await backend.listDevices()
                entries = latest
                listError = nil
                if let selectedID {
                    if let current = latest.first(where: { $0.id == selectedID }) {
                        detail?.update(entry: current)
                    } else {
                        self.selectedID = nil
                    }
                }
            } catch {
                let message = DeviceDetailStore.message(error)
                // 同じ失敗を、一覧の更新のたびに、ログへ積まない
                if listError != message { log.append(.error, "Cannot list devices: \(message)") }
                listError = message
            }
        }
        activeRefreshTask = task
        await task.value
    }

    /// 一定間隔で一覧を取り直す(2 回目以降の開始は、何もしない)。
    public func startPolling(every interval: Duration = .seconds(5)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func selectionChanged() {
        detail?.disconnect()
        detail = nil
        guard let selectedID, let entry = entries.first(where: { $0.id == selectedID }) else { return }
        let store = DeviceDetailStore(entry: entry, backend: backend, log: log)
        detail = store
        Task { await store.connect() }
    }
}
