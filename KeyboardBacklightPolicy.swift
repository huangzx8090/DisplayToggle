enum KeyboardBacklightPolicy {
    static func restoreTarget(original: Float, automatic: Bool) -> Float {
        // 自动调节时，原值为零可能只表示当时环境明亮；写回零会继续抑制背光。
        automatic && original <= 0.01 ? 0.5 : original
    }
}
