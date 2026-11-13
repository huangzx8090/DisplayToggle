import Combine
import Foundation

struct SettingsHardwareControl: Equatable, Identifiable {
    let id: String
    let title: String
    let percent: Double
}

struct SettingsDisplay: Equatable, Identifiable {
    let id: UInt32
    let name: String
    let current: HiDPIMode
    let details: String
    let hiDPI: [HiDPIMode]
    let loDPI: [HiDPIMode]
    let refreshRates: [HiDPIMode]
    let restriction: String?
    let hardware: [SettingsHardwareControl]
    let hardwareMessage: String?
    let hardwareBusy: Bool
}

struct DisplaySettingsState: Equatable {
    var builtinActive = true
    var builtinVisible = true
    var externalCount = 0
    var activeExternalCount = 0
    var lidClosed: Bool?
    var angle: Int?
    var externalMode = ExternalDisplayMode.angle
    var angleThreshold = 100
    var autoRestore = true
    var keepOnWhenClosed = false
    var autoTrueTone = true
    var trueToneStatus = "检测中"
    var keyboardStatus: String?
    var loginEnabled = false
    var version = "—"
    var displays: [SettingsDisplay] = []
    var displaysLoaded = false
    var displayModeBusy = false
    var hardwareReading = false

    var pose: LidPose { LidPose.resolve(angle: angle, isClosed: lidClosed) }

    var canToggleBuiltin: Bool {
        if builtinActive {
            return activeExternalCount > 0 && !(keepOnWhenClosed && lidClosed == true)
        }
        return lidClosed != true || keepOnWhenClosed
    }

    var builtinHint: String {
        if keepOnWhenClosed && lidClosed == true { return "合盖保持已开启，内屏优先保持点亮。" }
        if builtinActive && activeExternalCount == 0 { return "没有可用的物理外接画面，保持内屏开启。" }
        if !builtinActive && lidClosed == true { return "默认合盖保护正在阻止点亮内屏。" }
        return "手动操作后有 5 分钟优先期，安全恢复规则仍然有效。"
    }
}

struct SettingsActions {
    let setBuiltin: (Bool) -> Void
    let selectMode: (ExternalDisplayMode) -> Void
    let setThreshold: (Int) -> Void
    let setAutoRestore: (Bool) -> Void
    let setKeepOnWhenClosed: (Bool) -> Void
    let setAutoTrueTone: (Bool) -> Void
    let setLoginEnabled: (Bool) -> Void
    let selectDisplayMode: (UInt32, HiDPIMode) -> Void
    let setHardware: (UInt32, String, Double) -> Void
    let refreshDisplays: () -> Void
    let openLog: () -> Void
    let exportDiagnostics: () -> Void
    let checkUpdates: () -> Void
}

final class DisplaySettingsModel: ObservableObject {
    @Published private(set) var state: DisplaySettingsState
    let actions: SettingsActions

    init(state: DisplaySettingsState, actions: SettingsActions) {
        self.state = state
        self.actions = actions
    }

    func update(_ state: DisplaySettingsState) {
        // 现有采样器持续运行，只有状态改变时才让窗口重绘。
        if self.state != state { self.state = state }
    }
}
