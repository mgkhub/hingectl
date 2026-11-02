import HingeCtlAppKit
import HingeCtlCore
import SwiftUI

struct DeviceDetailView: View {
    @Bindable var detail: DeviceDetailStore
    let log: AppLog

    /// ログ欄を広げているか。既定は畳む。開閉の状態は、次回の起動で引き継ぐ。
    /// (保存のキーは、既定を広げていた間の値と区別するため、`logExpanded` とは別にしている)
    @AppStorage("logExpandedV2") private var logExpanded = false

    var body: some View {
        // 境界をドラッグすると、ログ欄の高さを変えられる(畳んでいる間は、見出しの高さで固定)
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    switch detail.phase {
                    case .idle, .connecting:
                        ProgressView("Connecting…")
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 8) {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            Button(.General.retry) { Task { await detail.connect() } }
                        }
                    case .ready:
                        if let reason = detail.hingeUnavailableReason {
                            HStack {
                                Label(reason, systemImage: "info.circle").foregroundStyle(.orange)
                                // 問い合わせの失敗(`unknown`)は、開き直すと、もう一度確かめられる
                                if detail.needsReconnect { reconnectButton }
                            }
                        }
                        AngleControlView(detail: detail)
                        SweepView(detail: detail)
                        OrientationView(detail: detail)
                        PostureView(detail: detail)
                        ScreenshotView(detail: detail, log: log)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200)
            LogView(log: log, isExpanded: $logExpanded)
                .frame(minHeight: logExpanded ? 80 : LogView.headerHeight,
                       idealHeight: logExpanded ? 150 : LogView.headerHeight,
                       maxHeight: logExpanded ? .infinity : LogView.headerHeight)
        }
    }

    private var reconnectButton: some View {
        Button(.General.reconnect, systemImage: "arrow.triangle.2.circlepath") { Task { await detail.connect() } }
            .disabled(detail.phase == .connecting)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text(detail.entry.name).font(.title2.bold())
                if let os = detail.entry.osText {
                    // ビルド(例: 24A94425)も添える
                    Text(detail.entry.osBuild.map { "\(os) (\($0))" } ?? os)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(detail.entry.udid).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let busy = detail.busyLabel {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            }
            LabeledContent {
                TextField("", value: $detail.timeout, format: .number)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text(.HingeAngle.confirmTimeout)
            }
            .fixedSize()
        }
    }
}

/// 項目ごとの枠
struct SectionBox<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            Text(title).font(.headline)
        }
    }
}

struct AngleControlView: View {
    @Bindable var detail: DeviceDetailStore
    @State private var slider = 180.0
    @State private var dragging = false
    @State private var isEditing = false
    @State private var inputAngle = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        SectionBox(title: .HingeAngle.title) {
            HStack(alignment: .firstTextBaseline) {
                if isEditing {
                    HStack(spacing: 2) {
                        TextField("", text: $inputAngle)
                            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.leading)
                            .focused($isFocused)
                            .frame(minWidth: 80, maxWidth: 120)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .frame(height: 2)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .onSubmit { commitEdit() }
                            .onExitCommand { cancelEdit() }
                            .onChange(of: isFocused) { _, focused in
                                if !focused && isEditing { commitEdit() }
                            }
                            .onChange(of: inputAngle) { _, newValue in
                                let filtered = sanitizeAngleInput(newValue)
                                if filtered != newValue {
                                    inputAngle = filtered
                                }
                            }
                        Text("°")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text(detail.reading.map { String(format: "%.1f°", $0.mechanicalAngle) } ?? "—")
                            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                            // 購読が切れたあとの値は、古い。薄くして示す
                            .opacity(detail.streamError == nil ? 1 : 0.35)
                        if let reading = detail.reading, abs(reading.sensorAngle - reading.mechanicalAngle) > 0.1 {
                            Text("(sensor: \(String(format: "%.1f°", reading.sensorAngle)))")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if detail.canUseHinge && !detail.isBusy {
                            Image(systemName: "pencil")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .opacity(isHovered ? 1 : 0)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isHovered && detail.canUseHinge && !detail.isBusy ? Color.secondary.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovered = hovering
                    }
                    .onTapGesture {
                        startEdit()
                    }
                    .help(.HingeAngle.editHelp)
                }

                if let reading = detail.reading, !reading.isValid {
                    Text("not valid").font(.caption).foregroundStyle(.orange)
                }
            }
            Slider(value: $slider, in: HingeLimits.angle) { editing in
                dragging = editing
                if !editing { detail.endDrag(slider) }
            }
            .onChange(of: slider) { _, value in
                if dragging { detail.dragAngle(value) }
            }
            .onChange(of: detail.reading?.mechanicalAngle) { _, angle in
                if let angle, !dragging, !detail.isDragging, !isEditing { slider = angle }
            }
            .onAppear { if let angle = detail.reading?.mechanicalAngle { slider = angle } }
            HStack {
                preset(.HingeAngle.close, 0)
                preset(.HingeAngle.half, 90)
                preset(.HingeAngle.open, 180)
            }
            if let error = detail.streamError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    Button(.General.reconnect, systemImage: "arrow.triangle.2.circlepath") { Task { await detail.connect() } }
                        .controlSize(.small)
                }
            }
        }
        .disabled(!detail.canUseHinge || (detail.isBusy && !detail.isDragging))
    }

    private func startEdit() {
        guard detail.canUseHinge, !detail.isBusy else { return }
        inputAngle = detail.reading.map { String(format: "%.1f", $0.mechanicalAngle) } ?? String(format: "%.1f", slider)
        isEditing = true
        isFocused = true
    }

    private func commitEdit() {
        guard isEditing else { return }
        isEditing = false
        isFocused = false
        let text = inputAngle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), HingeLimits.angle.contains(value) else {
            inputAngle = detail.reading.map { String(format: "%.1f", $0.mechanicalAngle) } ?? String(format: "%.1f", slider)
            return
        }
        slider = value
        Task { await detail.setAngle(value) }
    }

    private func sanitizeAngleInput(_ input: String) -> String {
        // 全角数字・記号を半角に正規化
        let normalized = input.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? input
        var result = ""
        var hasDecimalPoint = false
        var decimalDigitsCount = 0

        for ch in normalized {
            if ch.isNumber && ch.isASCII {
                if hasDecimalPoint {
                    if decimalDigitsCount < 1 {
                        result.append(ch)
                        decimalDigitsCount += 1
                    }
                } else {
                    if result.count < 3 {
                        result.append(ch)
                    }
                }
            } else if ch == "." && !hasDecimalPoint {
                hasDecimalPoint = true
                result.append(ch)
            }
        }
        return result
    }

    private func cancelEdit() {
        isEditing = false
        isFocused = false
    }

    private func preset(_ title: LocalizedStringResource, _ degrees: Double) -> some View {
        Button {
            Task { await detail.setAngle(degrees) }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("(\(Int(degrees))°)")
            }
        }
    }
}

struct SweepView: View {
    @Bindable var detail: DeviceDetailStore
    @State private var from = 180.0
    @State private var to = 0.0
    @State private var seconds = 3.0

    var body: some View {
        SectionBox(title: .Sweep.title) {
            // 1 行目は区間(プリセットが変えるのは、ここだけ)。2 行目は秒数と実行
            HStack {
                field(.Sweep.from, $from)
                Button(.Sweep.swap, systemImage: "arrow.left.arrow.right") { swap(&from, &to) }
                    .labelStyle(.iconOnly)
                    .help(.Sweep.swap)
                field(.Sweep.to, $to)
                Menu(.Sweep.presets) {
                    ForEach(Self.presets, id: \.title) { preset in
                        Button(preset.title) { from = preset.from; to = preset.to }
                    }
                }
                .fixedSize()
            }
            HStack {
                field(.Sweep.seconds, $seconds)
                Spacer()
                if detail.isSweeping {
                    Button(.Sweep.stop) { detail.cancelSweep() }
                } else {
                    Button(.Sweep.start) { detail.sweep(from: from, to: to, seconds: seconds) }
                }
            }
        }
        .disabled(!detail.canUseHinge || (detail.isBusy && !detail.isSweeping))
    }

    /// よく使う区間(Close 0° / Half 90° / Open 180°)
    private static let presets: [(title: String, from: Double, to: Double)] = [
        ("Open → Close", 180, 0),
        ("Close → Open", 0, 180),
        ("Open → Half", 180, 90),
        ("Half → Open", 90, 180),
        ("Half → Close", 90, 0),
        ("Close → Half", 0, 90),
    ]

    private func field(_ title: LocalizedStringResource, _ value: Binding<Double>) -> some View {
        LabeledContent {
            TextField("", value: value, format: .number).frame(width: 60).multilineTextAlignment(.trailing)
        } label: {
            Text(title)
        }
        .fixedSize()
    }
}

struct OrientationView: View {
    @Bindable var detail: DeviceDetailStore

    var body: some View {
        SectionBox(title: .Orientation.title) {
            HStack {
                ForEach(OrientationName.allCases, id: \.self) { name in
                    Button(name.rawValue) { Task { await detail.setOrientation(name) } }
                        .buttonStyle(.bordered)
                        .tint(detail.orientation == name ? .accentColor : nil)
                }
            }
            HStack {
                Button(.Orientation.rotateLeft, systemImage: "rotate.left") { Task { await detail.rotate(.left) } }
                Button(.Orientation.rotateRight, systemImage: "rotate.right") { Task { await detail.rotate(.right) } }
            }
        }
        // 向きは、ヒンジが無いデバイスでも使える(CLI の `orient` / `rotate` と同じ)
        .disabled(detail.isBusy)
    }
}

struct PostureView: View {
    @Bindable var detail: DeviceDetailStore

    var body: some View {
        SectionBox(title: .Posture.title) {
            if let posture = detail.posture {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Angle").foregroundStyle(.secondary)
                        if let angle = posture.mechanicalAngle {
                            if let sensor = posture.sensorAngle, abs(sensor - angle) > 0.1 {
                                Text("\(angleText(angle)) (sensor: \(angleText(sensor)))")
                            } else {
                                Text(angleText(angle))
                            }
                        } else {
                            Text("unavailable")
                        }
                    }
                    GridRow {
                        Text("Orientation").foregroundStyle(.secondary)
                        Text(posture.orientation.text)
                    }
                    ForEach(Array(posture.displays.enumerated()), id: \.offset) { index, display in
                        GridRow {
                            Text("Display").foregroundStyle(.secondary)
                            Text("\(display.name)\(display.primary ? " (primary)" : "")\(posture.active == index ? " (active)" : "") — backlight: \(display.backlight.text)")
                        }
                    }
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            Button(.General.refresh, systemImage: "arrow.clockwise") { Task { await detail.refreshPosture() } }
                .disabled(detail.isBusy)
        }
    }
}

struct ScreenshotView: View {
    @Bindable var detail: DeviceDetailStore
    let log: AppLog

    var body: some View {
        SectionBox(title: .Screenshot.title) {
            HStack {
                Button(.Screenshot.takeScreenshot, systemImage: "camera") { Task { await detail.takeScreenshot() } }
                .disabled(detail.isBusy)
                if let shot = detail.screenshot {
                    Button(.Screenshot.saveAs) { save(shot.path) }
                }
            }
            if let shot = detail.screenshot, let image = NSImage(contentsOfFile: shot.path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 360)
                // 撮影した時刻(保存の操作の時刻ではない)。保存時の既定のファイル名にも、同じ時刻を使う
                caption(for: shot)
            }
        }
    }

    @ViewBuilder
    private func caption(for shot: ScreenshotOutput) -> some View {
        if let date = detail.screenshotDate {
            Text(.Screenshot.caption(shot.display, date.formatted(date: .numeric, time: .standard)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text(shot.display)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func save(_ path: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = detail.suggestedScreenshotName ?? "Screenshot \(detail.entry.name).png"

        let performCopy: (URL) -> Void = { url in
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
            } catch {
                log.append(.error, "Cannot save screenshot: \(error.localizedDescription)")
            }
        }

        if let window = NSApp.windows.first(where: { $0.isKeyWindow && $0.isVisible }) ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    performCopy(url)
                }
            }
        } else {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            performCopy(url)
        }
    }
}

struct LogView: View {
    /// 畳んだときの高さ(見出しの 1 行)
    static let headerHeight: CGFloat = 30

    let log: AppLog
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14)
                    Text(.Log.title).font(.headline)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? .Log.collapse : .Log.expand)
                Spacer()
                if isExpanded {
                    Button(.Log.clear) { log.clear() }.buttonStyle(.link)
                } else if let last = log.lines.last {
                    // 畳んでいても、直近の 1 行は見えるようにする
                    Text(last.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(color(last.level))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.headerHeight)
            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.lines) { line in
                            Text("\(line.date.formatted(date: .omitted, time: .standard))  \(line.text)")
                                .font(.caption.monospaced())
                                .foregroundStyle(color(line.level))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
    }

    private func color(_ level: LogLine.Level) -> Color {
        switch level {
        case .note: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
