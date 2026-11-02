@main
struct DisplayPolicyTests {
    static func main() {
        precondition(ExternalDisplayMode.migrate(angle: nil, autoOff: nil) == .angle)
        precondition(ExternalDisplayMode.migrate(angle: true, autoOff: true) == .angle)
        precondition(ExternalDisplayMode.migrate(angle: true, autoOff: false) == .angle)
        precondition(ExternalDisplayMode.migrate(angle: false, autoOff: true) == .externalOnly)
        precondition(ExternalDisplayMode.migrate(angle: false, autoOff: false) == .manual)
        precondition(DisplayPriority.forceOnWhileClosed(keepOn: true, isClosed: true))
        precondition(!DisplayPriority.forceOnWhileClosed(keepOn: false, isClosed: true))
        precondition(!DisplayPriority.forceOnWhileClosed(keepOn: true, isClosed: false))
        precondition(!DisplayPriority.forceOnWhileClosed(keepOn: false, isClosed: false))
        print("外屏模式迁移与合盖优先级测试全部通过")
    }
}
