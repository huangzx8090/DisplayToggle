// 开发工具：只转换已核实的第三方 GLB，不生成或重画模型几何。
// 用法：swift tools/prepare-macbook.swift /path/to/macbook-pro-14.glb Assets/MacBook
import AppKit
import CryptoKit
import SceneKit

typealias Object = [String: Any]

func require(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

require(CommandLine.arguments.count == 3, "需要输入 GLB 和输出目录")
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let raw = try Data(contentsOf: input)
let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
require(digest == "a0e7369e062cb29fd12a7c91c3cf6120e5ab65cfc3dfc428a57139162d6e144d",
        "仅支持来源清单中固定 SHA256 的原模型")
func uint32(_ offset: Int) -> Int {
    Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian)
}
require(uint32(0) == 0x46546C67 && uint32(4) == 2, "需要 glTF 2 GLB")
let jsonLength = uint32(12)
let json = try JSONSerialization.jsonObject(with: raw.subdata(in: 20..<(20 + jsonLength))) as! Object
let binaryStart = 28 + jsonLength
let binary = raw.subdata(in: binaryStart..<(binaryStart + uint32(20 + jsonLength)))
let accessors = json["accessors"] as! [Object]
let views = json["bufferViews"] as! [Object]
let materials = json["materials"] as! [Object]
let meshes = json["meshes"] as! [Object]
let originalNodes = json["nodes"] as! [Object]
let textures = json["textures"] as! [Object]
let images = json["images"] as! [Object]
require((json["extensionsRequired"] as? [String] ?? []).isEmpty, "不支持压缩扩展")
try FileManager.default.createDirectory(at: output.appendingPathComponent("textures"),
                                      withIntermediateDirectories: true)

func packedAccessor(_ index: Int) -> (Data, Object, Int) {
    let accessor = accessors[index]
    let view = views[accessor["bufferView"] as! Int]
    let componentType = accessor["componentType"] as! Int
    require(componentType == 5126 || componentType == 5125, "只接受原模型的 Float32/UInt32")
    let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][accessor["type"] as! String]!
    let itemSize = components * 4
    let stride = view["byteStride"] as? Int ?? itemSize
    let offset = (view["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
    let count = accessor["count"] as! Int
    var result = Data(capacity: count * itemSize)
    for item in 0..<count {
        let begin = offset + item * stride
        result.append(binary.subdata(in: begin..<(begin + itemSize)))
    }
    return (result, accessor, components)
}

func geometrySource(_ index: Int, semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
    var (data, accessor, components) = packedAccessor(index)
    require(accessor["componentType"] as! Int == 5126, "顶点属性必须是 Float32")
    if semantic == .vertex {
        // 源模型根节点的两次坐标旋转互相抵消，只剩厘米到米的 0.01 缩放。
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let value = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self) * 0.01
                bytes.storeBytes(of: value, toByteOffset: offset, as: Float.self)
            }
        }
    }
    return SCNGeometrySource(data: data, semantic: semantic,
                             vectorCount: accessor["count"] as! Int, usesFloatComponents: true,
                             componentsPerVector: components, bytesPerComponent: 4,
                             dataOffset: 0, dataStride: components * 4)
}

let nativeMaterials = materials.indices.map { index -> SCNMaterial in
    let material = SCNMaterial()
    material.name = "material_\(index)"
    return material
}
let nodes = originalNodes.indices.map { index -> SCNNode in
    let node = SCNNode()
    node.name = index == 3 ? "lid" : (index == 20 ? "base" : "source_node_\(index)")
    if index > 1 {
        require(originalNodes[index]["matrix"] == nil && originalNodes[index]["translation"] == nil &&
                originalNodes[index]["rotation"] == nil && originalNodes[index]["scale"] == nil,
                "原模型的节点变换有变化，需要重新检查转换")
    }
    return node
}
var triangleCount = 0
for index in 2..<originalNodes.count {
    let sourceNode = originalNodes[index]
    if let meshIndex = sourceNode["mesh"] as? Int {
        for primitive in meshes[meshIndex]["primitives"] as! [Object] {
            require(primitive["mode"] as? Int ?? 4 == 4, "仅支持原模型的三角面")
            let attributes = primitive["attributes"] as! [String: Int]
            let sources = [("POSITION", SCNGeometrySource.Semantic.vertex),
                           ("NORMAL", .normal), ("TEXCOORD_0", .texcoord)].compactMap { key, semantic in
                attributes[key].map { geometrySource($0, semantic: semantic) }
            }
            let (indices, accessor, _) = packedAccessor(primitive["indices"] as! Int)
            let count = accessor["count"] as! Int
            triangleCount += count / 3
            let element = SCNGeometryElement(data: indices, primitiveType: .triangles,
                                            primitiveCount: count / 3, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            geometry.materials = [nativeMaterials[primitive["material"] as! Int]]
            nodes[index].addChildNode(SCNNode(geometry: geometry))
        }
    }
    for child in sourceNode["children"] as? [Int] ?? [] { nodes[index].addChildNode(nodes[child]) }
}
let scene = SCNScene()
scene.rootNode.addChildNode(nodes[2])
require(scene.write(to: output.appendingPathComponent("model.scn"), options: nil,
                    delegate: nil, progressHandler: nil), "无法写入 SceneKit 资源")

for (index, image) in images.enumerated() {
    require(image["mimeType"] as! String == "image/png", "需要原始 PNG 纹理")
    let view = views[image["bufferView"] as! Int]
    let offset = view["byteOffset"] as? Int ?? 0
    try binary.subdata(in: offset..<(offset + (view["byteLength"] as! Int)))
        .write(to: output.appendingPathComponent("textures/\(index).png"))
}

func texturePath(_ info: Any?) -> String? {
    guard let info = info as? Object, let index = info["index"] as? Int,
          let source = textures[index]["source"] as? Int else { return nil }
    return "textures/\(source).png"
}
let materialManifest: [Object] = materials.enumerated().map { index, material in
    let pbr = material["pbrMetallicRoughness"] as? Object ?? [:]
    var result: Object = [
        "name": "material_\(index)",
        "color": pbr["baseColorFactor"] ?? [1.0, 1.0, 1.0, 1.0],
        "metalness": pbr["metallicFactor"] ?? 1.0,
        "roughness": pbr["roughnessFactor"] ?? 1.0,
        "emission": material["emissiveFactor"] ?? [0.0, 0.0, 0.0],
        "doubleSided": material["doubleSided"] ?? false,
        "alphaBlend": (material["alphaMode"] as? String) == "BLEND"
    ]
    for (key, info) in [("diffuseTexture", pbr["baseColorTexture"]),
                        ("normalTexture", material["normalTexture"]),
                        ("metallicRoughnessTexture", pbr["metallicRoughnessTexture"]),
                        ("occlusionTexture", material["occlusionTexture"])] {
        if let path = texturePath(info) { result[key] = path }
    }
    return result
}
let manifest: Object = [
    "title": "2021 Macbook Pro 14\" (M1 Pro / M1 Max)",
    "author": "akshatmittal",
    "source": "https://sketchfab.com/3d-models/2021-macbook-pro-14-m1-pro-m1-max-f6b0b940fb6a4286b18a674ef32af2d3",
    "download": "https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-134/f6b0b940fb6a4286b18a674ef32af2d3.glb",
    "sourceSHA256": digest,
    "license": "https://creativecommons.org/licenses/by/4.0/",
    "changes": "Converted original geometry and PNG textures to SceneKit; baked scale; named lid/base groups; display material and lighting adjusted at runtime. Original mesh topology preserved.",
    "triangles": triangleCount, "materials": materialManifest,
    "lighting": [
        "title": "Studio Small 09", "source": "https://polyhaven.com/a/studio_small_09",
        "license": "https://creativecommons.org/publicdomain/zero/1.0/",
        "download": "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/studio_small_09_1k.hdr",
        "sha256": "e7cfda5f4e98e623db12b8bfd0184e048488e4855d9c83e2751fb44a32e80c45"
    ]
]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    .write(to: output.appendingPathComponent("model.json"))
print("转换完成：\(triangleCount) 个原始三角面，\(images.count) 张原始 PNG，未内嵌本机路径。")
