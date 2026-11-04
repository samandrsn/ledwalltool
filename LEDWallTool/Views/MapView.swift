import AppKit
import SwiftUI
import WallKit

enum MapLayer: String, CaseIterable, Identifiable {
    case data = "Data", power = "Power", processors = "Processors", structure = "Structure"
    var id: String { rawValue }
    var kind: WiringKind? { self == .data ? .data : self == .power ? .power : nil }
}

struct HingeEdit: Identifiable {
    enum Axis { case column, row }
    let axis: Axis
    let index: Int
    let anchor: CGPoint
    var id: String { "\(axis)-\(index)" }
}

/// Maps wall cells to points in the map canvas.
struct MapLayout {
    let wall: Wall
    let cw: CGFloat, ch: CGFloat
    let origin: CGPoint
    let size: CGSize
    var fontSize: CGFloat { max(8, min(cw, ch) * 0.2) }

    init(wall: Wall, spec: PanelSpec, available: CGSize, zoom: CGFloat) {
        self.wall = wall
        let margin: CGFloat = 64
        let wmm = CGFloat(wall.cols) * spec.mmW, hmm = CGFloat(wall.rows) * spec.mmH
        let fit = max(0.01, min((available.width - margin * 2) / wmm, (available.height - margin * 2) / hmm))
        let s = fit * zoom
        cw = spec.mmW * s; ch = spec.mmH * s
        let content = CGSize(width: CGFloat(wall.cols) * cw, height: CGFloat(wall.rows) * ch)
        size = CGSize(width: max(available.width, content.width + margin * 2), height: max(available.height, content.height + margin * 2))
        origin = CGPoint(x: (size.width - content.width) / 2, y: (size.height - content.height) / 2)
    }

    func rect(_ c: Cell) -> CGRect { CGRect(x: origin.x + CGFloat(c.c) * cw, y: origin.y + CGFloat(wall.rows - 1 - c.r) * ch, width: cw, height: ch) }
    func center(_ c: Cell) -> CGPoint { let r = rect(c); return CGPoint(x: r.midX, y: r.midY) }
    func cell(at p: CGPoint) -> Cell? {
        let c = Int(floor((p.x - origin.x) / cw)), rr = Int(floor((p.y - origin.y) / ch))
        guard c >= 0, c < wall.cols, rr >= 0, rr < wall.rows else { return nil }
        return Cell(c, wall.rows - 1 - rr)
    }
    func colHingeRect(_ i: Int) -> CGRect {
        let w = min(cw * 0.8, 46.0)
        return CGRect(x: origin.x + CGFloat(i + 1) * cw - w / 2, y: origin.y + CGFloat(wall.rows) * ch + 8, width: w, height: 18)
    }
    func rowHingeRect(_ i: Int) -> CGRect {
        CGRect(x: origin.x - 52, y: origin.y + CGFloat(wall.rows - 1 - i) * ch - 9, width: 44, height: 18)
    }
}

struct MapView: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selection: Selection?
    @State private var layer: MapLayer = .data
    @State private var selectedRun = 0
    @State private var zoom: CGFloat = 1
    @State private var hinge: HingeEdit?
    @State private var paint: PaintMode?
    @State private var lastCell: Cell?
    @State private var touched = Set<Cell>()
    @State private var pendingHinge: HingeEdit?

    @State private var paintProcessor: UUID?

    enum PaintMode { case cutOut(Bool), wire, erase, assign(UUID?), none }

    private var wall: Wall? { store.project.walls.first { $0.id == store.focusWallID } ?? store.project.walls.first }

    var body: some View {
        VStack(spacing: 0) {
            if let wall, let wr = store.report.walls[wall.id] {
                toolbar(wall, wr)
                GeometryReader { geo in
                    let layout = MapLayout(wall: wall, spec: wr.spec, available: geo.size, zoom: zoom)
                    ScrollView([.horizontal, .vertical]) {
                        Canvas { ctx, _ in draw(ctx, layout, wall, wr) }
                            .frame(width: layout.size.width, height: layout.size.height)
                            .contentShape(Rectangle())
                            .gesture(dragGesture(layout, wall, wr))
                            .overlay(alignment: .topLeading) {
                                Color.clear.frame(width: 1, height: 1)
                                    .offset(x: hinge?.anchor.x ?? 0, y: hinge?.anchor.y ?? 0)
                                    .popover(item: $hinge, arrowEdge: .bottom) { h in HingePopover(wallID: wall.id, edit: h) }
                            }
                    }
                    .background(Color(white: 0.075))
                    .gesture(MagnifyGesture().onChanged { zoom = min(8, max(0.3, zoom * $0.magnification)) })
                }
                if let kind = layer.kind { runsBar(wall, wr, kind) }
            } else {
                ContentUnavailableView("No Walls", systemImage: "square.grid.3x3", description: Text("Add a wall from the sidebar or the + button in the toolbar."))
            }
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private func toolbar(_ wall: Wall, _ wr: WallReport) -> some View {
        ViewBar {
            Picker("Wall", selection: Binding(get: { wall.id }, set: { store.focusWallID = $0; selection = .wall($0); selectedRun = 0 })) {
                ForEach(store.project.walls) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().fixedSize()
            Picker("Layer", selection: $layer) { ForEach(MapLayer.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: layer) { _, _ in selectedRun = 0 }
            if let kind = layer.kind {
                Picker("Mode", selection: Binding(get: { wall[kind].custom }, set: { custom in
                    if custom { store.makeCustom(wall.id, kind) } else { store.updateWall(wall.id) { $0[kind].custom = false } }
                })) { Text("Auto").tag(false); Text("Custom").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ControlGroup {
                Button { zoom = max(0.3, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                Button { zoom = 1 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Fit wall")
                Button { zoom = min(8, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            }
            .fixedSize()
            if let kind = layer.kind {
                if wall[kind].custom { customControls(wall, wr, kind) } else { autoControls(wall, wr, kind) }
            } else if layer == .processors {
                let target = paintProcessor ?? wall.processorID
                Picker("Paint with", selection: Binding(get: { target }, set: { paintProcessor = $0 })) {
                    ForEach(store.project.processors) { pr in
                        Text(pr.id == wall.processorID ? "\(pr.name) (main)" : pr.name).tag(Optional(pr.id))
                    }
                }
                .fixedSize()
                Text("Drag across panels to hand them to that processor. Each processor's panels get their own runs and canvas spot.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                Text("Click or drag panels to cut them out or restore them. Click an angle tag to set a hinge or curve block.")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    @ViewBuilder
    private func autoControls(_ wall: Wall, _ wr: WallReport, _ kind: WiringKind) -> some View {
        let pat = store.binding(wall: wall.id, kind == .data ? \Wall.data.pattern : \Wall.power.pattern, default: RunPattern())
        let cap = kind == .data ? wr.dataCap : wr.powerCap
        Picker("Pattern", selection: pat.preset) { ForEach(PatternPreset.allCases) { Text($0.label).tag($0) } }
            .fixedSize()
        Picker("Start", selection: pat.start) { ForEach(StartCorner.allCases) { Text($0.label).tag($0) } }
            .fixedSize()
        if pat.wrappedValue.preset != .recommend {
            Picker("Runs", selection: pat.chunk) { ForEach(Chunking.allCases) { Text($0.label).tag($0) } }
                .labelsHidden().fixedSize()
        }
        LabeledContent("Max per run") {
            CommitField(label: "Max", value: Binding(get: { Double(pat.wrappedValue.maxPerRun) }, set: { pat.wrappedValue.maxPerRun = max(0, Int($0.rounded())) }), integer: true).frame(width: 44).multilineTextAlignment(.trailing)
        }
        .fixedSize()
        Text(kind == .data && wall.isSplit ? "\(wall.feeds.count) processor sections · \(wr.dataRuns.count) ports, patterned per section"
             : pat.wrappedValue.preset == .recommend ? Routing.recommend(wall, cap: cap, pattern: pat.wrappedValue).summary : "Up to \(cap) panels per \(kind == .data ? "port" : "circuit")")
            .foregroundStyle(.secondary).font(.callout)
    }

    @ViewBuilder
    private func customControls(_ wall: Wall, _ wr: WallReport, _ kind: WiringKind) -> some View {
        let runs = wall[kind].runs
        let hasRun = runs.indices.contains(selectedRun)
        Button { store.updateWall(wall.id) { $0[kind].runs.append(Run()) }; selectedRun = runs.count } label: { Label("New Run", systemImage: "plus") }
        Button("Reverse") { editRun(wall.id, kind) { $0.cells.reverse() } }.disabled(!hasRun)
        Button("Clear") { editRun(wall.id, kind) { $0.cells = [] } }.disabled(!hasRun)
        Button("Delete Run") { deleteSelectedRun(wall.id, kind) }.disabled(!hasRun)
        let runProc = runs[safe: selectedRun]?.cells.first.flatMap { wall.feeds[safe: wall.feedIndex($0)]?.processorID } ?? wall.processorID
        if kind == .data, hasRun, let proc = store.project.processors.first(where: { $0.id == runProc }), let pr = store.report.processors[proc.id] {
            Picker("Port", selection: Binding(get: { runs[safe: selectedRun]?.port }, set: { v in editRun(wall.id, .data) { $0.port = v } })) {
                Text("Auto").tag(Int?.none)
                ForEach(0..<max(pr.hardMax, 1), id: \.self) { Text(proc.portLabel($0)).tag(Optional($0)) }
            }
            .fixedSize()
        }
        Text("Drag across panels to add them to the selected run (max \(kind == .data ? wr.dataCap : wr.powerCap)). ⌥-drag removes.")
            .foregroundStyle(.secondary).font(.callout)
    }

    /// Edits one hand-wired run, reading the wall fresh so a stale selection can never index past the end.
    private func editRun(_ wallID: UUID, _ kind: WiringKind, _ index: Int? = nil, _ f: @escaping (inout Run) -> Void) {
        let i = index ?? selectedRun
        store.updateWall(wallID) { w in if w[kind].runs.indices.contains(i) { f(&w[kind].runs[i]) } }
    }

    private func deleteSelectedRun(_ wallID: UUID, _ kind: WiringKind) {
        var remaining = 0
        store.updateWall(wallID) { w in
            if w[kind].runs.indices.contains(selectedRun) { w[kind].runs.remove(at: selectedRun) }
            remaining = w[kind].runs.count
        }
        selectedRun = min(selectedRun, max(0, remaining - 1))
    }

    private func runsBar(_ wall: Wall, _ wr: WallReport, _ kind: WiringKind) -> some View {
        let cap = kind == .data ? wr.dataCap : wr.powerCap
        let items: [(String, Int, String)] = kind == .data
            ? wr.dataRuns.map { ($0.label, $0.cells.count, "\(Int($0.loadPercent.rounded()))%") }
            : wr.powerRuns.map { ($0.label, $0.cells.count, F.amps($0.amps) + ($0.phase.map { " \($0)" } ?? "")) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    let over = items[i].1 > cap
                    Button { selectedRun = i } label: {
                        HStack(spacing: 6) {
                            Circle().fill(RunPalette.color(i, kind)).frame(width: 9, height: 9)
                            Text("\(items[i].0) · \(items[i].1) · \(items[i].2)").monospacedDigit()
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(i == selectedRun ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(over ? Color.red : i == selectedRun ? Color.accentColor : .clear, lineWidth: 1.2))
                        .foregroundStyle(over ? Color.red : .primary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if kind == .data, let run = wr.dataRuns[safe: i] {
                            Menu("Move Run to Processor") {
                                ForEach(store.project.processors) { pr in
                                    Button(pr.id == run.processorID ? "\(pr.name) ✓" : pr.name) { store.assign(Set(run.cells), wall: wall.id, to: pr.id) }
                                        .disabled(pr.id == run.processorID)
                                }
                            }
                            if wall.data.custom, let proc = store.project.processors.first(where: { $0.id == run.processorID }), let pr = store.report.processors[proc.id] {
                                Menu("Port") {
                                    Button("Auto") { editRun(wall.id, .data, i) { $0.port = nil } }
                                    ForEach(0..<max(pr.hardMax, 1), id: \.self) { port in
                                        Button(proc.portLabel(port)) { editRun(wall.id, .data, i) { $0.port = port } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .font(.caption)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ L: MapLayout, _ wall: Wall, _ wr: WallReport) {
        let kind = layer.kind
        let runs: [[Cell]] = kind == .data ? wr.dataRuns.map(\.cells) : kind == .power ? wr.powerRuns.map(\.cells) : []
        let labels: [String] = kind == .data ? wr.dataRuns.map(\.label) : kind == .power ? wr.powerRuns.map(\.label) : []
        var at: [Cell: (run: Int, idx: Int)] = [:]
        for (ri, run) in runs.enumerated() { for (pi, c) in run.enumerated() { at[c] = (ri, pi) } }
        let fs = L.fontSize
        let ink = Color(white: 0.92)
        let feeds = wall.feeds
        var feedOf: [Cell: Int] = [:]
        for f in feeds { for c in f.cells { feedOf[c] = f.index } }

        for c in 0..<wall.cols {
            for r in 0..<wall.rows {
                let cell = Cell(c, r), rect = L.rect(cell)
                if !wall.isEnabled(cell) {
                    ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.gray.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
                    var x = Path(); x.move(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.3)); x.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.maxY - rect.height * 0.3))
                    x.move(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.minY + rect.height * 0.3)); x.addLine(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY - rect.height * 0.3))
                    ctx.stroke(x, with: .color(.gray.opacity(0.6)), lineWidth: 0.8)
                    continue
                }
                let a = at[cell]
                let fill: Color
                if layer == .processors { fill = processorColor(feeds[feedOf[cell] ?? 0].processorID).opacity((c + r) % 2 == 0 ? 0.55 : 0.42) }
                else if kind == nil { fill = Color(hex: wall.colorHex).opacity((c + r) % 2 == 0 ? 0.42 : 0.32) }
                else if let a, let kind { fill = RunPalette.color(a.run, kind).opacity(a.run == selectedRun ? 0.6 : 0.34) }
                else { fill = .gray.opacity(0.15) }
                ctx.fill(Path(rect), with: .color(fill))
                ctx.stroke(Path(rect), with: .color(.black.opacity(0.85)), lineWidth: a?.run == selectedRun && kind != nil ? 1.6 : 0.7)
                if let a {
                    ctx.draw(Text("\(a.idx + 1)").font(.system(size: fs, weight: .medium)).foregroundColor(ink.opacity(0.75)),
                             at: CGPoint(x: rect.maxX - fs * 0.35, y: rect.minY + fs * 0.3), anchor: .topTrailing)
                } else if kind != nil {
                    ctx.draw(Text("!").font(.system(size: fs * 1.5, weight: .bold)).foregroundColor(.red), at: CGPoint(x: rect.midX, y: rect.midY))
                }
                if layer == .structure {
                    ctx.draw(Text("\(c + 1).\(r + 1)").font(.system(size: fs * 0.85)).foregroundColor(ink.opacity(0.55)),
                             at: CGPoint(x: rect.minX + fs * 0.35, y: rect.maxY - fs * 0.3), anchor: .bottomLeading)
                }
            }
        }

        if let kind {
            for (ri, run) in runs.enumerated() where !run.isEmpty {
                let pts = run.map(L.center)
                var path = Path(); path.addLines(pts)
                let col = RunPalette.color(ri, kind)
                ctx.stroke(path, with: .color(.black.opacity(0.85)), style: StrokeStyle(lineWidth: fs * 0.32, lineCap: .round, lineJoin: .round))
                ctx.stroke(path, with: .color(col), style: StrokeStyle(lineWidth: fs * 0.17, lineCap: .round, lineJoin: .round))
                if pts.count > 1 { arrow(ctx, from: pts[pts.count - 2], to: pts[pts.count - 1], size: fs * 0.8, color: col) }
                let label = labels[safe: ri] ?? "\(ri + 1)"
                let tag = Text(label).font(.system(size: fs, weight: .bold)).foregroundColor(.black)
                let resolved = ctx.resolve(tag)
                let ts = resolved.measure(in: CGSize(width: 400, height: 100))
                let box = CGRect(x: pts[0].x - ts.width / 2 - fs * 0.45, y: pts[0].y - ts.height / 2 - fs * 0.15, width: ts.width + fs * 0.9, height: ts.height + fs * 0.3)
                ctx.fill(Path(roundedRect: box, cornerRadius: fs * 0.3), with: .color(col))
                ctx.stroke(Path(roundedRect: box, cornerRadius: fs * 0.3), with: .color(.black.opacity(0.8)), lineWidth: 0.7)
                ctx.draw(resolved, at: pts[0])
                if kind == .power, let ph = wr.powerRuns[safe: ri]?.phase {
                    ctx.draw(Text(ph).font(.system(size: fs * 0.8)).foregroundColor(ink), at: CGPoint(x: pts[0].x, y: box.maxY + fs * 0.6))
                }
            }
        }

        // Processor zones: outline every boundary between panels on different processors, label each zone.
        if feeds.count > 1 {
            var edges = Path()
            for c in 0..<wall.cols {
                for r in 0..<wall.rows {
                    let f = feedOf[Cell(c, r)] ?? 0, rect = L.rect(Cell(c, r))
                    if c + 1 < wall.cols, (feedOf[Cell(c + 1, r)] ?? 0) != f { edges.move(to: CGPoint(x: rect.maxX, y: rect.minY)); edges.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
                    if r + 1 < wall.rows, (feedOf[Cell(c, r + 1)] ?? 0) != f { edges.move(to: CGPoint(x: rect.minX, y: rect.minY)); edges.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)) }
                }
            }
            ctx.stroke(edges, with: .color(.black), lineWidth: 5)
            ctx.stroke(edges, with: .color(.white), style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
            for f in feeds where !f.isEmpty {
                let topRow = f.cells.map(\.r).max()!
                let corner = Cell(f.cells.filter { $0.r == topRow }.map(\.c).min()!, topRow)
                let box = L.rect(corner)
                let pname = store.project.processors.first { $0.id == f.processorID }?.name ?? "No processor"
                let label = ctx.resolve(Text("\(f.tag) · \(pname)").font(.system(size: 11, weight: .semibold)).foregroundColor(.white))
                let sz = label.measure(in: CGSize(width: 400, height: 40))
                let pill = CGRect(x: box.minX + 4, y: box.minY + 4, width: sz.width + 14, height: sz.height + 6)
                ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(processorColor(f.processorID).opacity(0.95)))
                ctx.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black.opacity(0.8)), lineWidth: 0.8)
                ctx.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
            }
        }

        // Hinge tags
        for (i, a) in wall.colAngles.enumerated() where a != 0 || layer == .structure { hingeTag(ctx, L.colHingeRect(i), a) }
        for (i, a) in wall.rowAngles.enumerated() where a != 0 || layer == .structure { hingeTag(ctx, L.rowHingeRect(i), a) }
        // Column numbers & row labels
        for c in 0..<wall.cols {
            ctx.draw(Text("\(c + 1)").font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: L.origin.x + (CGFloat(c) + 0.5) * L.cw, y: L.origin.y - 10))
        }
        for r in 0..<wall.rows {
            ctx.draw(Text("R\(r + 1)").font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: L.origin.x + CGFloat(wall.cols) * L.cw + 8, y: L.rect(Cell(0, r)).midY), anchor: .leading)
        }
    }

    private func processorColor(_ id: UUID?) -> Color {
        guard let i = store.project.processors.firstIndex(where: { $0.id == id }) else { return .gray }
        return Color(hex: Wall.palette[i % Wall.palette.count])
    }

    private func hingeTag(_ ctx: GraphicsContext, _ rect: CGRect, _ a: Double) {
        let bg: Color = a > 0 ? Color(red: 0.17, green: 0.55, blue: 0.24) : a < 0 ? Color(red: 0.76, green: 0.25, blue: 0.05) : .clear
        let shape = Path(roundedRect: rect, cornerRadius: 5)
        ctx.fill(shape, with: .color(bg))
        ctx.stroke(shape, with: .color(.white.opacity(a == 0 ? 0.25 : 0.0)), lineWidth: 0.8)
        ctx.draw(Text(a == 0 ? "0°" : "\(a > 0 ? "+" : "")\(fmt(a))°").font(.system(size: 10, weight: .semibold)).foregroundColor(a == 0 ? .secondary : .white),
                 at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func arrow(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, size: CGFloat, color: Color) {
        let ang = atan2(b.y - a.y, b.x - a.x)
        var p = Path()
        p.move(to: CGPoint(x: b.x + cos(ang) * size * 0.6, y: b.y + sin(ang) * size * 0.6))
        p.addLine(to: CGPoint(x: b.x + cos(ang + 2.5) * size, y: b.y + sin(ang + 2.5) * size))
        p.addLine(to: CGPoint(x: b.x + cos(ang - 2.5) * size, y: b.y + sin(ang - 2.5) * size))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
        ctx.stroke(p, with: .color(.black.opacity(0.8)), lineWidth: 0.6)
    }

    // MARK: Interaction

    private func dragGesture(_ L: MapLayout, _ wall: Wall, _ wr: WallReport) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if paint == nil && pendingHinge == nil {
                    begin(at: v.startLocation, L, wall, wr)
                }
                guard pendingHinge == nil, let cell = L.cell(at: v.location) else { return }
                paintTo(cell, wall)
            }
            .onEnded { v in
                if let h = pendingHinge, hypot(v.translation.width, v.translation.height) < 4 { hinge = h }
                pendingHinge = nil
                paint = nil; lastCell = nil; touched = []
                store.endGesture()
            }
    }

    private func begin(at p: CGPoint, _ L: MapLayout, _ wall: Wall, _ wr: WallReport) {
        for i in wall.colAngles.indices where (wall.colAngles[i] != 0 || layer == .structure) && L.colHingeRect(i).insetBy(dx: -3, dy: -3).contains(p) {
            pendingHinge = HingeEdit(axis: .column, index: i, anchor: CGPoint(x: L.colHingeRect(i).midX, y: L.colHingeRect(i).maxY)); return
        }
        for i in wall.rowAngles.indices where (wall.rowAngles[i] != 0 || layer == .structure) && L.rowHingeRect(i).insetBy(dx: -3, dy: -3).contains(p) {
            pendingHinge = HingeEdit(axis: .row, index: i, anchor: CGPoint(x: L.rowHingeRect(i).midX, y: L.rowHingeRect(i).maxY)); return
        }
        guard let cell = L.cell(at: p) else { paint = PaintMode.none; return }
        if let kind = layer.kind {
            if !wall[kind].custom {
                let runs = kind == .data ? wr.dataRuns.map(\.cells) : wr.powerRuns.map(\.cells)
                if let i = runs.firstIndex(where: { $0.contains(cell) }) { selectedRun = i }
                paint = PaintMode.none
                return
            }
            store.beginGesture()
            if wall[kind].runs.isEmpty { store.updateWall(wall.id) { $0[kind].runs = [Run()] } }
            selectedRun = min(selectedRun, max(0, (store.project.walls.first { $0.id == wall.id }?[kind].runs.count ?? 1) - 1))
            paint = NSEvent.modifierFlags.contains(.option) ? .erase : .wire
        } else if layer == .processors {
            store.beginGesture()
            paint = .assign(paintProcessor ?? wall.processorID)
        } else {
            store.beginGesture()
            paint = .cutOut(wall.isEnabled(cell))
        }
    }

    /// Fills grid cells skipped between two drag samples, then applies the paint.
    private func paintTo(_ cell: Cell, _ wall: Wall) {
        guard let mode = paint else { return }
        if case .none = mode { return }
        var steps = [cell]
        if let last = lastCell {
            let dc = cell.c - last.c, dr = cell.r - last.r, n = max(abs(dc), abs(dr))
            if n > 1 { steps = (1...n).map { Cell(last.c + Int((Double(dc * $0) / Double(n)).rounded()), last.r + Int((Double(dr * $0) / Double(n)).rounded())) } }
        }
        lastCell = cell
        let todo = steps.filter { touched.insert($0).inserted }
        guard !todo.isEmpty else { return }
        if case .assign(let pid) = mode { store.assign(Set(todo), wall: wall.id, to: pid); return }
        let kind = layer.kind, run = selectedRun
        store.updateWall(wall.id) { w in
            for c in todo {
                switch mode {
                case .cutOut(let remove): if remove { w.disabled.insert(c) } else { w.disabled.remove(c) }
                case .wire, .erase:
                    guard let kind else { continue }
                    for i in w[kind].runs.indices { w[kind].runs[i].cells.removeAll { $0 == c } }
                    if case .wire = mode, w[kind].runs.indices.contains(run) { w[kind].runs[run].cells.append(c) }
                case .assign, .none: break
                }
            }
        }
    }
}

struct HingePopover: View {
    @EnvironmentObject private var store: ProjectStore
    let wallID: UUID
    let edit: HingeEdit
    @State private var value = 0.0
    @State private var all = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(edit.axis == .column ? "Column hinge \(edit.index + 1) | \(edit.index + 2)" : "Row hinge \(edit.index + 1) / \(edit.index + 2)").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 4), count: 5), spacing: 4) {
                ForEach(anglePresets, id: \.self) { a in
                    Button("\(a > 0 ? "+" : "")\(fmt(a))°") { apply(a) }.controlSize(.small)
                }
            }
            HStack {
                CommitField(label: "Angle", value: $value).frame(width: 70).onSubmit { DispatchQueue.main.async { apply(value) } }
                Text("°")
                Button("Set") { apply(value) }.keyboardShortcut(.defaultAction)
            }
            Toggle("Apply to all \(edit.axis == .column ? "column" : "row") hinges", isOn: $all)
            Text(edit.axis == .column ? "+ concave · − convex · 90 corner" : "+ tilts toward the audience").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .onAppear {
            if let w = store.project.walls.first(where: { $0.id == wallID }) {
                value = (edit.axis == .column ? w.colAngles : w.rowAngles)[safe: edit.index] ?? 0
            }
        }
    }

    private func apply(_ a: Double) {
        store.updateWall(wallID) { w in
            if edit.axis == .column { if all { w.colAngles = w.colAngles.map { _ in a } } else if w.colAngles.indices.contains(edit.index) { w.colAngles[edit.index] = a } }
            else { if all { w.rowAngles = w.rowAngles.map { _ in a } } else if w.rowAngles.indices.contains(edit.index) { w.rowAngles[edit.index] = a } }
        }
        dismiss()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
