import AppKit
import SceneKit
import SwiftUI

struct LidIllustration: NSViewRepresentable {
    let angle: Double
    let screenOn: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> MacBookView { MacBookView() }

    func updateNSView(_ view: MacBookView, context: Context) {
        view.update(angle: angle, screenOn: screenOn, animated: !reduceMotion)
    }
}

final class MacBookView: SCNView {
    private let model: MacBookScene?
    private var previousAngle: Double?
    private var previousScreenOn: Bool?

    init() {
        model = try? MacBookScene()
        super.init(frame: .zero, options: nil)
        backgroundColor = .clear
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 30
        // 静态时不持续重绘；只有传感器变化触发短暂的 SceneKit 动画。
        rendersContinuously = false
        isPlaying = false
        scene = model?.scene
        pointOfView = model?.camera
        if model == nil {
            let label = NSTextField(labelWithString: "设备预览素材未能载入")
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func update(angle: Double, screenOn: Bool, animated: Bool) {
        guard previousAngle != angle || previousScreenOn != screenOn else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated && previousAngle != nil ? 0.45 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        model?.setPose(angle: angle, screenOn: screenOn)
        SCNTransaction.commit()
        previousAngle = angle
        previousScreenOn = screenOn
        needsDisplay = true
    }
}

final class MacBookScene {
    struct Material: Decodable {
        let name: String
        let color: [Double]
        let metalness: Double
        let roughness: Double
        let emission: [Double]
        let doubleSided: Bool
        let alphaBlend: Bool
        let diffuseTexture: String?
        let normalTexture: String?
        let metallicRoughnessTexture: String?
        let occlusionTexture: String?
    }

    private struct Manifest: Decodable { let materials: [Material] }
    enum LoadError: Error { case missingResources, missingLid }

    let scene: SCNScene
    let camera = SCNNode()
    let lid: SCNNode
    private let screen: SCNMaterial?

    init(resourceDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("MacBook")) throws {
        guard let directory = resourceDirectory else { throw LoadError.missingResources }
        scene = try SCNScene(url: directory.appendingPathComponent("model.scn"), options: nil)
        guard let lid = scene.rootNode.childNode(withName: "lid", recursively: true) else {
            throw LoadError.missingLid
        }
        self.lid = lid
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("model.json")))
        let definitions = Dictionary(uniqueKeysWithValues: manifest.materials.map { ($0.name, $0) })
        var screenMaterial: SCNMaterial?
        scene.rootNode.enumerateChildNodes { node, _ in
            for material in node.geometry?.materials ?? [] {
                guard let name = material.name, let definition = definitions[name] else { continue }
                Self.apply(definition, to: material, directory: directory)
                if name == "material_2" { screenMaterial = material }
            }
        }
        screen = screenMaterial

        // 原素材上盖与底座已分组。仅设置铰链支点，完整保留作者的机身几何。
        lid.pivot = SCNMatrix4MakeTranslation(0, -0.0043, -0.1145)
        lid.position = SCNVector3(0, -0.0043, -0.1145)

        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = directory.appendingPathComponent("studio_small_09_1k.hdr")
        scene.lightingEnvironment.intensity = 0.5

        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 0.19
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 5
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.position = SCNVector3(0.20, 0.22, 0.5)
        camera.look(at: SCNVector3(0, 0.085, -0.035))
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 250
        key.position = SCNVector3(-0.3, 0.8, 0.6)
        key.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(key)
        setPose(angle: 100, screenOn: true)
    }

    func setPose(angle: Double, screenOn: Bool) {
        lid.eulerAngles.x = CGFloat(LidGeometry.rotation(for: angle))
        screen?.diffuse.contents = screenOn ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.015, alpha: 1)
        screen?.emission.contents = screenOn ? NSColor(white: 0.55, alpha: 1) : NSColor.black
        screen?.metalness.contents = 0.0
        screen?.roughness.contents = 0.3
    }

    private static func apply(_ source: Material, to material: SCNMaterial, directory: URL) {
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(srgbRed: source.color[0], green: source.color[1],
                                           blue: source.color[2], alpha: source.color[3])
        material.metalness.contents = source.metalness
        material.roughness.contents = source.roughness
        material.emission.contents = NSColor(srgbRed: source.emission[0], green: source.emission[1],
                                            blue: source.emission[2], alpha: 1)
        material.isDoubleSided = source.doubleSided
        material.transparency = source.alphaBlend ? CGFloat(source.color[3]) : 1
        func texture(_ path: String?, _ property: SCNMaterialProperty) {
            guard let path else { return }
            property.contents = directory.appendingPathComponent(path)
            // glTF 的纹理原点在左上角，SceneKit 使用左下角。
            property.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(1, -1, 1),
                                                        SCNMatrix4MakeTranslation(0, 1, 0))
            property.wrapS = .repeat
            property.wrapT = .repeat
        }
        texture(source.diffuseTexture, material.diffuse)
        texture(source.normalTexture, material.normal)
        texture(source.metallicRoughnessTexture, material.metalness)
        material.metalness.textureComponents = .blue
        texture(source.metallicRoughnessTexture, material.roughness)
        material.roughness.textureComponents = .green
        texture(source.occlusionTexture, material.ambientOcclusion)
        material.ambientOcclusion.textureComponents = .red
    }
}
