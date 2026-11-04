import AppKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import UniformTypeIdentifiers
import WallKit

enum SceneColorMode: String, CaseIterable, Identifiable {
    case walls = "Walls", data = "Data", power = "Power"
    var id: String { rawValue }
}

enum CameraPreset { case front, top, side, fit }

/// Bridges toolbar actions to the SCNView.
final class SceneController: ObservableObject {
    weak var view: SCNView?
    var fit: (CameraPreset) -> Void = { _ in }
    func snapshot() -> NSImage? { view?.snapshot() }
}

struct SceneWorkspace: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selection: Selection?
    @StateObject private var controller = SceneController()
    @State private var colorMode: SceneColorMode = .walls
    @State private var showPaths = true
    @State private var showRoomControls = false

    var body: some View {
        VStack(spacing: 0) {
            ViewBar {
                Picker("Color", selection: $colorMode) { ForEach(SceneColorMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Run paths", isOn: $showPaths).disabled(colorMode == .walls).fixedSize()
                ControlGroup {
                    Button("Front") { controller.fit(.front) }
                    Button("Top") { controller.fit(.top) }
                    Button("Side") { controller.fit(.side) }
                    Button("Fit") { controller.fit(.fit) }
                }
                .fixedSize()
                Button { importRoom() } label: { Label("Import Room…", systemImage: "building.2") }
                    .help("SketchUp: File ▸ Export ▸ 3D Model ▸ COLLADA (.dae), OBJ or USDZ")
                if store.project.room != nil {
                    Button { showRoomControls.toggle() } label: { Label("Room", systemImage: "slider.horizontal.3") }
                        .popover(isPresented: $showRoomControls, arrowEdge: .bottom) { RoomControls() }
                }
                Button { snapshot() } label: { Label("Snapshot", systemImage: "camera") }.help("Save the 3D view as PNG")
            }
            if store.project.walls.isEmpty {
                ContentUnavailableView("No Walls", systemImage: "cube.transparent", description: Text("Add a wall to see it in 3D."))
            } else {
                LEDSceneView(project: store.project, report: store.report, colorMode: colorMode, showPaths: showPaths,
                             selectedWall: { if case .wall(let id) = selection { return id }; return nil }(),
                             controller: controller) { id in selection = .wall(id); store.focusWallID = id }
            }
        }
    }

    private func importRoom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["dae", "obj", "usdz", "usd", "usda", "usdc", "scn", "stl", "ply", "abc"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a room model. From SketchUp: File ▸ Export ▸ 3D Model ▸ COLLADA (.dae)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let node = RoomLoader.load(url) else { store.alert("Couldn't read \(url.lastPathComponent)", "Try exporting COLLADA (.dae) or OBJ from SketchUp."); return }
        // SketchUp exports are usually inches: a model hundreds of units across is not in meters.
        let (minB, maxB) = node.boundingBox
        let span = max(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z)
        store.project.room = RoomModelRef(path: url.path, scale: span > 300 ? 0.0254 : 1)
        showRoomControls = true
    }

    private func snapshot() {
        guard let img = controller.snapshot(), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(store.project.name) 3D.png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}

enum RoomLoader {
    static var cache: [String: SCNNode] = [:]
    static func load(_ url: URL) -> SCNNode? {
        if let n = cache[url.path] { return n.clone() }
        let scene: SCNScene?
        if ["obj", "stl", "ply"].contains(url.pathExtension.lowercased()) {
            scene = SCNScene(mdlAsset: MDLAsset(url: url))
        } else {
            scene = try? SCNScene(url: url, options: [.convertToYUp: true, .checkConsistency: false])
        }
        guard let scene else { return nil }
        let root = SCNNode()
        for c in scene.rootNode.childNodes { root.addChildNode(c) }
        root.enumerateHierarchy { n, _ in n.geometry?.materials.forEach { $0.isDoubleSided = true } }
        cache[url.path] = root
        return root.clone()
    }
}

struct RoomControls: View {
    @EnvironmentObject private var store: ProjectStore
    var body: some View {
        if let room = store.project.room {
            let b = Binding(get: { store.project.room ?? room }, set: { store.project.room = $0 })
            Form {
                Text(URL(fileURLWithPath: room.path).lastPathComponent).font(.headline)
                Picker("Model units", selection: b.scale) {
                    Text("Meters").tag(1.0); Text("Centimeters").tag(0.01); Text("Millimeters").tag(0.001)
                    Text("Inches").tag(0.0254); Text("Feet").tag(0.3048)
                }
                NumberField(label: "Offset X", value: b.offset.x, unit: "m")
                NumberField(label: "Offset Y", value: b.offset.y, unit: "m")
                NumberField(label: "Offset Z", value: b.offset.z, unit: "m")
                NumberField(label: "Rotation", value: b.rotY, unit: "°")
                LabeledContent("Opacity") { Slider(value: b.opacity, in: 0.05...1) }
                Toggle("Show room", isOn: b.visible)
                Button("Remove Room", role: .destructive) { store.project.room = nil }
            }
            .formStyle(.grouped)
            .frame(width: 320)
        }
    }
}

struct LEDSceneView: NSViewRepresentable {
    let project: LEDProject
    let report: Report
    let colorMode: SceneColorMode
    let showPaths: Bool
    let selectedWall: UUID?
    let controller: SceneController
    let onPick: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = context.coordinator.scene
        v.backgroundColor = NSColor(white: 0.08, alpha: 1)
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = false
        v.pointOfView = context.coordinator.cameraNode
        v.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:))))
        context.coordinator.view = v
        controller.view = v
        controller.fit = { [weak coord = context.coordinator] p in coord?.place(p) }
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        c.onPick = onPick
        c.rebuild(project: project, report: report, mode: colorMode, paths: showPaths, selected: selectedWall)
    }

    final class Coordinator: NSObject {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        let wallsNode = SCNNode()
        let roomNode = SCNNode()
        weak var view: SCNView?
        var onPick: (UUID) -> Void = { _ in }
        private var fitted = false
        private var roomPath: String?
        private var lastKey: Int?

        override init() {
            super.init()
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.zFar = 2000
            cameraNode.camera?.zNear = 0.05
            cameraNode.position = SCNVector3(0, 6, 22)
            scene.rootNode.addChildNode(cameraNode)
            let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 500
            let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 900
            key.eulerAngles = SCNVector3(-0.8, 0.5, 0)
            scene.rootNode.addChildNode(amb); scene.rootNode.addChildNode(key)
            scene.rootNode.addChildNode(Self.grid())
            scene.rootNode.addChildNode(Self.person())
            scene.rootNode.addChildNode(wallsNode)
            scene.rootNode.addChildNode(roomNode)
        }

        static func grid() -> SCNNode {
            var v: [SCNVector3] = [], idx: [Int32] = []
            for i in -50...50 {
                let f = CGFloat(i)
                v += [SCNVector3(f, 0, -50), SCNVector3(f, 0, 50), SCNVector3(-50, 0, f), SCNVector3(50, 0, f)]
            }
            idx = (0..<Int32(v.count)).map { $0 }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            g.firstMaterial?.diffuse.contents = NSColor(white: 0.22, alpha: 1)
            g.firstMaterial?.lightingModel = .constant
            return SCNNode(geometry: g)
        }

        static func person() -> SCNNode {
            let n = SCNNode(geometry: SCNCapsule(capRadius: 0.22, height: 1.8))
            n.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.55, alpha: 1)
            n.position = SCNVector3(0, 0.9, 4)
            return n
        }

        func rebuild(project: LEDProject, report: Report, mode: SceneColorMode, paths: Bool, selected: UUID?) {
            var h = Hasher()
            h.combine(project.walls); h.combine(project.panelTypes); h.combine(mode); h.combine(paths); h.combine(selected)
            h.combine(project.processors); h.combine(project.settings)
            let key = h.finalize()
            if key != lastKey {
                lastKey = key
                buildWalls(project, report, mode, paths, selected)
            }
            updateRoom(project.room)
            if !fitted, !project.walls.isEmpty {
                fitted = true
                // Wait for the view to have its real size before framing.
                DispatchQueue.main.async { [weak self] in self?.place(.fit) }
            }
        }

        private func buildWalls(_ project: LEDProject, _ report: Report, _ mode: SceneColorMode, _ paths: Bool, _ selected: UUID?) {
            wallsNode.childNodes.forEach { $0.removeFromParentNode() }
            let geo = Geometry.compute(project)
            for wall in project.walls {
                guard let g = geo[wall.id], let wr = report.walls[wall.id] else { continue }
                let kind: WiringKind? = mode == .data ? .data : mode == .power ? .power : nil
                var runOf: [Cell: Int] = [:]
                if let kind {
                    let runs = kind == .data ? wr.dataRuns.map(\.cells) : wr.powerRuns.map(\.cells)
                    for (i, r) in runs.enumerated() { for c in r { runOf[c] = i } }
                }
                let dim = selected != nil && selected != wall.id
                var materials: [String: SCNMaterial] = [:]
                func material(_ color: NSColor, _ key: String) -> SCNMaterial {
                    if let m = materials[key] { return m }
                    let m = SCNMaterial()
                    m.diffuse.contents = dim ? color.blended(withFraction: 0.6, of: .black) : color
                    m.roughness.contents = 0.6
                    materials[key] = m
                    return m
                }
                let container = SCNNode()
                container.name = wall.id.uuidString
                let box = SCNBox(width: g.size.w - 0.004, height: g.size.h - 0.004, length: g.size.d, chamferRadius: 0)
                for c in 0..<wall.cols {
                    for r in 0..<wall.rows where wall.isEnabled(Cell(c, r)) {
                        let color: NSColor, mkey: String
                        if let kind {
                            if let i = runOf[Cell(c, r)] { color = RunPalette.ns(i, kind); mkey = "r\(i)" } else { color = NSColor(white: 0.2, alpha: 1); mkey = "none" }
                        } else {
                            let base = NSColor(hex: wall.colorHex)
                            color = (c + r) % 2 == 0 ? base : base.blended(withFraction: 0.15, of: .black) ?? base; mkey = "w\((c + r) % 2)"
                        }
                        let geom = box.copy() as! SCNBox
                        geom.materials = [material(color, mkey)]
                        let n = SCNNode(geometry: geom)
                        let m = g.panel(c, r) * M4.translate(g.size.w / 2, g.size.h / 2, -g.size.d / 2)
                        n.simdTransform = simd_float4x4(m.columns.0.float, m.columns.1.float, m.columns.2.float, m.columns.3.float)
                        container.addChildNode(n)
                    }
                }
                let flat = container.flattenedClone()
                flat.name = wall.id.uuidString
                wallsNode.addChildNode(flat)

                if let kind, paths {
                    let runs = kind == .data ? wr.dataRuns.map(\.cells) : wr.powerRuns.map(\.cells)
                    for run in runs where run.count > 1 {
                        let pts = run.map { c -> SCNVector3 in let p = g.panel(c.c, c.r).apply(SIMD3(g.size.w / 2, g.size.h / 2, 0.01)); return SCNVector3(p.x, p.y, p.z) }
                        let idx: [Int32] = (0..<Int32(pts.count - 1)).flatMap { [$0, $0 + 1] }
                        let lg = SCNGeometry(sources: [SCNGeometrySource(vertices: pts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
                        lg.firstMaterial?.diffuse.contents = NSColor.white
                        lg.firstMaterial?.lightingModel = .constant
                        wallsNode.addChildNode(SCNNode(geometry: lg))
                        let dot = SCNNode(geometry: SCNSphere(radius: min(g.size.w, g.size.h) * 0.09))
                        dot.geometry?.firstMaterial?.diffuse.contents = NSColor.white
                        dot.position = pts[0]
                        wallsNode.addChildNode(dot)
                    }
                }
            }
        }

        private func updateRoom(_ room: RoomModelRef?) {
            guard let room else { roomNode.childNodes.forEach { $0.removeFromParentNode() }; roomPath = nil; return }
            if roomPath != room.path {
                roomNode.childNodes.forEach { $0.removeFromParentNode() }
                if let n = RoomLoader.load(URL(fileURLWithPath: room.path)) { roomNode.addChildNode(n) }
                roomPath = room.path
            }
            roomNode.isHidden = !room.visible
            roomNode.scale = SCNVector3(room.scale, room.scale, room.scale)
            roomNode.position = SCNVector3(room.offset.x, room.offset.y, room.offset.z)
            roomNode.eulerAngles = SCNVector3(0, room.rotY * .pi / 180, 0)
            roomNode.opacity = room.opacity
        }

        func place(_ preset: CameraPreset) {
            let (minB, maxB) = wallsNode.boundingBox
            let empty = minB.x > maxB.x
            let c = empty ? SCNVector3(0, 2, 0) : SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
            let width = empty ? 10 : max(maxB.x - minB.x, maxB.z - minB.z), height = empty ? 5 : maxB.y - minB.y
            // Fit both the width and the height into the view, whatever its aspect ratio.
            let vfov = (cameraNode.camera?.fieldOfView ?? 60) * .pi / 180
            let bounds = view?.bounds.size ?? CGSize(width: 16, height: 9)
            let aspect = bounds.height > 0 ? bounds.width / bounds.height : 16 / 9
            let hfov = 2 * atan(tan(vfov / 2) * aspect)
            let d = max((width / 2) / tan(hfov / 2), (height / 2) / tan(vfov / 2)) * 1.25 + (empty ? 0 : (maxB.z - minB.z) / 2)
            switch preset {
            case .front: cameraNode.position = SCNVector3(c.x, c.y, c.z + d)
            case .top: cameraNode.position = SCNVector3(c.x, c.y + d, c.z + 0.01)
            case .side: cameraNode.position = SCNVector3(c.x + d, c.y, c.z)
            case .fit: cameraNode.position = SCNVector3(c.x, c.y + d * 0.25, c.z + d)
            }
            cameraNode.look(at: c)
            view?.pointOfView = cameraNode
            view?.defaultCameraController.target = c
        }

        @objc func click(_ g: NSClickGestureRecognizer) {
            guard let v = view else { return }
            let hits = v.hitTest(g.location(in: v), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .rootNode: wallsNode])
            var n = hits.first?.node
            while let node = n, node.name == nil { n = node.parent }
            if let name = n?.name, let id = UUID(uuidString: name) { onPick(id) }
        }
    }
}

private extension SIMD4 where Scalar == Double {
    var float: SIMD4<Float> { SIMD4<Float>(Float(x), Float(y), Float(z), Float(w)) }
}
