import SwiftUI
import SceneKit

struct PlanetView: NSViewRepresentable {
    var moon = false
    var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 24
        view.rendersContinuously = false
        view.allowsCameraControl = false
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        let file = moon ? "moon" : "earth"
        material.diffuse.contents = Bundle.module.url(forResource: file, withExtension: "jpg", subdirectory: "Assets")
        material.lightingModel = .lambert
        material.specular.contents = NSColor(white: 0.12, alpha: 1)
        sphere.firstMaterial = material
        let globe = SCNNode(geometry: sphere)
        globe.name = "globe"
        globe.eulerAngles = SCNVector3(moon ? 0 : 0.10, moon ? Float.pi : 1.3, moon ? 0 : -0.10)
        scene.rootNode.addChildNode(globe)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.01
        camera.position = SCNVector3(0, 0, 5)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = moon ? 560 : 650
        scene.rootNode.addChildNode(ambient)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .omni
        light.light?.intensity = moon ? 500 : 650
        light.position = SCNVector3(-3, 4, 5)
        scene.rootNode.addChildNode(light)
        view.scene = scene
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard let globe = view.scene?.rootNode.childNode(withName: "globe", recursively: false) else { return }
        if spinning && !reducedMotion {
            if globe.action(forKey: "scan") == nil {
                globe.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 36)), forKey: "scan")
            }
        } else { globe.removeAction(forKey: "scan") }
    }
}
