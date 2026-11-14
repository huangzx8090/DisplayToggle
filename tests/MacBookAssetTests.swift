import AppKit
import SceneKit

@main
struct MacBookAssetTests {
    static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("PASS: \(message)")
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/MacBook")
        let model = try MacBookScene(resourceDirectory: directory)
        expect(model.scene.rootNode.childNode(withName: "base", recursively: true) != nil,
               "现成模型的底座和上盖可分别载入")
        var triangleCount = 0
        var textures = Set<URL>()
        model.scene.rootNode.enumerateChildNodes { node, _ in
            triangleCount += node.geometry?.elements.reduce(0) { $0 + $1.primitiveCount } ?? 0
            for material in node.geometry?.materials ?? [] {
                for property in [material.diffuse, material.normal, material.metalness,
                                 material.roughness, material.ambientOcclusion] {
                    if let url = property.contents as? URL { textures.insert(url) }
                }
            }
        }
        expect(triangleCount == 104997, "保留原始 GLB 的全部 104997 个三角面")
        expect(textures.count == 6 && textures.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
               "六张原始纹理均从当前资源目录解析，不依赖开发机路径")
        let hinge = SCNVector3(0, -0.0043, -0.1145)
        for angle in [0.0, 30, 90, 135, 180] {
            model.setPose(angle: angle, screenOn: true)
            // 不依赖尚未渲染的 worldTransform 缓存，直接验证实际节点的局部变换。
            let matrix = SCNMatrix4Mult(SCNMatrix4Invert(model.lid.pivot), model.lid.transform)
            let actual = SCNVector3(
                hinge.x * matrix.m11 + hinge.y * matrix.m21 + hinge.z * matrix.m31 + matrix.m41,
                hinge.x * matrix.m12 + hinge.y * matrix.m22 + hinge.z * matrix.m32 + matrix.m42,
                hinge.x * matrix.m13 + hinge.y * matrix.m23 + hinge.z * matrix.m33 + matrix.m43)
            expect(abs(actual.x - hinge.x) < 0.00001 && abs(actual.y - hinge.y) < 0.00001 &&
                   abs(actual.z - hinge.z) < 0.00001,
                   "载入后的模型在 \(Int(angle))° 时绕固定铰链旋转")
        }
        expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("studio_small_09_1k.hdr").path),
               "离线摄影棚环境已随资源提供")
        print("模型资源与铰链集成测试全部通过；未执行 GPU 渲染或实机开合。")
    }
}
