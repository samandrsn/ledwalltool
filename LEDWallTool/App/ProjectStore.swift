import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WallKit

extension UTType {
    static let ledWallProject = UTType(exportedAs: "org.samanderson.ledwalltool.project", conformingTo: .json)
}

enum Selection: Hashable {
    case project
    case wall(UUID)
    case processor(UUID)
    case server(UUID)
    case panelType(UUID)
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published var project: LEDProject {
        didSet {
            guard project != oldValue else { return }
            report = Analysis.analyze(project)
            if gestureSnapshot == nil { registerUndo(oldValue) }
            isDirty = true
            scheduleAutosave()
        }
    }
    @Published private(set) var report: Report
    @Published var fileURL: URL?
    @Published var isDirty = false
    /// The wall shown in the 2D map (follows sidebar selection of walls).
    @Published var focusWallID: UUID?
    /// Shows the drawing-set export window.
    @Published var showExport = false

    let undoManager = UndoManager()
    private var gestureSnapshot: LEDProject?
    private var autosaveTask: Task<Void, Never>?

    /// Set by the `-demo YES` launch flag: show the demo set and leave the autosave alone.
    private let autosaveDisabled = UserDefaults.standard.bool(forKey: "demo")

    init() {
        let p = autosaveDisabled ? .demo() : Self.loadAutosave() ?? .starter()
        project = p
        report = Analysis.analyze(p)
        focusWallID = p.walls.first?.id
    }

    // MARK: Undo

    private func registerUndo(_ old: LEDProject) {
        undoManager.registerUndo(withTarget: self) { $0.project = old }
    }

    /// Drags (painting runs, moving canvases) become one undo step.
    func beginGesture() { if gestureSnapshot == nil { gestureSnapshot = project } }
    func endGesture() {
        guard let snap = gestureSnapshot else { return }
        gestureSnapshot = nil
        if snap != project { registerUndo(snap) }
    }

    // MARK: Files

    static var autosaveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LEDWallTool", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Autosave.ledwall")
    }
    static func loadAutosave() -> LEDProject? {
        guard let d = try? Data(contentsOf: autosaveURL) else { return nil }
        return try? JSONDecoder().decode(LEDProject.self, from: d)
    }
    private func scheduleAutosave() {
        guard !autosaveDisabled else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            try? self.encoded().write(to: Self.autosaveURL, options: .atomic)
        }
    }
    private func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(project)
    }

    func newProject() {
        guard confirmDiscard() else { return }
        replace(.starter(), url: nil)
    }

    /// A sample arena set to explore the app with.
    func openDemo() {
        guard confirmDiscard() else { return }
        replace(.demo(), url: nil)
    }

    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.ledWallProject, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { replace(try JSONDecoder().decode(LEDProject.self, from: Data(contentsOf: url)), url: url) }
        catch { alert("Couldn't open \(url.lastPathComponent)", error.localizedDescription) }
    }

    func save() { if let url = fileURL { write(to: url) } else { saveAs() } }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.ledWallProject]
        panel.nameFieldStringValue = project.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do { try encoded().write(to: url, options: .atomic); fileURL = url; isDirty = false }
        catch { alert("Couldn't save", error.localizedDescription) }
    }

    private func replace(_ p: LEDProject, url: URL?) {
        undoManager.removeAllActions()
        project = p
        undoManager.removeAllActions()
        fileURL = url; isDirty = false
        focusWallID = p.walls.first?.id
    }

    private func confirmDiscard() -> Bool {
        guard isDirty, fileURL != nil else { return true }
        let a = NSAlert()
        a.messageText = "Discard unsaved changes to “\(project.name)”?"
        a.addButton(withTitle: "Discard"); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func alert(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info; a.runModal()
    }

    // MARK: Editing helpers

    func binding<T>(wall id: UUID, _ kp: WritableKeyPath<Wall, T>, default d: T) -> Binding<T> {
        Binding(get: { self.project.walls.first { $0.id == id }?[keyPath: kp] ?? d },
                set: { v in if let i = self.project.wallIndex(id) { self.project.walls[i][keyPath: kp] = v } })
    }
    func updateWall(_ id: UUID, _ f: (inout Wall) -> Void) { if let i = project.wallIndex(id) { f(&project.walls[i]) } }
    func updateProcessor(_ id: UUID, _ f: (inout Processor) -> Void) { if let i = project.processorIndex(id) { f(&project.processors[i]) } }

    @discardableResult
    func addWall() -> UUID {
        let n = project.walls.count
        var w = Wall(name: "Wall \(n + 1)", colorHex: Wall.palette[n % Wall.palette.count], panelTypeID: project.panelTypes.first?.id, cols: 12, rows: 6)
        if let last = project.walls.last, let pt = project.panelType(last.panelTypeID) {
            w.position = Vec3(last.position.x + Double(last.cols) * pt.spec.mmW / 1000 + 1, 0, 0)
        }
        w.processorID = project.processors.first?.id
        placeCanvas(&w)
        project.walls.append(w)
        focusWallID = w.id
        return w.id
    }

    @discardableResult
    func addAttached(to parentID: UUID, edge: AttachEdge) -> UUID? {
        guard let parent = project.walls.first(where: { $0.id == parentID }) else { return nil }
        let n = project.walls.count
        let top = edge == .top
        var w = Wall(name: "\(parent.name) \(top ? "Header" : edge == .left ? "L Wing" : "R Wing")", colorHex: Wall.palette[n % Wall.palette.count],
                     panelTypeID: parent.panelTypeID, cols: top ? parent.cols : 4, rows: top ? 2 : parent.rows)
        w.attach = Attachment(wallID: parent.id, edge: edge, angle: top ? 0 : 90)
        w.processorID = parent.processorID
        w.rigging = top ? .flown : parent.rigging
        placeCanvas(&w)
        project.walls.append(w)
        focusWallID = w.id
        return w.id
    }

    @discardableResult
    func duplicateWall(_ id: UUID) -> UUID? {
        guard var w = project.walls.first(where: { $0.id == id }) else { return nil }
        w.id = UUID(); w.name += " copy"; w.attach = nil
        if let pt = project.panelType(w.panelTypeID) { w.position.x += Double(w.cols) * pt.spec.mmW / 1000 + 1 }
        placeCanvas(&w)
        project.walls.append(w)
        focusWallID = w.id
        return w.id
    }

    func deleteWall(_ id: UUID) {
        project.walls.removeAll { $0.id == id }
        for i in project.walls.indices where project.walls[i].attach?.wallID == id { project.walls[i].attach = nil }
        if focusWallID == id { focusWallID = project.walls.first?.id }
    }

    @discardableResult
    func addProcessor(_ model: ProcessorModel = .bromptonSX40) -> UUID {
        var p = Processor(index: project.processors.count, model: model)
        p.sourceID = project.servers.first?.id
        p.sourceOutput = min(project.processors.count, (project.servers.first?.outputs.count ?? 1) - 1)
        project.processors.append(p)
        return p.id
    }

    func deleteProcessor(_ id: UUID) {
        project.processors.removeAll { $0.id == id }
        for i in project.walls.indices {
            if project.walls[i].processorID == id { project.walls[i].processorID = nil }
            for j in (project.walls[i].split?.sections ?? []).indices where project.walls[i].split!.sections[j].processorID == id {
                project.walls[i].split!.sections[j].processorID = nil
            }
            for j in (project.walls[i].zones ?? []).indices where project.walls[i].zones![j].processorID == id {
                project.walls[i].zones![j].processorID = nil
            }
        }
    }

    @discardableResult
    func addServer() -> UUID {
        let s = MediaServer(name: "Media Server \(project.servers.count + 1)")
        project.servers.append(s)
        return s.id
    }

    func deleteServer(_ id: UUID) {
        project.servers.removeAll { $0.id == id }
        for i in project.processors.indices where project.processors[i].sourceID == id { project.processors[i].sourceID = nil }
    }

    @discardableResult
    func addPanelType(_ spec: PanelSpec = PanelLibrary.all[0]) -> UUID {
        let t = PanelType(spec)
        project.panelTypes.append(t)
        return t.id
    }

    func deletePanelType(_ id: UUID) {
        guard !project.walls.contains(where: { $0.panelTypeID == id }) else { return }
        project.panelTypes.removeAll { $0.id == id }
    }

    /// Puts each section of a wall in the first free spot on its processor's canvas (top-left first),
    /// falling back to below everything when nothing fits.
    /// `only` limits it to those zones (the wall's own id = its main feed), leaving the rest where they are.
    func placeCanvas(_ w: inout Wall, only: Set<UUID>? = nil) {
        guard let pt = project.panelType(w.panelTypeID) else { return }
        typealias R = (x: Int, y: Int, w: Int, h: Int)
        var placed: [UUID: [R]] = [:]          // processor → rects already on its canvas
        for o in project.walls where o.id != w.id {
            guard let opt = project.panelType(o.panelTypeID) else { continue }
            for of in o.feeds where !of.isEmpty {
                guard let pid = of.processorID else { continue }
                placed[pid, default: []].append((of.canvasX, of.canvasY, of.cols.count * opt.spec.pxW, of.rows.count * opt.spec.pxH))
            }
        }
        let feeds = w.feeds
        let moving = Set(feeds.filter { only == nil || only!.contains($0.zoneID ?? w.id) }.map(\.index))
        for f in feeds where !f.isEmpty && !moving.contains(f.index) {
            if let pid = f.processorID { placed[pid, default: []].append((f.canvasX, f.canvasY, f.cols.count * pt.spec.pxW, f.rows.count * pt.spec.pxH)) }
        }
        for f in feeds where !f.isEmpty && moving.contains(f.index) {
            guard let pid = f.processorID, let proc = project.processors.first(where: { $0.id == pid }) else { continue }
            let W = f.cols.count * pt.spec.pxW, H = f.rows.count * pt.spec.pxH
            let rects = placed[pid] ?? []
            func free(_ x: Int, _ y: Int) -> Bool {
                x + W <= proc.inputW && y + H <= proc.inputH &&
                    !rects.contains { x < $0.x + $0.w && $0.x < x + W && y < $0.y + $0.h && $0.y < y + H }
            }
            let xs = Set([0] + rects.map { $0.x + $0.w } + rects.map(\.x)), ys = Set([0] + rects.map { $0.y + $0.h } + rects.map(\.y))
            let spot = ys.sorted().lazy.flatMap { y in xs.sorted().lazy.map { (x: $0, y: y) } }.first { free($0.x, $0.y) }
                ?? (0, rects.map { $0.y + $0.h }.max() ?? 0)
            w.setCanvas(feed: f.index, x: spot.x, y: spot.y)
            placed[pid, default: []].append((spot.x, spot.y, W, H))
        }
    }

    /// Hands panels to a processor (painting in the 2D map, or moving a run). New zones get a canvas spot.
    func assign(_ cells: Set<Cell>, wall id: UUID, to processor: UUID?) {
        guard var w = project.walls.first(where: { $0.id == id }) else { return }
        let before = Set(w.zoneList.map(\.id))
        w.assign(cells, to: processor)
        let added = Set(w.zoneList.map(\.id)).subtracting(before)
        if !added.isEmpty { placeCanvas(&w, only: added) }
        if w.data.custom {
            // Hand-wired runs can't cross processors: drop moved panels from runs that now span two.
            let feedOf = Dictionary(uniqueKeysWithValues: w.feeds.flatMap { f in f.cells.map { ($0, f.index) } })
            for i in w.data.runs.indices {
                guard let first = w.data.runs[i].cells.first else { continue }
                let f = feedOf[first] ?? 0
                w.data.runs[i].cells.removeAll { (feedOf[$0] ?? 0) != f }
            }
        }
        updateWall(id) { $0 = w }
    }

    /// Splits a wall evenly between its processor and `count - 1` more (reusing other processors, then adding new ones).
    func splitWall(_ id: UUID, into count: Int, axis: SplitAxis) {
        guard var w = project.walls.first(where: { $0.id == id }) else { return }
        let n = axis == .columns ? w.cols : w.rows
        let count = max(1, min(count, n))
        w.split = nil; w.zones = nil
        if w.data.custom { w.data.custom = false; w.data.runs = [] }
        guard count > 1 else { placeCanvas(&w); updateWall(id) { $0 = w }; return }
        var pool = project.processors.map(\.id).filter { $0 != w.processorID }
        if w.processorID == nil { w.processorID = project.processors.first?.id }
        var zones: [WallZone] = []
        for k in 1..<count {
            let pid = pool.isEmpty ? addProcessor() : pool.removeFirst()
            let lo = Int((Double(n) * Double(k) / Double(count)).rounded()), hi = Int((Double(n) * Double(k + 1) / Double(count)).rounded())
            var cells = Set<Cell>()
            for a in lo..<hi { for b in 0..<(axis == .columns ? w.rows : w.cols) { cells.insert(axis == .columns ? Cell(a, b) : Cell(b, a)) } }
            zones.append(WallZone(processorID: pid, cells: cells))
        }
        w.zones = zones
        placeCanvas(&w)
        updateWall(id) { $0 = w }
    }

    /// Skyline packing, largest first: each wall section goes to the lowest, then leftmost, spot it fits.
    func autoPack(_ procID: UUID) {
        guard let proc = project.processors.first(where: { $0.id == procID }), let pr = report.processors[procID] else { return }
        var placed: [(x: Int, y: Int, w: Int, h: Int)] = []
        let items = pr.slots.compactMap { s -> (Int, Int, Int, Int)? in
            guard let i = project.wallIndex(s.wallID) else { return nil }
            return (i, s.feed, s.w, s.h)
        }.sorted { $0.2 * $0.3 > $1.2 * $1.3 }
        var p = project
        for (i, feed, W, H) in items {
            var best: (score: Int, x: Int, y: Int)?
            for x in [0] + placed.map({ $0.x + $0.w }) {
                let y = placed.filter { $0.x < x + W && x < $0.x + $0.w }.map { $0.y + $0.h }.max() ?? 0
                let fits = x + W <= proc.inputW && y + H <= proc.inputH
                let score = (fits ? 0 : 1_000_000_000) + y * 100_000 + x
                if best == nil || score < best!.score { best = (score, x, y) }
            }
            p.walls[i].setCanvas(feed: feed, x: best!.x, y: best!.y)
            placed.append((best!.x, best!.y, W, H))
        }
        project = p
    }

    /// Freeze the current generated runs so they can be hand-edited.
    func makeCustom(_ wallID: UUID, _ kind: WiringKind) {
        guard let wr = report.walls[wallID] else { return }
        let runs: [Run] = kind == .data
            ? wr.dataRuns.map { Run(cells: $0.cells, port: $0.explicitPort) }
            : wr.powerRuns.map { Run(cells: $0.cells) }
        updateWall(wallID) { w in
            guard !w[kind].custom else { return }
            w[kind].runs = runs
            w[kind].custom = true
        }
    }
}
