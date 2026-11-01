import SwiftUI
import UIKit
import CoreMotion

// MARK: - Log Entry

struct EventLogItem: Identifiable {
    let id = UUID()
    let timestamp: Date
    let source: String
    let message: String

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        return formatter.string(from: timestamp)
    }

    var shortSource: String {
        switch source {
        case "CoreMotion": return "CM"
        case "UIHinge": return "UI"
        case "Orientation": return "ORI"
        default: return source
        }
    }
}

// MARK: - Main Model

@MainActor
final class HingeAnalyzerModel: ObservableObject {
    // CoreMotion (CMAngleManager)
    @Published var cmAngleDegrees: Float?
    @Published var cmMechanicalDegrees: Float?
    @Published var cmAvailable: Bool = false
    @Published var cmStatus: String = "Initializing..."

    // UIKit (UIHinge)
    @Published var uiHingeAvailable: Bool = false
    @Published var uiHingeStatus: UIHinge.Status = .unknown
    @Published var uiHingeAngleRad: CGFloat?
    @Published var uiHingeAngleDeg: Double?

    // Orientation & Display
    @Published var deviceOrientation: UIDeviceOrientation = .unknown
    @Published var interfaceOrientation: UIInterfaceOrientation = .unknown
    @Published var screenSummary: String = "Detecting..."
    @Published var screenScale: CGFloat = 1.0
    @Published var totalScreens: Int = 1

    // Event Logs
    @Published var logs: [EventLogItem] = []

    private var motionManager: AnyObject?

    init() {
        startCoreMotion()
        startOrientationMonitoring()
        updateDisplayInfo()
    }

    func addLog(source: String, message: String) {
        let item = EventLogItem(timestamp: Date(), source: source, message: message)
        logs.insert(item, at: 0)
        if logs.count > 40 {
            logs.removeLast()
        }
        NSLog("[HingeTest] [\(source)] \(message)")
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - CoreMotion (CMAngleManager)

    func startCoreMotion() {
        guard let managerClass = NSClassFromString("CMAngleManager") as? NSObject.Type else {
            cmStatus = "Unavailable"
            addLog(source: "CoreMotion", message: "CMAngleManager not available in runtime")
            return
        }

        let isAvailSel = NSSelectorFromString("isAvailable")
        if managerClass.responds(to: isAvailSel) {
            typealias BoolFn = @convention(c) (AnyObject, Selector) -> Bool
            let imp = managerClass.method(for: isAvailSel)
            let fn = unsafeBitCast(imp, to: BoolFn.self)
            if !fn(managerClass, isAvailSel) {
                cmStatus = "isAvailable=false"
                addLog(source: "CoreMotion", message: "CMAngleManager isAvailable returned false")
                return
            }
        }

        let mgr = managerClass.init()
        self.motionManager = mgr
        self.cmAvailable = true

        let startSel = NSSelectorFromString("startAngleUpdatesToQueue:handler:")
        if mgr.responds(to: startSel) {
            typealias StartFn = @convention(c) (AnyObject, Selector, OperationQueue, @escaping @convention(block) (AnyObject) -> Void) -> Void
            let imp = mgr.method(for: startSel)
            let fn = unsafeBitCast(imp, to: StartFn.self)
            fn(mgr, startSel, .main) { [weak self] angleObj in
                self?.handleCoreMotionUpdate(angleObj)
            }
            cmStatus = "Streaming"
            addLog(source: "CoreMotion", message: "Started CMAngle updates")
        } else {
            cmStatus = "Selector not found"
            addLog(source: "CoreMotion", message: "startAngleUpdates selector not found")
        }
    }

    private func handleCoreMotionUpdate(_ angleObj: AnyObject) {
        let sel = NSSelectorFromString("angleDegrees")
        let mechSel = NSSelectorFromString("mechanicalAngleDegrees")

        var deg: Float = 0
        var mechDeg: Float = 0

        typealias FloatFn = @convention(c) (AnyObject, Selector) -> Float

        if angleObj.responds(to: sel) {
            let imp = angleObj.method(for: sel)
            deg = unsafeBitCast(imp, to: FloatFn.self)(angleObj, sel)
        }
        if angleObj.responds(to: mechSel) {
            let imp = angleObj.method(for: mechSel)
            mechDeg = unsafeBitCast(imp, to: FloatFn.self)(angleObj, mechSel)
        }

        self.cmAngleDegrees = deg
        self.cmMechanicalDegrees = mechDeg

        let delta = deg - mechDeg
        addLog(source: "CoreMotion", message: String(format: "s:%.1f° m:%.1f° (Δ%+.1f°)", deg, mechDeg, delta))
    }

    // MARK: - UIKit (UIHinge)

    func handleUIHingeUpdate(_ hinge: UIHinge?) {
        guard let hinge = hinge else {
            uiHingeAvailable = false
            uiHingeAngleRad = nil
            uiHingeAngleDeg = nil
            uiHingeStatus = .unknown
            addLog(source: "UIHinge", message: "unavailable")
            return
        }

        uiHingeAvailable = true
        uiHingeStatus = hinge.status
        uiHingeAngleRad = hinge.angle

        let degrees = Double(hinge.angle) * 180.0 / .pi
        uiHingeAngleDeg = degrees

        let statusStr: String
        switch hinge.status {
        case .closed: statusStr = "closed(1)"
        case .partiallyOpen: statusStr = "part(2)"
        case .fullyOpen: statusStr = "open(3)"
        case .unknown: fallthrough
        @unknown default: statusStr = "unk(0)"
        }

        addLog(source: "UIHinge", message: String(format: "%@ %.1f° (%.3frad)", statusStr, degrees, hinge.angle))
    }

    // MARK: - Orientation & Display

    func startOrientationMonitoring() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        self.deviceOrientation = UIDevice.current.orientation

        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let newOri = UIDevice.current.orientation
                self.deviceOrientation = newOri
                self.updateDisplayInfo()
                self.addLog(source: "Orientation", message: "Dev: \(self.orientationName(newOri))")
            }
        }
    }

    func updateDisplayInfo() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let windowScene = scenes.first {
            self.interfaceOrientation = windowScene.effectiveGeometry.interfaceOrientation
            let screen = windowScene.screen
            let bounds = screen.bounds
            let scale = screen.scale
            self.screenScale = scale
            self.screenSummary = String(format: "%.0f×%.0fpt (%.0fx)", bounds.width, bounds.height, scale)
        }
        self.totalScreens = scenes.count
    }

    func orientationName(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "Portrait (縦)"
        case .portraitUpsideDown: return "Portrait Rev (逆縦)"
        case .landscapeLeft: return "Landscape L (左横)"
        case .landscapeRight: return "Landscape R (右横)"
        case .faceUp: return "Face Up"
        case .faceDown: return "Face Down"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    func interfaceOrientationName(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: return "Portrait"
        case .portraitUpsideDown: return "Portrait Rev"
        case .landscapeLeft: return "Landscape L"
        case .landscapeRight: return "Landscape R"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - UIHingeInteraction Bridge

struct UIHingeInteractionBridge: UIViewRepresentable {
    let onUpdate: (UIHinge?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        let interaction = UIHingeInteraction { _, update in
            DispatchQueue.main.async {
                onUpdate(update.hinge)
            }
        }
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Main App & Responsive Content View

@main
struct HingeTestApp: App {
    @StateObject private var model = HingeAnalyzerModel()

    var body: some Scene {
        WindowGroup {
            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                if isLandscape {
                    LandscapeLayout(model: model)
                } else {
                    PortraitLayout(model: model)
                }
            }
            .background(Color(.systemBackground))
            .background(UIHingeInteractionBridge { hinge in
                model.handleUIHingeUpdate(hinge)
            })
        }
    }
}

// MARK: - Portrait Layout (閉じた縦画面でもファーストビューに基本情報を集約)

struct PortraitLayout: View {
    @ObservedObject var model: HingeAnalyzerModel

    var body: some View {
        VStack(spacing: 8) {
            // Header: 1行
            AppHeaderBar(model: model)

            // Primary Metrics Card (Angles + Tension)
            AnglesSummaryCard(model: model)

            // Details Grid Card (CoreMotion, UIHinge, Orientation, Display)
            DetailsGridCard(model: model)

            // Remaining space: Logs Stream
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Event Logs", systemImage: "list.bullet.rectangle")
                        .font(.caption.bold())
                    Spacer()
                    Text("\(model.logs.count)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)

                LogsListView(logs: model.logs)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Landscape Layout (閉じた横画面でも左に全基本情報、右にログを配置してスクロール不要に)

struct LandscapeLayout: View {
    @ObservedObject var model: HingeAnalyzerModel

    var body: some View {
        HStack(spacing: 10) {
            // Left Column: ALL Essential Information (100% visible without scrolling)
            VStack(spacing: 6) {
                AppHeaderBar(model: model)

                AnglesSummaryCard(model: model)

                DetailsGridCard(model: model)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            // Right Column: Event Logs Stream
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Event Logs", systemImage: "list.bullet.rectangle")
                        .font(.caption.bold())
                    Spacer()
                    Text("\(model.logs.count)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                LogsListView(logs: model.logs)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Reusable UI Components

struct AppHeaderBar: View {
    @ObservedObject var model: HingeAnalyzerModel

    var body: some View {
        HStack(spacing: 6) {
            Text("Hinge & Motion")
                .font(.subheadline.weight(.heavy))

            statusBadge(model.uiHingeStatus)

            Spacer()

            Button(action: { model.clearLogs() }) {
                Image(systemName: "trash")
                    .font(.caption2)
                    .padding(4)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: UIHinge.Status) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .closed: return ("CLOSED", .orange)
            case .partiallyOpen: return ("PARTIAL", .blue)
            case .fullyOpen: return ("OPEN", .green)
            case .unknown: return ("UNKNOWN", .gray)
            @unknown default: return ("UNKNOWN", .gray)
            }
        }()

        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }
}

// MARK: - Angles Summary Card (3大角 + テンションをコンパクトに集約)

struct AnglesSummaryCard: View {
    @ObservedObject var model: HingeAnalyzerModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                // Screen Angle
                AngleColumn(
                    title: "Screen (Raw)",
                    value: model.cmAngleDegrees.map { String(format: "%.1f°", $0) } ?? "--",
                    exact: model.cmAngleDegrees.map { String(format: "%.4f°", $0) } ?? "",
                    color: .blue
                )

                Divider().frame(height: 38)

                // Mechanical Angle
                AngleColumn(
                    title: "Mech (Hinge)",
                    value: model.cmMechanicalDegrees.map { String(format: "%.1f°", $0) } ?? "--",
                    exact: model.cmMechanicalDegrees.map { String(format: "%.4f°", $0) } ?? "",
                    color: .green
                )

                Divider().frame(height: 38)

                // UIHinge Angle
                AngleColumn(
                    title: "UIHinge (UIKit)",
                    value: model.uiHingeAngleDeg.map { String(format: "%.1f°", $0) } ?? "--",
                    exact: model.uiHingeAngleDeg.map { String(format: "%.4f°", $0) } ?? "",
                    color: .purple
                )
            }

            // Tension bar
            if let screen = model.cmAngleDegrees, let mech = model.cmMechanicalDegrees {
                let diff = screen - mech
                HStack(spacing: 4) {
                    Text("Tension (Screen - Mech):")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%+.1f°", diff))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(abs(diff) < 0.1 ? Color.secondary : (diff > 0 ? Color.orange : Color.indigo))
                    Text(String(format: "(%+.4f°)", diff))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.top, 1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
    }
}

struct AngleColumn: View {
    let title: String
    let value: String
    let exact: String
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            if !exact.isEmpty {
                Text(exact)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Details Grid Card (CoreMotion, UIHinge, Orientation, Display)

struct DetailsGridCard: View {
    @ObservedObject var model: HingeAnalyzerModel

    var body: some View {
        VStack(spacing: 3) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                // CoreMotion Row
                GridRow {
                    Label("CoreMotion", systemImage: "gyroscope")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 90, alignment: .leading)

                    HStack(spacing: 4) {
                        Text(model.cmStatus)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(model.cmAvailable ? .green : .red)
                        Spacer()
                        if let s = model.cmAngleDegrees, let m = model.cmMechanicalDegrees {
                            Text(String(format: "s:%.1f° m:%.1f°", s, m))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // UIKit UIHinge Row
                GridRow {
                    Label("UIHinge", systemImage: "macbook.and.ipad")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 90, alignment: .leading)

                    HStack(spacing: 4) {
                        Text(statusShortString(model.uiHingeStatus))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Spacer()
                        if let rad = model.uiHingeAngleRad, let deg = model.uiHingeAngleDeg {
                            Text(String(format: "%.1f° (%.3frad)", deg, rad))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.purple)
                        } else {
                            Text("nil")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // Orientation Row
                GridRow {
                    Label("Orientation", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 90, alignment: .leading)

                    HStack(spacing: 4) {
                        Text("Dev: \(model.orientationName(model.deviceOrientation))")
                            .font(.system(size: 10))
                        Spacer()
                        Text("UI: \(model.interfaceOrientationName(model.interfaceOrientation))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Screen & Display Row
                GridRow {
                    Label("Screen", systemImage: "display")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 90, alignment: .leading)

                    HStack(spacing: 4) {
                        Text(model.screenSummary)
                            .font(.system(size: 10, design: .monospaced))
                        Spacer()
                        Text("\(model.totalScreens) screen(s)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
    }

    private func statusShortString(_ status: UIHinge.Status) -> String {
        switch status {
        case .closed: return ".closed"
        case .partiallyOpen: return ".partiallyOpen"
        case .fullyOpen: return ".fullyOpen"
        case .unknown: return ".unknown"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Logs List View

struct LogsListView: View {
    let logs: [EventLogItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if logs.isEmpty {
                    Text("No events received.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(logs) { item in
                        HStack(spacing: 6) {
                            Text(item.formattedTime)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Text("[\(item.shortSource)]")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(colorForSource(item.source))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Text(item.message)
                                .font(.system(size: 9, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    private func colorForSource(_ source: String) -> Color {
        switch source {
        case "CoreMotion": return .blue
        case "UIHinge": return .purple
        case "Orientation": return .orange
        default: return .secondary
        }
    }
}
