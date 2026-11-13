import AppKit
import SwiftUI

// 新SDK同时导出State宏与包装器；别名明确选用兼容旧系统的包装器。
private typealias ViewState<Value> = SwiftUI.State<Value>

final class SettingsWindowController: NSWindowController {
    let model: DisplaySettingsModel

    init(model: DisplaySettingsModel) {
        self.model = model
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "DisplayToggle 设置"
        window.contentMinSize = NSSize(width: 900, height: 630)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DisplayToggleSettings")
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        if !window.setFrameUsingName("DisplayToggleSettings") { window.center() }
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case display = "显示与策略"
    case external = "外接显示器"
    case general = "通用与诊断"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .display: return "macbook"
        case .external: return "display"
        case .general: return "gearshape"
        }
    }
}

private struct SettingsRootView: View {
    @ObservedObject var model: DisplaySettingsModel
    @ViewState<SettingsPage> private var page = .display

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Label("DisplayToggle", systemImage: "laptopcomputer")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 14)
                VStack(spacing: 5) {
                    ForEach(SettingsPage.allCases) { item in
                        Button {
                            page = item
                        } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 10)
                                .foregroundStyle(page == item ? Color.white : Color.primary)
                                .background(page == item ? Color.accentColor : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(page == item ? [.isSelected] : [])
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Text("v\(model.state.version)")
                    Text("设置与菜单栏同步")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(width: 178)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    switch page {
                    case .display: displayPage
                    case .external: externalPage
                    case .general: generalPage
                    }
                }
                .padding(30)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 630)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(page.rawValue)
                    .font(.system(size: 25, weight: .semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if page == .external {
                Button {
                    model.actions.refreshDisplays()
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .disabled(model.state.hardwareReading)
            }
        }
    }

    private var subtitle: String {
        switch page {
        case .display: return "跟随开盖角度，调整内外屏的使用方式。"
        case .external: return "查看实际可用的模式，调整显示器支持的硬件控制。"
        case .general: return "登录启动、更新和当前显示状态的诊断。"
        }
    }

    private var displayPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            LidStatusView(state: model.state)
            HStack(alignment: .center, spacing: 16) {
                Button(model.state.builtinActive ? "关闭内屏" : "打开内屏") {
                    model.actions.setBuiltin(!model.state.builtinActive)
                }
                .disabled(!model.state.canToggleBuiltin)
                Text(model.state.builtinHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("接外屏时").font(.headline)
                Picker("接外屏时", selection: binding(\.externalMode, model.actions.selectMode)) {
                    ForEach(ExternalDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(modeExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if model.state.externalMode == .angle {
                    HStack {
                        Text("打开内屏的角度")
                        Spacer()
                        Text("\(model.state.angleThreshold)°")
                            .monospacedDigit()
                            .fontWeight(.medium)
                    }
                    Slider(value: Binding(
                        get: { Double(model.state.angleThreshold) },
                        set: { model.actions.setThreshold(Int($0)) }),
                           in: 30...135, step: 5)
                        .accessibilityLabel("打开内屏的角度")
                    HStack {
                        Text("30°")
                        Spacer()
                        Text("135°")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("低于阈值 5° 并稳定后关闭，减少临界角度的反复切换。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            SettingsToggle(
                title: "外接屏没画面时，自动打开内屏",
                detail: "全部物理外接屏拔掉后仍会尝试恢复；系统息屏时不干预。",
                value: binding(\.autoRestore, model.actions.setAutoRestore))
            SettingsToggle(
                title: "合盖时保持内屏点亮",
                detail: "开启后，合盖时优先保持内屏点亮；默认关闭。",
                value: binding(\.keepOnWhenClosed, model.actions.setKeepOnWhenClosed))
            SettingsToggle(
                title: "自动切换原彩显示",
                detail: "内屏出画时开启，只用外屏时关闭。当前：\(model.state.trueToneStatus)。",
                value: binding(\.autoTrueTone, model.actions.setAutoTrueTone))
            if let status = model.state.keyboardStatus {
                Label(status, systemImage: "light.max")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeExplanation: String {
        switch model.state.externalMode {
        case .angle:
            return model.state.pose.source == .sensor
                ? "达到设定角度时使用内屏。设备模型跟随真实读数开合。"
                : "需要可读取的角度传感器。没有有效读数时，角度控制暂停。"
        case .externalOnly:
            return "物理外接屏稳定出画后关闭内屏，拔掉全部外屏时按保护条件尝试恢复。"
        case .manual:
            return "内屏由你手动开关，拔掉全部外屏后的恢复保护仍然有效。"
        }
    }

    private var externalPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.state.displays.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "display")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(model.state.externalCount == 0 ? "未连接物理外接显示器" :
                            (model.state.displaysLoaded ? "没有读取到可用显示模式" : "正在读取显示模式…"))
                        .font(.headline)
                    Text("连接后可在这里查看分辨率、刷新率和支持的硬件控制。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 100)
            }
            ForEach(model.state.displays) { display in
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(display.name, systemImage: "display").font(.headline)
                            Spacer()
                            Text(display.current.isHiDPI ? "HiDPI" : "普通模式")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(display.current.title)
                            .font(.system(size: 21, weight: .medium))
                        if !display.details.isEmpty {
                            Text(display.details)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            modeMenu("HiDPI", modes: display.hiDPI, display: display)
                            modeMenu("普通分辨率", modes: display.loDPI, display: display)
                            modeMenu("刷新率", modes: display.refreshRates, display: display)
                        }
                        .disabled(display.restriction != nil || model.state.displayModeBusy)
                        if let restriction = display.restriction {
                            Label(restriction, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(display.hardware) { control in
                            HardwareSliderRow(control: control, busy: display.hardwareBusy) { percent in
                                model.actions.setHardware(display.id, control.id, percent)
                            }
                        }
                        if let message = display.hardwareMessage {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                }
            }
            if !model.state.displays.isEmpty {
                Text("显示模式变更需要及时确认。没有备用画面时，亮度与对比度调整也会先进入预览，超时将尝试还原。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modeMenu(_ title: String, modes: [HiDPIMode],
                          display: SettingsDisplay) -> some View {
        Menu(title) {
            ForEach(modes.indices, id: \.self) { index in
                let mode = modes[index]
                Button {
                    model.actions.selectDisplayMode(display.id, mode)
                } label: {
                    if mode.matches(display.current) {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        }
        .disabled(modes.isEmpty)
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsToggle(
                title: "开机自动启动",
                detail: "在下次登录时启动当前路径的应用。移动应用后请重新检查。",
                value: binding(\.loginEnabled, model.actions.setLoginEnabled))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("显示状态诊断").font(.headline)
                Text("报告记录当前显示状态、版本和系统信息，不包含显示器序列号、个人路径或日志正文。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("导出诊断报告…") { model.actions.exportDiagnostics() }
                    Button("查看日志") { model.actions.openLog() }
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DisplayToggle").font(.headline)
                    Text("当前版本 \(model.state.version)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("检查更新…") { model.actions.checkUpdates() }
            }
            Divider()
            HStack(spacing: 6) {
                Text("设备模型：akshatmittal")
                Link("原始素材", destination: URL(string: "https://sketchfab.com/3d-models/2021-macbook-pro-14-m1-pro-m1-max-f6b0b940fb6a4286b18a674ef32af2d3")!)
                Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: KeyPath<DisplaySettingsState, Value>,
                                _ change: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { model.state[keyPath: keyPath] }, set: change)
    }
}

private struct LidStatusView: View {
    let state: DisplaySettingsState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState<Double> private var lastKnownAngle = 90

    private var illustratedAngle: Double {
        state.pose.source == .unavailable ? lastKnownAngle : state.pose.angle
    }

    var body: some View {
        HStack(spacing: 12) {
            LidIllustration(angle: illustratedAngle, screenOn: state.builtinVisible,
                            reduceMotion: reduceMotion)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                Text("开盖角度").foregroundStyle(.secondary)
                Text(state.pose.reading)
                    .font(.system(size: state.pose.source == .closed ? 32 : 48,
                                  weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("开盖角度 \(state.pose.reading)")
                Text(angleDetail).font(.callout).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
                Label(state.builtinActive ? "内屏已开启" : "内屏已关闭",
                      systemImage: state.builtinActive ? "laptopcomputer" : "laptopcomputer.slash")
                Label("物理外接屏 \(state.externalCount) 台", systemImage: "display")
            }
            .frame(width: 190, alignment: .leading)
        }
        .frame(height: 240)
        .onAppear {
            if state.pose.source != .unavailable { lastKnownAngle = state.pose.angle }
        }
        .onChange(of: state.pose) { pose in
            if pose.source != .unavailable { lastKnownAngle = pose.angle }
        }
    }

    private var angleDetail: String {
        switch state.pose.source {
        case .sensor: return "来自角度传感器"
        case .closed: return "根据合盖状态显示"
        case .unavailable: return "暂无有效读数，示意保持静止"
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var value: Bool

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $value)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct HardwareSliderRow: View {
    let control: SettingsHardwareControl
    let busy: Bool
    let commit: (Double) -> Void
    @ViewState<Double> private var percent: Double
    @ViewState<Bool> private var editing = false

    init(control: SettingsHardwareControl, busy: Bool, commit: @escaping (Double) -> Void) {
        self.control = control
        self.busy = busy
        self.commit = commit
        _percent = ViewState(initialValue: control.percent)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(control.title)
                Spacer()
                Text("\(Int(percent.rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $percent, in: 0...100) { editing in
                self.editing = editing
                // 与原菜单滑块一致，松开后才向显示器发送一次硬件写入。
                if !editing { commit(percent) }
            }
            .accessibilityLabel(control.title)
            .disabled(busy)
        }
        .onChange(of: control.percent) { value in
            if !editing { percent = value }
        }
        .onChange(of: busy) { value in
            // 写入失败时读数可能没变化，也要在操作结束后回到最后确认的值。
            if !value && !editing { percent = control.percent }
        }
    }
}
