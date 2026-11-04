import SwiftUI
import WallKit

@main
struct LEDWallToolApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup("LED Wall Tool") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1520, height: 940)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Project Settings…") { NotificationCenter.default.post(name: .showProjectSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { store.newProject() }.keyboardShortcut("n")
                Button("Open…") { store.open() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }.keyboardShortcut("s")
                Button("Save As…") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .printItem) {
                Button("Print Drawings…") { Exporters.printDrawings(store) }.keyboardShortcut("p")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undoManager.undo() }.keyboardShortcut("z")
                Button("Redo") { store.undoManager.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Export") {
                Button("Drawing Set…") { store.showExport = true }.keyboardShortcut("e")
                Button("Drawings (PDF) with Last Settings…") { Exporters.exportDrawingsPDF(store) }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Pixel Maps (PNG)…") { Exporters.exportPixelMaps(store) }
                Button("Resource Report (CSV)…") { Exporters.exportCSV(store) }
                Divider()
                Button("Export Panel Library…") { Exporters.exportPanelLibrary(store) }
                Button("Import Panel Library…") { Exporters.importPanelLibrary(store) }
            }
        }
    }
}

enum Workspace: String, CaseIterable, Identifiable {
    case map = "2D Map", scene = "3D", pixel = "Processor Map", comp = "Comp & Mask", resources = "Resources"
    var id: String { rawValue }
    /// 3D is hidden for now; it still opens with `-workspace 3D`.
    static let visible: [Workspace] = [.map, .pixel, .comp, .resources]
    var icon: String {
        switch self {
        case .map: return "square.grid.3x3"
        case .scene: return "cube.transparent"
        case .pixel: return "rectangle.dashed"
        case .comp: return "photo.on.rectangle"
        case .resources: return "gauge.with.dots.needle.33percent"
        }
    }
}

extension Notification.Name {
    static let showProjectSettings = Notification.Name("showProjectSettings")
}

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var selection: Selection? = .project
    @State private var workspace: Workspace = .map
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            Group {
                switch workspace {
                case .map: MapView(selection: $selection)
                case .scene: SceneWorkspace(selection: $selection)
                case .pixel: PixelMapView(selection: $selection)
                case .comp: CompView(selection: $selection)
                case .resources: ResourcesView(selection: $selection, workspace: $workspace)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
            .inspector(isPresented: $showInspector) {
                InspectorView(selection: $selection)
                    .inspectorColumnWidth(min: 270, ideal: 300, max: 440)
            }
        }
        .navigationTitle(store.project.name)
        .navigationSubtitle(store.fileURL?.lastPathComponent ?? "Not saved")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $workspace) {
                    ForEach(Workspace.visible) { w in
                        if w == .resources, store.report.errorCount > 0 {
                            Text("\(w.rawValue) (\(store.report.errorCount))").tag(w)
                        } else {
                            Text(w.rawValue).tag(w)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Wall") { selection = .wall(store.addWall()) }
                    Button("Processor") { selection = .processor(store.addProcessor()) }
                    Button("Media Server") { selection = .server(store.addServer()) }
                    Button("Panel Type") { selection = .panelType(store.addPanelType()) }
                } label: { Label("Add", systemImage: "plus") }
                .help("Add a wall, processor, media server or panel type")

                Button { Exporters.printDrawings(store) } label: { Label("Print Drawings", systemImage: "printer") }
                    .help("Print data & power drawings")
                Button { store.showExport = true } label: { Label("Export Drawings", systemImage: "square.and.arrow.up") }
                    .help("Export the drawing set: audience and rear views, schedules, BOM, pixel maps")
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Show or hide the inspector")
            }
        }
        .onChange(of: selection) { _, s in
            if case .wall(let id) = s { store.focusWallID = id }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showProjectSettings)) { _ in selection = .project; showInspector = true }
        .onAppear(perform: applyLaunchArguments)
        .sheet(isPresented: $store.showExport) { ExportView().environmentObject(store) }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        let t = store.report.totals, s = store.project.settings
        // Widest layout that fits wins; narrow windows keep the essentials.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                stat("Panels", t.panels.formatted())
                stat("Pixels", F.mp(t.pixels))
                stat("Weight", F.weight(t.kg))
                stat("Max", F.kw(t.wMax))
                stat("Typ", F.kw(t.wAvg))
                stat("@ \(Int(s.voltage.volts)) V", F.amps(t.wMax / s.voltage.volts))
                stat("208 3Φ", F.amps(Analysis.amps(t.wMax, .threePhase208)) + "/leg")
                stat("Circuits", "\(t.circuits)")
                stat("Data runs", "\(t.dataRuns)")
                Spacer(minLength: 12)
                checks
            }
            HStack(spacing: 14) {
                stat("Panels", t.panels.formatted())
                stat("Weight", F.weight(t.kg))
                stat("Max", F.kw(t.wMax))
                stat("@ \(Int(s.voltage.volts)) V", F.amps(t.wMax / s.voltage.volts))
                stat("Circuits", "\(t.circuits)")
                stat("Runs", "\(t.dataRuns)")
                Spacer(minLength: 12)
                checks
            }
            HStack(spacing: 12) {
                stat("Panels", t.panels.formatted())
                stat("Max", F.kw(t.wMax))
                stat("", F.amps(t.wMax / s.voltage.volts))
                Spacer(minLength: 8)
                checks
            }
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var checks: some View {
        HStack(spacing: 10) {
            if store.report.errorCount > 0 {
                Label("\(store.report.errorCount) errors", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Label("No errors", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if store.report.warningCount > 0 {
                Label("\(store.report.warningCount)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .fixedSize()
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) { Text(k).foregroundStyle(.secondary); Text(v) }
    }
}

extension ContentView {
    /// Command-line conveniences for testing layouts: `-windowSize 1100x720 -workspace 3D -showExport YES`.
    func applyLaunchArguments() {
        let d = UserDefaults.standard
        if let ws = d.string(forKey: "workspace").flatMap(Workspace.init(rawValue:)) { workspace = ws }
        if d.bool(forKey: "showExport") { store.showExport = true }
        if let s = d.string(forKey: "windowSize")?.split(separator: "x").compactMap({ Double($0) }), s.count == 2 {
            DispatchQueue.main.async { NSApp.windows.first { $0.isVisible && $0.frame.width > 400 }?.setContentSize(NSSize(width: s[0], height: s[1])) }
        }
    }
}
