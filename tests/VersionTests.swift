import Foundation

@main
struct VersionTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("PASS: \(message)")
        } else {
            print("FAIL: \(message)")
            failures += 1
        }
    }

    static func main() {
        expect(Version.isNewer("1.9.0", than: "1.8.0"), "次版本更高")
        expect(Version.isNewer("1.9.1", than: "1.9.0"), "修订号更高")
        expect(Version.isNewer("2.0", than: "1.99.99"), "主版本优先")
        expect(Version.isNewer("1.10.0", than: "1.9.9"), "按数字比较而不是字符串")
        expect(!Version.isNewer("1.9.0", than: "1.9.0"), "相同版本不算更新")
        expect(!Version.isNewer("1.8.9", than: "1.9.0"), "旧版本不算更新")
        expect(!Version.isNewer("1.9", than: "1.9.0"), "段数不同但数值相同")
        expect(Version.isNewer("v2.0.0", than: "1.9.0"), "带 v 前缀")
        expect(Version.isNewer("1.9.0", than: "1.9.0-beta.2"), "预发布后缀被忽略")
        expect(Version.isNewer("1.0.1", than: "1.0"), "补零比较")
        expect(Version.isNewer("1.9.0-beta.10", than: "1.9.0-beta.2"), "预发布数字标识按数值比较")
        expect(Version.isNewer("1.9.0-beta", than: "1.9.0-1"), "文本预发布标识高于数字标识")
        expect(!Version.isNewer("1.9.0+build.2", than: "1.9.0+build.1"), "构建元数据不影响版本优先级")

        if failures > 0 {
            print("版本比较测试失败 \(failures) 项")
            exit(1)
        }
        print("版本比较测试全部通过")
    }
}
