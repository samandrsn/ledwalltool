import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WallKit

/// The content comp (e.g. a Resolume composition): lay every wall out at native pixels,
/// then export a mask, a template and the output slice list.
struct CompView: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selection: Selection?
    @State private var snap = true
    @State private var labels = true
    @State private var drag: (id: UUID, dx: CGFloat, dy: CGFloat)?

    private static let presets: [(Int, Int)] = [(1920, 1080), (3840, 2160), (4096, 2160), (5760, 1080), (7680, 1080), (7680, 2160), (7680, 4320), (11520, 2160), (15360, 2160)]

    var body: some View {
        let rects = Comp.rects(store.project, store.report)
        let comp = store.project.comp
        let outside = rects.filter { $0.x < 0 || $0.y < 0 || $0.x + $0.w > comp.width || $0.y + $0.h > comp.height }
        VStack(spacing: 0) {
            ViewBar {
                LabeledContent("Comp") {
                    HStack(spacing: 4) {
                        let step = panelStep
                        CommitField(label: "Width", value: intBinding(\.width), integer: true).frame(width: 56).multilineTextAlignment(.trailing)
                        Stepper("Width", onIncrement: { grow(\.width, step.w) }, onDecrement: { grow(\.width, -step.w) })
                            .labelsHidden().help("Width ± \(step.w) px (one panel)")
                        Text("×").foregroundStyle(.secondary)
                        CommitField(label: "Height", value: intBinding(\.height), integer: true).frame(width: 56).multilineTextAlignment(.trailing)
                        Stepper("Height", onIncrement: { grow(\.height, step.h) }, onDecrement: { grow(\.height, -step.h) })
                            .labelsHidden().help("Height ± \(step.h) px (one panel)")
                    }
                }
                .fixedSize()
                Menu("Size") {
                    Button("Fit to Walls") { let f = Comp.fit(rects); store.project.comp.width = f.0; store.project.comp.height = f.1 }
                    Divider()
                    ForEach(Self.presets.indices, id: \.self) { i in let pr = Self.presets[i]
                        Button { store.project.comp.width = pr.0; store.project.comp.height = pr.1 } label: { Text(verbatim: "\(pr.0) × \(pr.1)") }
                    }
                }
                .fixedSize()
                Menu("Arrange") {
                    Button("Stage Layout (Unrolled)") { arrange { _ in nil } }
                    Button("Match Media Server Outputs") { arrange(matchOutputs) }
                }
                .fixedSize()
                Menu {
                    ForEach(store.project.walls) { w in
                        Toggle(w.name, isOn: Binding(get: { w.comp?.hidden != true }, set: { show in
                            freezeLayout()
                            store.updateWall(w.id) { $0.comp?.hidden = !show }
                        }))
                    }
                } label: { Label("Walls", systemImage: "square.grid.3x3") }
                .fixedSize()
                Toggle("Snap to panels", isOn: $snap).fixedSize()
                Toggle("Labels", isOn: $labels).fixedSize()
                Menu {
                    Button("Mask PNG…") { export(.mask) }
                    Button("Template PNG…") { export(.template) }
                    Divider()
                    Button("Slices CSV…") { exportSlices() }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .fixedSize()
                if !outside.isEmpty {
                    Label("\(outside.count) wall\(outside.count == 1 ? "" : "s") outside the comp", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    canvas(rects, outside: Set(outside.map(\.wallID)), width: geo.size.width - 48, height: geo.size.height - 70)
                        .padding(24)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }
            .background(Color(white: 0.075))
            .frame(minHeight: 200)
            Divider()
            sliceTable
        }
    }

    // MARK: Canvas

    private func canvas(_ rects: [CompRect], outside: Set<UUID>, width: CGFloat, height: CGFloat) -> some View {
        let comp = store.project.comp
        // Show the comp plus anything hanging outside it, so stray walls can be dragged back in.
        let extW = max(comp.width, rects.map { $0.x + $0.w }.max() ?? 0), extH = max(comp.height, rects.map { $0.y + $0.h }.max() ?? 0)
        let scale = min(1, max(0.02, min(width / CGFloat(extW), height / CGFloat(extH))))
        let project = store.project, report = store.report, moving = drag.map { ($0.id, $0.dx, $0.dy) }, showLabels = labels && scale > 0.12
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Comp \(comp.width)×\(comp.height) (blue outline) · drag walls to place their content · mask: walls transparent, unused black\(extW > comp.width || extH > comp.height ? " · grey = outside the comp" : "")")
                .font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.withCGContext { cg in
                        cg.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
                        cg.fill(CGRect(x: 0, y: 0, width: extW, height: extH))
                        CompRenderer.draw(cg, project, report, mode: .template, labels: labels, panelIDs: showLabels, moving: moving, minTitle: 13 / scale)
                        cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
                        cg.setLineWidth(2 / scale)
                        cg.stroke(CGRect(x: 0, y: 0, width: comp.width, height: comp.height))
                    }
                }
                .frame(width: CGFloat(extW) * scale, height: CGFloat(extH) * scale)
                ForEach(rects, id: \.wallID) { r in
                    if let w = store.project.walls.first(where: { $0.id == r.wallID }), let wr = store.report.walls[w.id] {
                        let off = drag?.id == w.id ? CGSize(width: drag!.dx, height: drag!.dy) : .zero
                        Rectangle()
                            .strokeBorder(outside.contains(w.id) ? Color.red : Color(hex: w.colorHex), lineWidth: selection == .wall(w.id) ? 3 : 1.5)
                            .background(Color.white.opacity(0.001))
                            .frame(width: CGFloat(r.w) * scale, height: CGFloat(r.h) * scale)
                            .offset(x: (CGFloat(r.x) + off.width) * scale, y: (CGFloat(r.y) + off.height) * scale)
                            .help(Text(verbatim: "\(w.name) \(r.w)×\(r.h) at \(r.x),\(r.y)"))
                            .gesture(DragGesture()
                                .onChanged { v in
                                    let (nx, ny) = snapped(r, wr, v.translation, scale)
                                    drag = (w.id, CGFloat(nx - r.x), CGFloat(ny - r.y))
                                }
                                .onEnded { v in
                                    let (nx, ny) = snapped(r, wr, v.translation, scale)
                                    drag = nil
                                    selection = .wall(w.id)
                                    freezeLayout()
                                    store.updateWall(w.id) { $0.comp = CompPlacement(x: nx, y: ny) }
                                })
                    }
                }
            }
        }
    }

    private func snapped(_ r: CompRect, _ wr: WallReport, _ t: CGSize, _ scale: CGFloat) -> (Int, Int) {
        let sx = snap ? wr.spec.pxW : 1, sy = snap ? wr.spec.pxH : 1
        let x = Double(r.x) + t.width / scale, y = Double(r.y) + t.height / scale
        return (max(0, Int((x / Double(sx)).rounded()) * sx), max(0, Int((y / Double(sy)).rounded()) * sy))
    }

    // MARK: Slices

    private var sliceTable: some View {
        let slices = Comp.slices(store.project, store.report)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Output Slices").font(.headline).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            Table(slices) {
                TableColumn("Slice") { Text($0.name) }
                TableColumn("Comp X, Y") { s in Text(verbatim: "\(s.compX), \(s.compY)").monospacedDigit() }
                TableColumn("Size") { s in Text(verbatim: "\(s.w)×\(s.h)").monospacedDigit() }
                TableColumn("Processor") { Text($0.processor) }
                TableColumn("Server · Output") { s in Text(s.output.map { "\(s.server) · Out \($0)" } ?? "—") }
                TableColumn("Output X, Y") { s in Text(verbatim: "\(s.outputX), \(s.outputY)").monospacedDigit() }
                TableColumn("Desktop X, Y") { s in Text(verbatim: s.desktopX.map { "\($0), \(s.desktopY!)" } ?? "—").monospacedDigit() }
            }
        }
        .frame(height: 190)
    }

    // MARK: Actions

    private func intBinding(_ kp: WritableKeyPath<CompSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(store.project.comp[keyPath: kp]) }, set: { store.project.comp[keyPath: kp] = max(16, min(32768, Int($0.rounded()))) })
    }

    /// One panel's pixels, from the panel type with the most panels in the comp.
    private var panelStep: (w: Int, h: Int) {
        var counts: [PanelSpec: Int] = [:]
        for r in Comp.rects(store.project, store.report) { if let wr = store.report.walls[r.wallID] { counts[wr.spec, default: 0] += wr.panelCount } }
        guard let spec = counts.max(by: { $0.value < $1.value })?.key else { return (192, 192) }
        return (spec.pxW, spec.pxH)
    }

    private func grow(_ kp: WritableKeyPath<CompSettings, Int>, _ by: Int) {
        store.project.comp[keyPath: kp] = max(16, min(32768, store.project.comp[keyPath: kp] + by))
    }

    /// Pins every auto-placed wall where it is, so moving one wall doesn't shuffle the rest.
    private func freezeLayout() {
        let rects = Comp.rects(store.project, store.report)
        var p = store.project
        for r in rects where !r.placed { if let i = p.wallIndex(r.wallID) { p.walls[i].comp = CompPlacement(x: r.x, y: r.y) } }
        store.project = p
    }

    private func arrange(_ position: (Wall) -> (Int, Int)?) {
        let auto = Comp.stageLayout(store.project, store.report)
        var p = store.project
        for i in p.walls.indices {
            let hidden = p.walls[i].comp?.hidden ?? false
            let xy = position(p.walls[i]) ?? auto[p.walls[i].id] ?? (0, 0)
            p.walls[i].comp = CompPlacement(x: xy.0, y: xy.1, hidden: hidden)
        }
        store.project = p
    }

    /// Comp position = where the wall lands on the media server's mosaic desktop (first section).
    private func matchOutputs(_ w: Wall) -> (Int, Int)? {
        Comp.slices(store.project, store.report).first { $0.wallID == w.id && $0.feed == 0 }.flatMap { s in s.desktopX.map { ($0, s.desktopY!) } }
    }

    private func export(_ mode: CompRenderer.Mode) {
        let p = store.project
        guard let png = CompRenderer.png(p, store.report, mode: mode) else { return }
        Exporters.save(png, name: "\(p.name) — comp \(mode == .mask ? "mask" : "template") \(p.comp.width)x\(p.comp.height).png", type: .png)
    }

    private func exportSlices() {
        let p = store.project
        var rows = [["Slice", "Comp X", "Comp Y", "Width", "Height", "Processor", "Server", "Output", "Output X", "Output Y", "Desktop X", "Desktop Y"]]
        for s in Comp.slices(p, store.report) {
            rows.append([s.name, "\(s.compX)", "\(s.compY)", "\(s.w)", "\(s.h)", s.processor, s.server, s.output.map(String.init) ?? "",
                         "\(s.outputX)", "\(s.outputY)", s.desktopX.map(String.init) ?? "", s.desktopY.map(String.init) ?? ""])
        }
        let csv = rows.map { $0.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") }.joined(separator: "\n")
        Exporters.save(Data(csv.utf8), name: "\(p.name) — comp slices.csv", type: .commaSeparatedText)
    }
}

extension CompSlice: Identifiable {
    public var id: String { "\(wallID)-\(feed)" }
}

enum CompRenderer {
    enum Mode { case mask, template }

    /// Draws the comp at native pixels into a y-down context.
    /// `minTitle` keeps wall names readable when the comp is drawn scaled down.
    static func draw(_ cg: CGContext, _ p: LEDProject, _ rep: Report, mode: Mode, labels: Bool, panelIDs: Bool = true,
                     moving: (UUID, CGFloat, CGFloat)? = nil, minTitle: CGFloat = 14) {
        let comp = p.comp
        cg.setFillColor(mode == .mask ? NSColor.black.cgColor : NSColor(white: 0.06, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: comp.width, height: comp.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        for r in Comp.rects(p, rep) {
            guard let w = p.walls.first(where: { $0.id == r.wallID }), let wr = rep.walls[w.id] else { continue }
            let dx = moving?.0 == w.id ? moving!.1 : 0, dy = moving?.0 == w.id ? moving!.2 : 0
            let ox = CGFloat(r.x) + dx, oy = CGFloat(r.y) + dy
            let pw = CGFloat(wr.spec.pxW), ph = CGFloat(wr.spec.pxH)
            let base = NSColor(hex: w.colorHex)
            let line = max(1, min(pw, ph) / 96)
            for c in 0..<w.cols {
                for row in 0..<w.rows where w.isEnabled(Cell(c, row)) {
                    let rect = CGRect(x: ox + CGFloat(c) * pw, y: oy + CGFloat(w.rows - 1 - row) * ph, width: pw, height: ph)
                    if mode == .mask { cg.clear(rect); continue }   // LED = transparent, unused = black
                    cg.setFillColor(base.withAlphaComponent((c + row) % 2 == 0 ? 0.85 : 0.6).cgColor)
                    cg.fill(rect)
                    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                    cg.setLineWidth(line)
                    cg.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
                    if labels && panelIDs && pw >= 48 {
                        text("\(c + 1).\(row + 1)", at: CGPoint(x: rect.minX + line * 4, y: rect.minY + line * 3), size: max(9, ph / 8))
                    }
                }
            }
            if mode == .template && labels {
                let size = min(max(minTitle, min(96, CGFloat(r.h) / 7)), CGFloat(r.h) / 3)
                text(w.name, at: CGPoint(x: ox + CGFloat(r.w) / 2, y: oy + CGFloat(r.h) / 2 - size * 0.6), size: size, bold: true, centered: true)
                text("\(r.w)×\(r.h) @ \(r.x),\(r.y)", at: CGPoint(x: ox + CGFloat(r.w) / 2, y: oy + CGFloat(r.h) / 2 + size * 0.55), size: size * 0.5, centered: true)
            }
        }
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, bold: Bool = false, centered: Bool = false) {
        let shadow = NSShadow()
        shadow.shadowColor = .black; shadow.shadowBlurRadius = size / 6; shadow.shadowOffset = .zero
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium),
                                                           .foregroundColor: NSColor.white, .shadow: shadow])
        let sz = a.size()
        a.draw(at: CGPoint(x: centered ? p.x - sz.width / 2 : p.x, y: centered ? p.y - sz.height / 2 : p.y))
    }

    /// The comp rendered to a PNG at full resolution.
    static func png(_ p: LEDProject, _ rep: Report, mode: Mode) -> Data? {
        let w = p.comp.width, h = p.comp.height
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: 1, y: -1)
        if mode == .mask { cg.setShouldAntialias(false) }
        draw(cg, p, rep, mode: mode, labels: true)
        guard let img = cg.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}
