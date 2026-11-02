@main
struct KeyboardBacklightPolicyTests {
    static func main() {
        precondition(KeyboardBacklightPolicy.restoreTarget(original: 0, automatic: true) == 0.5)
        precondition(KeyboardBacklightPolicy.restoreTarget(original: 0.4, automatic: true) == 0.4)
        precondition(KeyboardBacklightPolicy.restoreTarget(original: 0, automatic: false) == 0)
        precondition(KeyboardBacklightPolicy.restoreTarget(original: 0.4, automatic: false) == 0.4)
        print("键盘背光恢复策略测试全部通过")
    }
}
