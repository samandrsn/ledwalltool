import SwiftUI
import WallKit

struct PixelMapView: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selection: Selection?
    @State private var procID: UUID?
    @State private var snap = true
    /// 1 = fit the whole input canvas in the window.
    @State private var zoom: CGFloat = 1
    @State private var drag: (id: UUID, feed: Int, dx: CGFloat, dy: CGFloat)?

    private var proc: Processor? {
        store.project.processors.first { $0.id == (procID ?? { if case .processor(let id) = selection { return id }; return nil }()) } ?? store.project.processors.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let proc {
                ViewBar {
                    Picker("Processor", selection: Binding(get: { proc.id }, set: { procID = $0 })) {
                        ForEach(store.project.processors) { Text(verbatim: "\($0.name) — \($0.inputW)×\($0.inputH)").tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    ControlGroup {
                        Button { zoom = max(0.25, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                        Button { zoom = 1 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Fit canvas to window")
                        Button { zoom = min(8, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                    }
                    .fixedSize()
                    Toggle("Snap to panel grid", isOn: $snap).fixedSize()
                    Button("Auto-Pack") { store.autoPack(proc.id) }
                    Button { Exporters.exportPixelMap(store, proc.id) } label: { Label("Export PNG…", systemImage: "square.and.arrow.up") }
                    Text("Drag walls (or sections of split walls) to place them on the processor's input canvas.").foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 18) {
                            canvas(proc, width: geo.size.width - 48, height: geo.size.height - 80)
                            if let sid = proc.sourceID, let sr = store.report.servers[sid] { mosaic(sr, width: geo.size.width - 48) }
                        }
                        .padding(24)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                .background(Color(white: 0.075))
                .gesture(MagnifyGesture().onChanged { zoom = min(8, max(0.25, zoom * $0.magnification)) })
            } else {
                ContentUnavailableView("No Processors", systemImage: "cpu", description: Text("Add a processor to map walls onto its input."))
            }
        }
    }

    private func canvas(_ proc: Processor, width: CGFloat, height: CGFloat) -> some View {
        let fit = min(width / CGFloat(proc.inputW), max(120, height) / CGFloat(proc.inputH))
        let scale = max(0.02, fit * zoom)
        let slots = store.report.processors[proc.id]?.slots ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(proc.name) input canvas \(proc.inputW)×\(proc.inputH)").font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    ctx.scaleBy(x: scale, y: scale)
                    PixelMapRenderer.draw(ctx, store.project, store.report, proc, labels: scale > 0.25, moving: drag.map { ($0.id, $0.feed, $0.dx, $0.dy) })
                }
                .frame(width: CGFloat(proc.inputW) * scale, height: CGFloat(proc.inputH) * scale)
                .border(Color.white.opacity(0.3), width: 0.5)
                ForEach(slots, id: \.self) { sl in
                    if let w = store.project.walls.first(where: { $0.id == sl.wallID }), let wr = store.report.walls[w.id] {
                        let off = drag?.id == w.id && drag?.feed == sl.feed ? CGSize(width: drag!.dx, height: drag!.dy) : .zero
                        Rectangle()
                            .strokeBorder(Color(hex: w.colorHex), lineWidth: selection == .wall(w.id) ? 3 : 1.5)
                            .background(Color.white.opacity(0.001))
                            .frame(width: CGFloat(sl.w) * scale, height: CGFloat(sl.h) * scale)
                            .offset(x: CGFloat(sl.x) * scale + off.width * scale, y: CGFloat(sl.y) * scale + off.height * scale)
                            .help("\(sl.name) \(sl.w)×\(sl.h) at \(sl.x),\(sl.y)")
                            .gesture(DragGesture()
                                .onChanged { v in
                                    let (nx, ny) = snapped(sl, wr, v.translation, scale)
                                    drag = (w.id, sl.feed, CGFloat(nx - sl.x), CGFloat(ny - sl.y))
                                }
                                .onEnded { v in
                                    let (nx, ny) = snapped(sl, wr, v.translation, scale)
                                    drag = nil
                                    selection = .wall(w.id)
                                    store.updateWall(w.id) { $0.setCanvas(feed: sl.feed, x: nx, y: ny) }
                                })
                    }
                }
            }
        }
    }

    private func snapped(_ sl: CanvasSlot, _ wr: WallReport, _ t: CGSize, _ scale: CGFloat) -> (Int, Int) {
        let sx = snap ? wr.spec.pxW : 1, sy = snap ? wr.spec.pxH : 1
        let x = Double(sl.x) + t.width / scale, y = Double(sl.y) + t.height / scale
        return (max(0, Int((x / Double(sx)).rounded()) * sx), max(0, Int((y / Double(sy)).rounded()) * sy))
    }

    private func mosaic(_ sr: ServerReport, width: CGFloat) -> some View {
        let s = min(0.08, width / CGFloat(max(1, sr.canvasW)))
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(sr.server.name) mosaic desktop \(sr.canvasW)×\(sr.canvasH) (\(sr.server.mosaicCols)×\(sr.server.mosaicRows))").font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                ForEach(sr.cells, id: \.index) { c in
                    let feeds = (sr.feeds[c.index] ?? []).compactMap { id in store.project.processors.first { $0.id == id }?.name }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Out \(c.index + 1) · \(c.w)×\(c.h)").font(.caption.weight(.semibold))
                        Text(feeds.isEmpty ? "Unused" : feeds.joined(separator: ", ")).font(.caption2)
                    }
                    .padding(6)
                    .frame(width: CGFloat(c.w) * s, height: CGFloat(c.h) * s, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(feeds.isEmpty ? Color.white.opacity(0.04) : Color.accentColor.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(feeds.isEmpty ? Color.white.opacity(0.2) : Color.accentColor))
                    .foregroundStyle(feeds.isEmpty ? .secondary : .primary)
                    .offset(x: CGFloat(c.x) * s, y: CGFloat(c.y) * s)
                }
            }
            .frame(width: CGFloat(sr.canvasW) * s, height: CGFloat(sr.canvasH) * s, alignment: .topLeading)
        }
    }
}

enum PixelMapRenderer {
    /// Draws a processor's input canvas at native pixel scale (caller scales the context).
    static func draw(_ ctx: GraphicsContext, _ p: LEDProject, _ rep: Report, _ proc: Processor, labels: Bool, moving: (UUID, Int, CGFloat, CGFloat)? = nil) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: proc.inputW, height: proc.inputH)), with: .color(.black))
        for sl in rep.processors[proc.id]?.slots ?? [] {
            guard let w = p.walls.first(where: { $0.id == sl.wallID }), let wr = rep.walls[w.id], let f = wr.feeds[safe: sl.feed] else { continue }
            let (pw, ph) = (CGFloat(wr.spec.pxW), CGFloat(wr.spec.pxH))
            let mv = moving.map { $0.0 == w.id && $0.1 == sl.feed } ?? false
            let ox = CGFloat(sl.x) + (mv ? moving!.2 : 0), oy = CGFloat(sl.y) + (mv ? moving!.3 : 0)
            let base = Color(hex: w.colorHex)
            for c in f.cols {
                for r in f.rows where f.contains(Cell(c, r)) && w.isEnabled(Cell(c, r)) {
                    let at = f.canvasCell(Cell(c, r))
                    let rect = CGRect(x: ox + CGFloat(at.x) * pw, y: oy + CGFloat(at.y) * ph, width: pw, height: ph)
                    ctx.fill(Path(rect), with: .color(base.opacity((c + r) % 2 == 0 ? 0.85 : 0.6)))
                    ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.9)), lineWidth: 1)
                    if labels, pw >= 48 {
                        ctx.draw(Text("\(c + 1).\(r + 1)").font(.system(size: max(9, ph / 7))).foregroundColor(.white),
                                 at: CGPoint(x: rect.minX + 4, y: rect.minY + 3), anchor: .topLeading)
                    }
                }
            }
            let title = Text(verbatim: "\(sl.name)  \(sl.w)×\(sl.h)").font(.system(size: max(14, min(64, CGFloat(sl.h) / 8)), weight: .bold)).foregroundColor(.white)
            ctx.draw(title, at: CGPoint(x: ox + CGFloat(sl.w) / 2, y: oy + CGFloat(sl.h) / 2))
        }
    }
}
