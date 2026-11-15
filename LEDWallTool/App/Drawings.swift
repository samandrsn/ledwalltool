import AppKit
import CoreGraphics
import WallKit
import simd

/// As-built style drawing set: bordered sheets with grid zones, a full-height title block with
/// revisions, and LED-xxx sheet numbering. Wall sheets can be drawn from the audience or the rear.
enum Drawings {

    struct Page {
        var number: String
        var title: String
        var view: String
        var notes: String = ""
        var draw: (Sheet, CGRect) -> Void
    }

    // MARK: Entry points

    static func pdf(_ p: LEDProject, _ rep: Report, options: DrawingOptions? = nil) -> Data {
        let o = options ?? p.drawing
        let size = CGSize(width: o.paper.points.w, height: o.paper.points.h)
        let pages = Self.pages(p, rep, o)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: "\(p.name) — LED drawings", kCGPDFContextCreator as String: "LED Wall Tool"] as CFDictionary)
        else { return Data() }
        for (i, page) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)   // y-down like the screen
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let s = Sheet(ctx: ctx, size: size)
            let area = frame(s, p, o, page, index: i + 1, of: pages.count)
            page.draw(s, area)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    static func pages(_ p: LEDProject, _ rep: Report, _ o: DrawingOptions) -> [Page] {
        let walls = p.walls.filter { o.wallIDs.isEmpty || o.wallIDs.contains($0.id) }.map { displayWall(p, $0) }
        let sides: [Bool] = o.side == .both ? [false, true] : [o.side == .rear]
        func viewLabel(_ rear: Bool) -> String { rear ? "REAR (BUILD SIDE)" : "AUDIENCE SIDE" }
        var pages: [Page] = []
        var index: [(String, String, String)] = []   // filled after; cover reads it lazily

        if o.system {
            pages.append(Page(number: "LED-001", title: "System Overview — Signal Flow", view: "SCHEMATIC",
                              notes: "Media server outputs feed processors; processors feed distros and walls. Line weight indicates port count.") { s, a in systemSheet(s, a, p, rep) })
        }
        func series(_ base: Int, _ enabled: Bool, _ kind: String, _ draw: @escaping (Sheet, CGRect, Wall, Bool) -> Void, _ notes: String) {
            guard enabled else { return }
            var n = base
            for w in walls {
                for rear in sides {
                    n += 1
                    pages.append(Page(number: "LED-\(n)", title: "\(w.name) — \(kind)", view: viewLabel(rear), notes: notes) { s, a in draw(s, a, w, rear) })
                }
            }
        }
        series(100, o.data, "Data Map", { s, a, w, rear in wallSheet(s, a, p, rep, o, w, .data, rear) },
               "Numbers show chain order from the port. Run tag marks the first panel (home run). Arrow marks the last panel.")
        series(200, o.power, "Power Map", { s, a, w, rear in wallSheet(s, a, p, rep, o, w, .power, rear) },
               "\(p.settings.voltage.label) circuits, \(Int(p.settings.breakerAmps)) A at \(Int(p.settings.derate * 100))% load. Phase legs shown under each circuit tag.")
        series(300, o.structure, "Structure & Build", { s, a, w, rear in structureSheet(s, a, p, rep, o, w, rear) },
               "Hinge angles: + concave (toward audience), − convex. Column weights include extra hardware per panel.")
        if o.cableSchedule {
            let lines = Schedules.cables(p, rep, walls: walls)
            let perPage = max(10, Int((CGFloat(o.paper.points.h) - 160) / 14))
            let chunks = stride(from: 0, to: max(1, lines.count), by: perPage).map { Array(lines[$0..<min($0 + perPage, lines.count)]) }
            for (i, chunk) in chunks.enumerated() {
                pages.append(Page(number: "LED-\(401 + i)", title: "Cable Schedule\(chunks.count > 1 ? " (\(i + 1) of \(chunks.count))" : "")", view: "SCHEDULE",
                                  notes: "Jumpers = panel-to-panel links in each run. Start/End are column.row as numbered on the maps.") { s, a in cableSheet(s, a, chunk) })
            }
        }
        if o.bom {
            pages.append(Page(number: "LED-501", title: "Bill of Materials", view: "SCHEDULE",
                              notes: "Spares at \(o.sparesPercent)% rounded up. Quantities exclude rigging and cable lengths.") { s, a in bomSheet(s, a, p, rep, walls, o) })
        }
        if o.pixelMaps {
            let procIDs = Set(walls.flatMap(\.processorIDs))
            for (i, proc) in p.processors.enumerated() where procIDs.contains(proc.id) {
                pages.append(Page(number: "LED-\(601 + i)", title: "\(proc.name) — Pixel Map", view: "INPUT CANVAS",
                                  notes: "Wall positions on the processor input canvas, in pixels from the top-left.") { s, a in pixelSheet(s, a, p, rep, proc) })
            }
        }
        if o.cover {
            index = pages.map { ($0.number, $0.title, $0.view) }
            let idx = index
            pages.insert(Page(number: "LED-000", title: "Cover & Sheet Index", view: "GENERAL") { s, a in coverSheet(s, a, p, rep, idx) }, at: 0)
        }
        return pages
    }

    // MARK: Primitives

    struct Sheet {
        let ctx: CGContext
        let size: CGSize
        /// Type scale relative to an 11×17 sheet.
        var k: CGFloat { min(1.6, max(0.75, sqrt(size.width * size.height / (1224 * 792)))) }

        func font(_ s: CGFloat, _ bold: Bool = false, mono: Bool = false) -> NSFont {
            mono ? NSFont.monospacedDigitSystemFont(ofSize: s, weight: bold ? .bold : .regular) : (bold ? .boldSystemFont(ofSize: s) : .systemFont(ofSize: s))
        }
        func attr(_ str: String, _ s: CGFloat, bold: Bool = false, color: NSColor = .black) -> NSAttributedString {
            NSAttributedString(string: str, attributes: [.font: font(s, bold, mono: true), .foregroundColor: color])
        }
        /// y is the baseline-ish top for left/right text; with vcenter, y is the vertical middle.
        func text(_ str: String, _ p: CGPoint, _ s: CGFloat, bold: Bool = false, color: NSColor = .black, align: NSTextAlignment = .left, vcenter: Bool = false) {
            let a = attr(str, s, bold: bold, color: color), sz = a.size()
            var o = p
            if align == .center { o.x -= sz.width / 2 } else if align == .right { o.x -= sz.width }
            o.y -= vcenter ? sz.height / 2 : sz.height * 0.8
            a.draw(at: o)
        }
        /// Wrapped text inside a box; returns the height used.
        @discardableResult
        func textBox(_ str: String, _ r: CGRect, _ s: CGFloat, bold: Bool = false, color: NSColor = .black) -> CGFloat {
            let a = attr(str, s, bold: bold, color: color)
            a.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return a.boundingRect(with: CGSize(width: r.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height
        }
        func measure(_ str: String, _ s: CGFloat, bold: Bool = false) -> CGSize { attr(str, s, bold: bold).size() }
        func rect(_ r: CGRect, fill: NSColor? = nil, stroke: NSColor? = .black, width: CGFloat = 1, dash: [CGFloat] = [], radius: CGFloat = 0) {
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if let fill { ctx.addPath(path); ctx.setFillColor(fill.cgColor); ctx.fillPath() }
            if let stroke { ctx.addPath(path); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(width); ctx.setLineDash(phase: 0, lengths: dash); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: []) }
        }
        func line(_ a: CGPoint, _ b: CGPoint, color: NSColor = .black, width: CGFloat = 0.7, dash: [CGFloat] = []) {
            ctx.move(to: a); ctx.addLine(to: b); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width)
            ctx.setLineDash(phase: 0, lengths: dash); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
        }
        func polyline(_ pts: [CGPoint], color: NSColor, width: CGFloat) {
            guard pts.count > 1 else { return }
            ctx.addLines(between: pts); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width)
            ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
        }
        func arrow(from a: CGPoint, to b: CGPoint, size: CGFloat, color: NSColor = .black) {
            let ang = atan2(b.y - a.y, b.x - a.x)
            ctx.move(to: CGPoint(x: b.x + cos(ang) * size * 0.6, y: b.y + sin(ang) * size * 0.6))
            ctx.addLine(to: CGPoint(x: b.x + cos(ang + 2.6) * size, y: b.y + sin(ang + 2.6) * size))
            ctx.addLine(to: CGPoint(x: b.x + cos(ang - 2.6) * size, y: b.y + sin(ang - 2.6) * size))
            ctx.closePath(); ctx.setFillColor(color.cgColor); ctx.fillPath()
        }
        func curve(from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat) {
            let dx = (b.x - a.x) * 0.5
            ctx.move(to: a); ctx.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.strokePath()
        }
        /// Architectural dimension line with extension lines and arrowheads.
        func dimension(_ a: CGPoint, _ b: CGPoint, offset: CGVector, label: String) {
            let pa = CGPoint(x: a.x + offset.dx, y: a.y + offset.dy), pb = CGPoint(x: b.x + offset.dx, y: b.y + offset.dy)
            let ext = CGVector(dx: offset.dx == 0 ? 0 : (offset.dx > 0 ? 4 : -4) * k, dy: offset.dy == 0 ? 0 : (offset.dy > 0 ? 4 : -4) * k)
            line(a, CGPoint(x: pa.x + ext.dx, y: pa.y + ext.dy), width: 0.4)
            line(b, CGPoint(x: pb.x + ext.dx, y: pb.y + ext.dy), width: 0.4)
            line(pa, pb, width: 0.6)
            arrow(from: pb, to: pa, size: 5 * k); arrow(from: pa, to: pb, size: 5 * k)
            let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            let sz = measure(label, 7.5 * k)
            if abs(pa.x - pb.x) >= abs(pa.y - pb.y) {
                rect(CGRect(x: mid.x - sz.width / 2 - 3, y: mid.y - sz.height / 2, width: sz.width + 6, height: sz.height), fill: .white, stroke: nil)
                text(label, mid, 7.5 * k, align: .center, vcenter: true)
            } else {
                ctx.saveGState(); ctx.translateBy(x: mid.x, y: mid.y); ctx.rotate(by: -.pi / 2)
                rect(CGRect(x: -sz.width / 2 - 3, y: -sz.height / 2, width: sz.width + 6, height: sz.height), fill: .white, stroke: nil)
                text(label, .zero, 7.5 * k, align: .center, vcenter: true)
                ctx.restoreGState()
            }
        }
        /// Simple table. Returns the bottom y.
        @discardableResult
        func table(_ origin: CGPoint, width: CGFloat, columns: [(String, CGFloat, NSTextAlignment)], rows: [[String]], rowHeight: CGFloat, fontSize: CGFloat, shade: ((Int) -> NSColor?)? = nil) -> CGFloat {
            let total = columns.reduce(0) { $0 + $1.1 }
            let widths = columns.map { $0.1 / total * width }
            var y = origin.y
            func row(_ cells: [String], bold: Bool, fill: NSColor?) {
                if let fill { rect(CGRect(x: origin.x, y: y, width: width, height: rowHeight), fill: fill, stroke: nil) }
                var x = origin.x
                for (i, c) in cells.enumerated() {
                    let w = widths[i], al = columns[i].2
                    let px: CGFloat = al == .right ? x + w - 4 : al == .center ? x + w / 2 : x + 4
                    text(c, CGPoint(x: px, y: y + rowHeight / 2), fontSize, bold: bold, align: al, vcenter: true)
                    x += w
                }
                line(CGPoint(x: origin.x, y: y + rowHeight), CGPoint(x: origin.x + width, y: y + rowHeight), width: bold ? 0.8 : 0.3)
                y += rowHeight
            }
            line(CGPoint(x: origin.x, y: y), CGPoint(x: origin.x + width, y: y), width: 0.8)
            row(columns.map { $0.0 }, bold: true, fill: NSColor(white: 0.9, alpha: 1))
            for (i, r) in rows.enumerated() { row(r, bold: false, fill: shade?(i) ?? (i % 2 == 1 ? NSColor(white: 0.97, alpha: 1) : nil)) }
            return y
        }
    }

    // MARK: Sheet frame & title block

    /// Draws border, grid zones and the title block; returns the drawing area.
    static func frame(_ s: Sheet, _ p: LEDProject, _ o: DrawingOptions, _ page: Page, index: Int, of total: Int) -> CGRect {
        let k = s.k, W = s.size.width, H = s.size.height
        s.rect(CGRect(origin: .zero, size: s.size), fill: .white, stroke: nil)
        let outer = CGRect(x: 12 * k, y: 12 * k, width: W - 24 * k, height: H - 24 * k)
        let inner = o.gridZones ? outer.insetBy(dx: 13 * k, dy: 13 * k) : outer
        s.rect(outer, width: 0.8)
        s.rect(inner, width: 1.8)
        if o.gridZones {
            let nc = max(4, Int((W / (150 * k)).rounded())), nr = max(3, Int((H / (150 * k)).rounded()))
            for i in 0...nc {
                let x = inner.minX + inner.width * CGFloat(i) / CGFloat(nc)
                s.line(CGPoint(x: x, y: outer.minY), CGPoint(x: x, y: inner.minY), width: 0.6)
                s.line(CGPoint(x: x, y: inner.maxY), CGPoint(x: x, y: outer.maxY), width: 0.6)
                if i < nc {
                    let cx = x + inner.width / CGFloat(nc) / 2, label = "\(nc - i)"
                    s.text(label, CGPoint(x: cx, y: (outer.minY + inner.minY) / 2), 7.5 * k, align: .center, vcenter: true)
                    s.text(label, CGPoint(x: cx, y: (outer.maxY + inner.maxY) / 2), 7.5 * k, align: .center, vcenter: true)
                }
            }
            for j in 0...nr {
                let y = inner.minY + inner.height * CGFloat(j) / CGFloat(nr)
                s.line(CGPoint(x: outer.minX, y: y), CGPoint(x: inner.minX, y: y), width: 0.6)
                s.line(CGPoint(x: inner.maxX, y: y), CGPoint(x: outer.maxX, y: y), width: 0.6)
                if j < nr {
                    let cy = y + inner.height / CGFloat(nr) / 2, label = String(UnicodeScalar(UInt8(65 + (nr - 1 - j))))
                    s.text(label, CGPoint(x: (outer.minX + inner.minX) / 2, y: cy), 7.5 * k, align: .center, vcenter: true)
                    s.text(label, CGPoint(x: (outer.maxX + inner.maxX) / 2, y: cy), 7.5 * k, align: .center, vcenter: true)
                }
            }
        }

        // Title block: full-height strip on the right.
        let tw = min(W * 0.21, 236 * k)
        let tb = CGRect(x: inner.maxX - tw, y: inner.minY, width: tw, height: inner.height)
        s.line(CGPoint(x: tb.minX, y: tb.minY), CGPoint(x: tb.minX, y: tb.maxY), width: 1.8)
        let pad = 8 * k
        var y = tb.minY
        func rule() { s.line(CGPoint(x: tb.minX, y: y), CGPoint(x: tb.maxX, y: y), width: 0.9) }
        func label(_ t: String, _ yy: CGFloat) { s.text(t, CGPoint(x: tb.minX + pad, y: yy), 6 * k, color: .darkGray) }
        let tB = p.titleBlock

        // Company
        y += pad
        s.text(tB.company.isEmpty ? "LED VIDEO SYSTEMS" : tB.company.uppercased(), CGPoint(x: tb.minX + pad, y: y + 11 * k), 12 * k, bold: true)
        s.text(tB.company.isEmpty ? "Data & power documentation" : "LED video systems", CGPoint(x: tb.minX + pad, y: y + 24 * k), 7.5 * k, color: .darkGray)
        y += 34 * k; rule()

        // Project
        label("PROJECT", y + 10 * k)
        s.textBox(p.name, CGRect(x: tb.minX + pad, y: y + 13 * k, width: tw - pad * 2, height: 30 * k), 11.5 * k, bold: true)
        let projLines = [p.client, p.venue, tB.showDates].filter { !$0.isEmpty }
        for (i, l) in projLines.prefix(3).enumerated() { s.text(l, CGPoint(x: tb.minX + pad, y: y + 46 * k + CGFloat(i) * 11 * k), 8 * k) }
        y += 50 * k + CGFloat(min(3, projLines.count)) * 11 * k; rule()

        // Bottom-up fixed blocks
        var bottom = tb.maxY
        // Sheet number
        let numH = 64 * k
        bottom -= numH
        s.line(CGPoint(x: tb.minX, y: bottom), CGPoint(x: tb.maxX, y: bottom), width: 1.4)
        label("SHEET", bottom + 10 * k)
        s.text(page.number, CGPoint(x: tb.midX, y: bottom + 34 * k), 22 * k, bold: true, align: .center, vcenter: true)
        s.text("SHEET \(index) OF \(total)  ·  REV \(tB.currentRevision)", CGPoint(x: tb.midX, y: bottom + numH - 9 * k), 7 * k, align: .center, vcenter: true)
        // Sheet title
        let titleH = 54 * k
        bottom -= titleH
        s.line(CGPoint(x: tb.minX, y: bottom), CGPoint(x: tb.maxX, y: bottom), width: 0.9)
        label("SHEET TITLE", bottom + 10 * k)
        s.textBox(page.title.uppercased(), CGRect(x: tb.minX + pad, y: bottom + 13 * k, width: tw - pad * 2, height: 28 * k), 10.5 * k, bold: true)
        s.text("VIEW: \(page.view)", CGPoint(x: tb.minX + pad, y: bottom + titleH - 6 * k), 7.5 * k)
        // Fields
        let fields: [(String, String)] = [
            ("DRAWN BY", p.designer.isEmpty ? "—" : p.designer), ("CHECKED BY", tB.checkedBy.isEmpty ? "—" : tB.checkedBy),
            ("APPROVED", tB.approvedBy.isEmpty ? "—" : tB.approvedBy), ("DATE", Date().formatted(date: .abbreviated, time: .omitted)),
            ("SCALE", "NTS"), ("PAPER", o.paper.label),
        ]
        let fh = 12.5 * k
        bottom -= fh * CGFloat(fields.count) + 6 * k
        s.line(CGPoint(x: tb.minX, y: bottom), CGPoint(x: tb.maxX, y: bottom), width: 0.9)
        for (i, f) in fields.enumerated() {
            let fy = bottom + 4 * k + CGFloat(i) * fh + fh / 2
            s.text(f.0, CGPoint(x: tb.minX + pad, y: fy), 6 * k, color: .darkGray, vcenter: true)
            s.text(f.1, CGPoint(x: tb.maxX - pad, y: fy), 7.5 * k, align: .right, vcenter: true)
        }
        // Revisions
        let revs = Array(tB.revisions.suffix(6))
        let rh = 11 * k
        bottom -= rh * CGFloat(revs.count + 1) + 14 * k
        s.line(CGPoint(x: tb.minX, y: bottom), CGPoint(x: tb.maxX, y: bottom), width: 0.9)
        label("REVISIONS", bottom + 10 * k)
        s.table(CGPoint(x: tb.minX + 4 * k, y: bottom + 13 * k), width: tw - 8 * k,
                columns: [("REV", 0.6, .center), ("DATE", 1.4, .left), ("DESCRIPTION", 3, .left), ("BY", 0.7, .center)],
                rows: revs.map { [$0.rev, $0.date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits)), $0.description, $0.by] },
                rowHeight: rh, fontSize: 6.5 * k)
        // AS BUILT stamp sits at the foot of the notes area, clear of the drawing.
        if o.asBuiltStamp, bottom - y > 90 * k {
            stamp(s, CGRect(x: tb.minX + pad, y: bottom - 56 * k, width: tw - pad * 2, height: 46 * k))
            bottom -= 62 * k
        }
        // Notes fill the remaining space
        if bottom - y > 30 * k {
            label("NOTES", y + 10 * k)
            s.textBox(page.notes.isEmpty ? "—" : page.notes, CGRect(x: tb.minX + pad, y: y + 15 * k, width: tw - pad * 2, height: bottom - y - 20 * k), 7.5 * k)
        }

        return CGRect(x: inner.minX + 14 * k, y: inner.minY + 14 * k, width: inner.width - tw - 28 * k, height: inner.height - 28 * k)
    }

    static func stamp(_ s: Sheet, _ r: CGRect) {
        let k = s.k
        let red = NSColor(red: 0.78, green: 0.1, blue: 0.1, alpha: 1)
        s.rect(r, stroke: red, width: 2.2, radius: 4)
        s.rect(r.insetBy(dx: 3 * k, dy: 3 * k), stroke: red, width: 0.8, radius: 3)
        s.text("AS BUILT", CGPoint(x: r.midX, y: r.minY + 17 * k), 16 * k, bold: true, color: red, align: .center, vcenter: true)
        s.text(Date().formatted(date: .abbreviated, time: .omitted).uppercased(), CGPoint(x: r.midX, y: r.maxY - 10 * k), 7.5 * k, color: red, align: .center, vcenter: true)
    }

    /// Boxed, wrapped info lines anchored to a bottom edge; returns the box's top.
    @discardableResult
    static func infoBox(_ s: Sheet, _ lines: [String], x: CGFloat, bottom: CGFloat, width: CGFloat) -> CGFloat {
        let k = s.k, fs = 7 * k, pad = 5 * k, gap = 3 * k
        let heights = lines.map { s.attr($0, fs).boundingRect(with: CGSize(width: width - pad * 2, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height }
        let total = heights.reduce(0, +) + gap * CGFloat(max(0, lines.count - 1)) + pad * 2
        let top = bottom - total
        s.rect(CGRect(x: x, y: top, width: width, height: total), stroke: .black, width: 0.6)
        var y = top + pad
        for (l, h) in zip(lines, heights) { s.textBox(l, CGRect(x: x + pad, y: y, width: width - pad * 2, height: h + 2), fs); y += h + gap }
        return top
    }

    /// A header follows its parent's curve, so its drawings show the parent's hinge angles.
    static func displayWall(_ p: LEDProject, _ w: Wall) -> Wall {
        guard let a = w.attach, a.edge == .top, let parent = p.walls.first(where: { $0.id == a.wallID }) else { return w }
        var d = w
        let off = Int(a.offset.rounded())
        d.colAngles = (0..<max(0, w.cols - 1)).map { i in parent.colAngles[safe: i + off] ?? w.colAngles[safe: i] ?? 0 }
        return d
    }

    static func heading(_ s: Sheet, _ a: CGRect, _ title: String, _ sub: String) {
        s.text(title.uppercased(), CGPoint(x: a.minX, y: a.minY + 14 * s.k), 15 * s.k, bold: true)
        s.text(sub, CGPoint(x: a.minX, y: a.minY + 30 * s.k), 8 * s.k, color: .darkGray)
    }

    // MARK: Wall grid geometry (shared by data, power and structure sheets)

    struct Grid {
        let wall: Wall, rear: Bool
        let ox: CGFloat, oy: CGFloat, cw: CGFloat, ch: CGFloat
        /// Column position on paper: mirrored when drawn from the rear.
        func px(_ c: Int) -> Int { rear ? wall.cols - 1 - c : c }
        func rect(_ c: Cell) -> CGRect { CGRect(x: ox + CGFloat(px(c.c)) * cw, y: oy + CGFloat(wall.rows - 1 - c.r) * ch, width: cw, height: ch) }
        func center(_ c: Cell) -> CGPoint { let r = rect(c); return CGPoint(x: r.midX, y: r.midY) }
        var width: CGFloat { CGFloat(wall.cols) * cw }
        var height: CGFloat { CGFloat(wall.rows) * ch }
        /// x of the hinge between column i and i+1.
        func hingeX(_ i: Int) -> CGFloat { ox + CGFloat(rear ? wall.cols - 1 - i : i + 1) * cw }
    }

    static func grid(_ wall: Wall, _ spec: PanelSpec, in r: CGRect, rear: Bool) -> Grid {
        let sc = min(r.width / (CGFloat(wall.cols) * spec.mmW), r.height / (CGFloat(wall.rows) * spec.mmH))
        let cw = spec.mmW * sc, ch = spec.mmH * sc
        return Grid(wall: wall, rear: rear, ox: r.minX + (r.width - CGFloat(wall.cols) * cw) / 2, oy: r.minY + (r.height - CGFloat(wall.rows) * ch) / 2, cw: cw, ch: ch)
    }

    /// Column numbers, row labels, hinge tags and overall dimensions around a grid.
    static func gridFurniture(_ s: Sheet, _ g: Grid, _ wall: Wall, _ spec: PanelSpec, _ o: DrawingOptions, units: UnitSystem, extraBelow: CGFloat = 0) {
        let k = s.k
        for c in 0..<wall.cols { s.text("C\(c + 1)", CGPoint(x: g.rect(Cell(c, 0)).midX, y: g.oy - 6 * k), 6.5 * k, color: .darkGray, align: .center) }
        for r in 0..<wall.rows { s.text("R\(r + 1)", CGPoint(x: g.ox + g.width + 5 * k, y: g.rect(Cell(0, r)).midY), 6.5 * k, color: .darkGray, vcenter: true) }
        let tagY = g.oy + g.height + 5 * k + extraBelow
        for (i, a) in wall.colAngles.enumerated() where a != 0 { hingeTag(s, CGPoint(x: g.hingeX(i), y: tagY + 6 * k), a) }
        for (i, a) in wall.rowAngles.enumerated() where a != 0 {
            hingeTag(s, CGPoint(x: g.ox + g.width + 34 * k, y: g.oy + CGFloat(wall.rows - 1 - i) * g.ch), a)
        }
        if o.dimensions {
            let w = Double(wall.cols) * spec.mmW / 1000, h = Double(wall.rows) * spec.mmH / 1000
            let curved = wall.colAngles.contains { $0 != 0 }
            var wl = "\(F.length(w, units)) (\(wall.cols) × \(Int(spec.mmW)) mm)\(curved ? " UNROLLED" : "")"
            if curved {
                let pl = Geometry.plan(wall, spec)
                let chord = simd_distance(pl.first!, pl.last!)
                wl += " · CHORD \(F.length(chord, units))"
            }
            let below = tagY + (wall.colAngles.contains { $0 != 0 } ? 18 * k : 4 * k)
            s.dimension(CGPoint(x: g.ox, y: g.oy + g.height), CGPoint(x: g.ox + g.width, y: g.oy + g.height),
                        offset: CGVector(dx: 0, dy: below - (g.oy + g.height) + 10 * k), label: wl)
            s.dimension(CGPoint(x: g.ox, y: g.oy), CGPoint(x: g.ox, y: g.oy + g.height),
                        offset: CGVector(dx: -16 * k, dy: 0), label: "\(F.length(h, units)) (\(wall.rows) × \(Int(spec.mmH)) mm)")
        }
    }

    static func hingeTag(_ s: Sheet, _ c: CGPoint, _ a: Double) {
        let k = s.k
        let r = CGRect(x: c.x - 15 * k, y: c.y - 6 * k, width: 30 * k, height: 12 * k)
        s.rect(r, fill: a > 0 ? NSColor(red: 0.17, green: 0.5, blue: 0.24, alpha: 1) : NSColor(red: 0.76, green: 0.25, blue: 0.05, alpha: 1), stroke: nil, radius: 3)
        s.text("\(a > 0 ? "+" : "")\(fmt(a))°", c, 6.5 * k, bold: true, color: .white, align: .center, vcenter: true)
    }

    static func sideNote(_ wall: Wall, _ rear: Bool) -> String {
        rear ? "VIEWED FROM REAR (BUILD SIDE) — C1 AT RIGHT, MIRRORED FROM AUDIENCE VIEW" : "VIEWED FROM FRONT (AUDIENCE SIDE) — C1 AT LEFT"
    }

    // MARK: Data / power sheets

    static func wallSheet(_ s: Sheet, _ a: CGRect, _ p: LEDProject, _ rep: Report, _ o: DrawingOptions, _ wall: Wall, _ kind: WiringKind, _ rear: Bool) {
        guard let wr = rep.walls[wall.id] else { return }
        let k = s.k, spec = wr.spec, set = p.settings
        let proc = p.processors.first { $0.id == wall.processorID }
        heading(s, a, "\(wall.name) — \(kind == .data ? "Data Map" : "Power Map")", sideNote(wall, rear))

        let legendW = 178 * k
        let curved = wall.colAngles.contains { $0 != 0 } || wall.rowAngles.contains { $0 != 0 }
        let stripH: CGFloat = curved ? 118 * k : 0
        let gridArea = CGRect(x: a.minX + 34 * k, y: a.minY + 54 * k, width: a.width - legendW - 90 * k, height: a.height - 54 * k - stripH - 66 * k)
        let g = grid(wall, spec, in: gridArea, rear: rear)
        let fs = max(4.5, min(g.cw, g.ch) * 0.2)

        let runs: [[Cell]] = kind == .data ? wr.dataRuns.map(\.cells) : wr.powerRuns.map(\.cells)
        let labels: [String] = kind == .data ? wr.dataRuns.map(\.label) : wr.powerRuns.map(\.label)
        var at: [Cell: (Int, Int)] = [:]
        for (ri, run) in runs.enumerated() { for (pi, c) in run.enumerated() { at[c] = (ri, pi) } }
        for c in 0..<wall.cols {
            for r in 0..<wall.rows {
                let cell = Cell(c, r), rr = g.rect(cell)
                if !wall.isEnabled(cell) { s.rect(rr, stroke: .gray, width: 0.5, dash: [3, 3]); continue }
                if let (ri, pi) = at[cell] {
                    s.rect(rr, fill: RunPalette.ns(ri, kind).withAlphaComponent(0.32), stroke: .black, width: 0.5)
                    s.text("\(pi + 1)", CGPoint(x: rr.maxX - fs * 0.3, y: rr.minY + fs * 1.05), fs, color: .darkGray, align: .right)
                } else {
                    s.rect(rr, fill: NSColor(white: 0.9, alpha: 1), stroke: .black, width: 0.5)
                    s.text("!", CGPoint(x: rr.midX, y: rr.midY), fs * 1.4, bold: true, color: .red, align: .center, vcenter: true)
                }
                if o.panelIDs { s.text("\(c + 1).\(r + 1)", CGPoint(x: rr.minX + fs * 0.3, y: rr.maxY - fs * 0.25), fs * 0.75, color: .gray) }
            }
        }
        for (ri, run) in runs.enumerated() where !run.isEmpty {
            let pts = run.map(g.center), col = RunPalette.ns(ri, kind)
            s.polyline(pts, color: .black, width: fs * 0.3)
            s.polyline(pts, color: col, width: fs * 0.16)
            if pts.count > 1 { s.arrow(from: pts[pts.count - 2], to: pts[pts.count - 1], size: fs * 0.8) }
            let label = labels[safe: ri] ?? "\(ri + 1)"
            let sz = s.measure(label, fs, bold: true)
            let box = CGRect(x: pts[0].x - sz.width / 2 - fs * 0.4, y: pts[0].y - sz.height / 2 - 1, width: sz.width + fs * 0.8, height: sz.height + 2)
            s.rect(box, fill: col, stroke: .black, width: 0.6, radius: fs * 0.3)
            s.text(label, pts[0], fs, bold: true, align: .center, vcenter: true)
            if kind == .power, let ph = wr.powerRuns[safe: ri]?.phase { s.text(ph, CGPoint(x: pts[0].x, y: box.maxY + fs * 0.9), fs * 0.8, align: .center) }
        }
        if kind == .data && wr.feeds.count > 1 {
            var feedOf: [Cell: Int] = [:]
            for f in wr.feeds { for c in f.cells { feedOf[c] = f.index } }
            // Heavy dashed line on every boundary between processors (grid.rect handles the rear mirror).
            for c in 0..<wall.cols {
                for r in 0..<wall.rows {
                    let f = feedOf[Cell(c, r)] ?? 0, rr = g.rect(Cell(c, r))
                    if c + 1 < wall.cols, (feedOf[Cell(c + 1, r)] ?? 0) != f {
                        let x = g.rect(Cell(c + 1, r)).midX > rr.midX ? rr.maxX : rr.minX
                        s.line(CGPoint(x: x, y: rr.minY), CGPoint(x: x, y: rr.maxY), width: 2.2, dash: [6, 3])
                    }
                    if r + 1 < wall.rows, (feedOf[Cell(c, r + 1)] ?? 0) != f { s.line(CGPoint(x: rr.minX, y: rr.minY), CGPoint(x: rr.maxX, y: rr.minY), width: 2.2, dash: [6, 3]) }
                }
            }
            for f in wr.feeds where !f.isEmpty {
                let top = f.cells.map(\.r).max()!
                let rects = f.cells.filter { $0.r == top }.map(g.rect)
                let box = rects.min { $0.minX < $1.minX }!
                let name = "\(f.tag) · \(p.processors.first { $0.id == f.processorID }?.name.uppercased() ?? "NO PROCESSOR")"
                let sz = s.measure(name, 7.5 * k, bold: true)
                let pill = CGRect(x: box.minX + 3 * k, y: box.minY + 3 * k, width: sz.width + 10 * k, height: sz.height + 4 * k)
                s.rect(pill, fill: .black, stroke: nil, radius: 3)
                s.text(name, CGPoint(x: pill.midX, y: pill.midY), 7.5 * k, bold: true, color: .white, align: .center, vcenter: true)
            }
        }
        gridFurniture(s, g, wall, spec, o, units: set.units)

        // Legend
        let lx = a.maxX - legendW
        var ly = a.minY + 54 * k
        s.text(kind == .data ? "DATA RUNS" : "POWER CIRCUITS", CGPoint(x: lx, y: ly), 9 * k, bold: true)
        ly += 8 * k
        let rows: [[String]] = kind == .data
            ? wr.dataRuns.map { [$0.label, "\($0.cells.count)", "\(Int($0.loadPercent.rounded()))%"] }
            : wr.powerRuns.map { [$0.label, "\($0.cells.count)", fmt1($0.amps), $0.phase ?? ""] }
        let maxRows = Int((a.maxY - stripH - ly - 140 * k) / (11 * k))
        let shown = Array(rows.prefix(max(0, maxRows)))
        let cols: [(String, CGFloat, NSTextAlignment)] = kind == .data
            ? [("PORT", 1.6, .left), ("PNL", 0.8, .right), ("LOAD", 1, .right)]
            : [("CIRCUIT", 1.8, .left), ("PNL", 0.7, .right), ("AMPS", 0.9, .right), ("LEG", 1, .center)]
        ly = s.table(CGPoint(x: lx, y: ly), width: legendW, columns: cols, rows: shown, rowHeight: 11 * k, fontSize: 7 * k) { i in RunPalette.ns(i, kind).withAlphaComponent(0.25) }
        if rows.count > shown.count { s.text("+\(rows.count - shown.count) more — see cable schedule", CGPoint(x: lx, y: ly + 10 * k), 7 * k) }

        // Summary box
        let info: [String] = [
            "\(spec.mfr) \(spec.name)",
            "\(wall.cols) × \(wall.rows) = \(wr.panelCount) panels · \(wr.resW)×\(wr.resH) px",
            "\(F.length(wr.widthM, set.units)) W × \(F.length(wr.heightM, set.units)) H · \(F.weight(wr.kg))",
            kind == .data ? (wall.isSplit ? "Processors: " + wr.feeds.map { f in "\(f.tag) \(p.processors.first { $0.id == f.processorID }?.name ?? "—")" }.joined(separator: ", ")
                                          : "\(proc?.name ?? "No processor") · \(proc?.spec.name ?? "")") + " · ≤\(wr.dataCap) pnl/port @ \(fmt(set.frameRate)) Hz"
                          : "Max \(F.kw(wr.wMax)) · \(F.amps(wr.wMax / set.voltage.volts)) @ \(Int(set.voltage.volts)) V · ≤\(wr.powerCap) pnl/circuit",
            kind == .data ? (wall.isSplit ? wr.feeds.map { "\($0.tag) @ \($0.canvasX),\($0.canvasY)" }.joined(separator: " · ") : "Canvas \(wall.canvasX), \(wall.canvasY)") + " · \(wr.dataRuns.count) ports" : "\(wr.powerRuns.count) circuits · typical \(F.kw(wr.wAvg))",
        ]
        infoBox(s, info, x: lx, bottom: a.maxY - stripH - 4 * k, width: legendW)

        if curved { strips(s, CGRect(x: a.minX, y: a.maxY - stripH + 14 * k, width: a.width, height: stripH - 30 * k), wall, spec, set.units) }
    }

    static func strips(_ s: Sheet, _ r: CGRect, _ wall: Wall, _ spec: PanelSpec, _ units: UnitSystem) {
        if wall.colAngles.contains(where: { $0 != 0 }) { planStrip(s, wall, spec, CGRect(x: r.minX, y: r.minY, width: r.width * 0.6, height: r.height), units) }
        if wall.rowAngles.contains(where: { $0 != 0 }) { sectionStrip(s, wall, spec, CGRect(x: r.minX + r.width * 0.68, y: r.minY, width: r.width * 0.25, height: r.height)) }
    }

    static func planStrip(_ s: Sheet, _ wall: Wall, _ spec: PanelSpec, _ r: CGRect, _ units: UnitSystem) {
        let k = s.k
        let pl = Geometry.plan(wall, spec)
        let xs = pl.map(\.x), zs = pl.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minZ = zs.min()!, maxZ = zs.max()!
        let sc = min(r.width / max(0.1, maxX - minX), (r.height - 10 * k) / max(0.1, maxZ - minZ), 200)
        let ox = r.minX + (r.width - (maxX - minX) * sc) / 2, oy = r.minY + (r.height - 10 * k) / 2 + (maxZ + minZ) / 2 * sc
        let pts = pl.map { CGPoint(x: ox + ($0.x - minX) * sc, y: oy - $0.y * sc) }
        s.polyline(pts, color: NSColor(hex: wall.colorHex), width: 3.5 * k)
        for pt in pts { s.rect(CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3), fill: .black, stroke: nil, radius: 1.5) }
        let uniform = wall.colAngles.allSatisfy { $0 == wall.colAngles.first }
        if !uniform { for (i, a) in wall.colAngles.enumerated() where a != 0 { s.text("\(a > 0 ? "+" : "")\(fmt(a))°", CGPoint(x: pts[i + 1].x, y: pts[i + 1].y - 6 * k), 6.5 * k, align: .center) } }
        let total = wall.colAngles.reduce(0, +)
        let summary = uniform && !wall.colAngles.isEmpty ? "ALL \(wall.colAngles.count) HINGES \(fmt(wall.colAngles[0]))° · R \(F.length(Geometry.radius(forAngle: wall.colAngles[0], panelWidth: spec.size.w), units)) · " : ""
        s.text("PLAN (AUDIENCE ↓) — \(summary)TOTAL \(fmt(total))°", CGPoint(x: r.minX, y: r.maxY + 4 * k), 7 * k, color: .darkGray)
    }

    static func sectionStrip(_ s: Sheet, _ wall: Wall, _ spec: PanelSpec, _ r: CGRect) {
        let k = s.k
        let pl = Geometry.section(wall, spec)
        let zs = pl.map(\.x), ys = pl.map(\.y)
        let sc = min((r.height - 6 * k) / max(0.1, ys.max()!), r.width / max(0.5, zs.max()! - zs.min()! + 1))
        let mid = (zs.max()! + zs.min()!) / 2
        let pts = pl.map { CGPoint(x: r.midX + ($0.x - mid) * sc, y: r.maxY - 6 * k - $0.y * sc) }
        s.polyline(pts, color: NSColor(hex: wall.colorHex), width: 3.5 * k)
        for (i, a) in wall.rowAngles.enumerated() where a != 0 { s.text("\(a > 0 ? "+" : "")\(fmt(a))°", CGPoint(x: pts[i + 1].x + 6 * k, y: pts[i + 1].y + 3 * k), 6.5 * k) }
        s.text("SECTION (AUDIENCE →)", CGPoint(x: r.minX, y: r.maxY + 4 * k), 7 * k, color: .darkGray)
    }

    // MARK: Structure sheet

    static func structureSheet(_ s: Sheet, _ a: CGRect, _ p: LEDProject, _ rep: Report, _ o: DrawingOptions, _ wall: Wall, _ rear: Bool) {
        guard let wr = rep.walls[wall.id] else { return }
        let k = s.k, spec = wr.spec, units = p.settings.units
        heading(s, a, "\(wall.name) — Structure & Build", sideNote(wall, rear))
        let legendW = 178 * k
        let curved = wall.colAngles.contains { $0 != 0 } || wall.rowAngles.contains { $0 != 0 }
        let stripH: CGFloat = curved ? 118 * k : 0
        let gridArea = CGRect(x: a.minX + 34 * k, y: a.minY + 54 * k, width: a.width - legendW - 90 * k, height: a.height - 54 * k - stripH - 84 * k)
        let g = grid(wall, spec, in: gridArea, rear: rear)
        let fs = max(4.5, min(g.cw, g.ch) * 0.2)
        let base = NSColor(hex: wall.colorHex)
        let kgPer = spec.kg + wall.extraKgPerPanel
        for c in 0..<wall.cols {
            for r in 0..<wall.rows {
                let cell = Cell(c, r), rr = g.rect(cell)
                if !wall.isEnabled(cell) {
                    s.rect(rr, stroke: .gray, width: 0.5, dash: [3, 3])
                    s.line(CGPoint(x: rr.minX + 3, y: rr.minY + 3), CGPoint(x: rr.maxX - 3, y: rr.maxY - 3), color: .gray, width: 0.4)
                    s.line(CGPoint(x: rr.maxX - 3, y: rr.minY + 3), CGPoint(x: rr.minX + 3, y: rr.maxY - 3), color: .gray, width: 0.4)
                    continue
                }
                s.rect(rr, fill: base.withAlphaComponent((c + r) % 2 == 0 ? 0.22 : 0.12), stroke: .black, width: 0.5)
                if o.panelIDs { s.text("C\(c + 1)·R\(r + 1)", CGPoint(x: rr.midX, y: rr.midY), fs * 0.95, align: .center, vcenter: true) }
            }
        }
        // Per-column weight (for rigging / floor loads)
        for c in 0..<wall.cols {
            let n = (0..<wall.rows).filter { wall.isEnabled(Cell(c, $0)) }.count
            let kg = Double(n) * kgPer
            s.text(units == .metric ? "\(Int(kg.rounded())) kg" : "\(Int((kg * 2.20462).rounded())) lb", CGPoint(x: g.rect(Cell(c, 0)).midX, y: g.oy + g.height + 9 * k), 6 * k, color: .darkGray, align: .center)
        }
        let rigY = wall.rigging == .flown ? g.oy - 16 * k : g.oy + g.height + 1 * k
        s.text(wall.rigging == .flown ? "▼ FLOWN — RIGGED FROM TOP ROW" : "▲ GROUND STACKED", CGPoint(x: g.ox, y: rigY), 6.5 * k, bold: true, color: .darkGray)
        gridFurniture(s, g, wall, spec, o, units: units, extraBelow: 12 * k)

        // Hinge / curve-block schedule
        let lx = a.maxX - legendW
        var ly = a.minY + 54 * k
        s.text("CURVE BLOCK SCHEDULE", CGPoint(x: lx, y: ly), 9 * k, bold: true)
        ly += 8 * k
        /// "H1–H5, H8" from [1,2,3,4,5,8].
        func ranges(_ idx: [Int], _ prefix: String) -> String {
            var parts: [String] = [], i = 0
            while i < idx.count {
                var j = i
                while j + 1 < idx.count && idx[j + 1] == idx[j] + 1 { j += 1 }
                parts.append(j > i ? "\(prefix)\(idx[i])–\(prefix)\(idx[j])" : "\(prefix)\(idx[i])")
                i = j + 1
            }
            return parts.joined(separator: ", ")
        }
        // Flat hinges need no block, so only angled ones are scheduled.
        func groups(_ angles: [Double], _ prefix: String) -> [[String]] {
            var by: [Double: [Int]] = [:]
            for (i, a) in angles.enumerated() where a != 0 { by[a, default: []].append(i + 1) }
            return by.sorted { $0.key < $1.key }.map { a, idx in
                ["\(a > 0 ? "+" : "")\(fmt(a))°", "\(idx.count)", ranges(idx, prefix), a > 0 ? "Concave" : "Convex"]
            }
        }
        var rows = groups(wall.colAngles, "H") + groups(wall.rowAngles, "V")
        if let at = wall.attach, at.angle != 0, let parent = p.walls.first(where: { $0.id == at.wallID }) {
            rows.append(["\(at.angle > 0 ? "+" : "")\(fmt(at.angle))°", "1", at.edge == .top ? "Base" : "Edge", at.edge == .top ? "Tilt to \(parent.name)" : "Corner to \(parent.name)"])
        }
        ly = s.table(CGPoint(x: lx, y: ly), width: legendW, columns: [("ANGLE", 0.9, .left), ("QTY", 0.5, .right), ("HINGES", 1.5, .left), ("TYPE", 1.6, .left)],
                     rows: rows.isEmpty ? [["—", "", "None", "Flat wall"]] : rows, rowHeight: 11 * k, fontSize: 7 * k)
        s.text("H = column hinge (H1 between C1 and C2). V = row hinge.", CGPoint(x: lx, y: ly + 10 * k), 6.3 * k, color: .darkGray)

        let info: [String] = [
            "\(spec.mfr) \(spec.name) · \(Int(spec.mmW))×\(Int(spec.mmH))×\(Int(spec.mmD)) mm",
            "\(wr.panelCount) panels\(wall.disabled.isEmpty ? "" : " (\(wall.disabled.count) removed)") · \(wall.rigging.label)",
            "Weight \(F.weight(wr.kg)) (\(fmt(kgPer)) kg per panel incl. hardware)",
            wall.attach.map { a in "Attached to \(p.walls.first { $0.id == a.wallID }?.name ?? "?") \(a.edge.label.lowercased()) at \(fmt(a.angle))°" }
                ?? "Position X \(fmt1(wall.position.x)) m, Z \(fmt1(wall.position.z)) m, yaw \(fmt(wall.yaw))°",
            "Max power \(F.kw(wr.wMax)) · \(wr.powerRuns.count) circuits · \(wr.dataRuns.count) data runs",
        ]
        infoBox(s, info, x: lx, bottom: a.maxY - stripH - 4 * k, width: legendW)
        if curved { strips(s, CGRect(x: a.minX, y: a.maxY - stripH + 14 * k, width: a.width, height: stripH - 30 * k), wall, spec, units) }
    }

    // MARK: Schedules

    static func cableSheet(_ s: Sheet, _ a: CGRect, _ lines: [CableLine]) {
        heading(s, a, "Cable Schedule", "Data and power runs, chain order as shown on the data and power maps")
        func cell(_ c: Cell?) -> String { c.map { "\($0.c + 1).\($0.r + 1)" } ?? "—" }
        s.table(CGPoint(x: a.minX, y: a.minY + 44 * s.k), width: a.width,
                columns: [("WALL", 2, .left), ("RUN", 1.4, .left), ("TYPE", 0.9, .left), ("PANELS", 0.8, .right), ("START", 0.8, .center),
                          ("END", 0.8, .center), ("JUMPERS", 0.9, .right), ("LOAD", 0.9, .right), ("LEG", 0.8, .center)],
                rows: lines.map { [$0.wall, $0.run, $0.kind == .data ? "Data" : "Power", "\($0.panels)", cell($0.start), cell($0.end), "\($0.jumpers)", $0.load, $0.phase] },
                rowHeight: 13 * s.k, fontSize: 8 * s.k)
    }

    static func bomSheet(_ s: Sheet, _ a: CGRect, _ p: LEDProject, _ rep: Report, _ walls: [Wall], _ o: DrawingOptions) {
        let k = s.k
        heading(s, a, "Bill of Materials", "\(walls.count) wall\(walls.count == 1 ? "" : "s") · spares at \(o.sparesPercent)%")
        let lines = Schedules.bom(p, rep, walls: walls, sparesPercent: o.sparesPercent)
        let tableW = a.width * 0.66
        s.table(CGPoint(x: a.minX, y: a.minY + 44 * k), width: tableW,
                columns: [("CATEGORY", 1, .left), ("ITEM", 3.2, .left), ("QTY", 0.7, .right), ("SPARES", 0.8, .right), ("TOTAL", 0.8, .right), ("NOTE", 1.8, .left)],
                rows: lines.map { [$0.category, $0.item, "\($0.qty)", "\($0.spares)", "\($0.total)", $0.note] }, rowHeight: 14 * k, fontSize: 8 * k)
        let wr = walls.compactMap { rep.walls[$0.id] }
        let kg = wr.reduce(0) { $0 + $1.kg }, wMax = wr.reduce(0) { $0 + $1.wMax }, wAvg = wr.reduce(0) { $0 + $1.wAvg }
        let px = wr.reduce(0) { $0 + $1.pixels }, panels = wr.reduce(0) { $0 + $1.panelCount }
        let sx = a.minX + tableW + 20 * k, sw = a.width - tableW - 20 * k
        s.text("TOTALS", CGPoint(x: sx, y: a.minY + 44 * k), 9 * k, bold: true)
        s.table(CGPoint(x: sx, y: a.minY + 52 * k), width: sw, columns: [("ITEM", 1.4, .left), ("VALUE", 1.6, .right)], rows: [
            ["Panels", "\(panels)"], ["Pixels", F.mp(px)], ["Weight", F.weight(kg)],
            ["Power max", F.kw(wMax)], ["Power typical", F.kw(wAvg)], ["Heat (typ.)", "\(Int(wAvg * 3.412).formatted()) BTU/h"],
            ["120 V 1Φ", F.amps(Analysis.amps(wMax, .single120))], ["208 V 1Φ", F.amps(Analysis.amps(wMax, .single208))],
            ["208 V 3Φ /leg", F.amps(Analysis.amps(wMax, .threePhase208))], ["400 V 3Φ /leg", F.amps(Analysis.amps(wMax, .threePhase400))],
        ], rowHeight: 14 * k, fontSize: 8 * k)
    }

    // MARK: Pixel map sheet

    static func pixelSheet(_ s: Sheet, _ a: CGRect, _ p: LEDProject, _ rep: Report, _ proc: Processor) {
        let k = s.k
        heading(s, a, "\(proc.name) — Pixel Map", "\(proc.spec.vendor) \(proc.spec.name) · input \(proc.inputW)×\(proc.inputH)")
        let slots = rep.processors[proc.id]?.slots ?? []
        let tableH = CGFloat(slots.count + 1) * 13 * k + 20 * k
        let area = CGRect(x: a.minX, y: a.minY + 44 * k, width: a.width, height: a.height - 44 * k - tableH - 10 * k)
        let sc = min(area.width / CGFloat(proc.inputW), area.height / CGFloat(proc.inputH))
        let canvas = CGRect(x: area.minX, y: area.minY, width: CGFloat(proc.inputW) * sc, height: CGFloat(proc.inputH) * sc)
        s.rect(canvas, fill: NSColor(white: 0.12, alpha: 1), stroke: .black, width: 1)
        for sl in slots {
            guard let w = p.walls.first(where: { $0.id == sl.wallID }), let wr = rep.walls[w.id], let f = wr.feeds[safe: sl.feed] else { continue }
            let col = NSColor(hex: w.colorHex)
            for c in f.cols {
                for r in f.rows where f.contains(Cell(c, r)) && w.isEnabled(Cell(c, r)) {
                    let at = f.canvasCell(Cell(c, r))
                    let rr = CGRect(x: canvas.minX + CGFloat(sl.x + at.x * wr.spec.pxW) * sc, y: canvas.minY + CGFloat(sl.y + at.y * wr.spec.pxH) * sc,
                                    width: CGFloat(wr.spec.pxW) * sc, height: CGFloat(wr.spec.pxH) * sc)
                    s.rect(rr, fill: col.withAlphaComponent((c + r) % 2 == 0 ? 0.85 : 0.6), stroke: .white, width: 0.3)
                }
            }
            let wrect = CGRect(x: canvas.minX + CGFloat(sl.x) * sc, y: canvas.minY + CGFloat(sl.y) * sc, width: CGFloat(sl.w) * sc, height: CGFloat(sl.h) * sc)
            s.rect(wrect, stroke: .white, width: 1.5)
            s.text(sl.name.uppercased(), CGPoint(x: wrect.midX, y: wrect.midY - 6 * k), 9 * k, bold: true, color: .white, align: .center, vcenter: true)
            s.text("\(sl.x), \(sl.y) · \(sl.w)×\(sl.h)", CGPoint(x: wrect.midX, y: wrect.midY + 7 * k), 7 * k, color: .white, align: .center, vcenter: true)
        }
        s.text("0,0", CGPoint(x: canvas.minX + 3, y: canvas.minY + 9 * k), 6.5 * k, color: .lightGray)
        s.text("\(proc.inputW),\(proc.inputH)", CGPoint(x: canvas.maxX - 3, y: canvas.maxY - 4 * k), 6.5 * k, color: .lightGray, align: .right)
        s.table(CGPoint(x: a.minX, y: a.maxY - tableH + 10 * k), width: a.width,
                columns: [("WALL", 2, .left), ("PANELS", 1.2, .left), ("X", 0.8, .right), ("Y", 0.8, .right), ("WIDTH", 0.9, .right), ("HEIGHT", 0.9, .right), ("PANEL PX", 1.1, .right), ("PORTS", 1.8, .left)],
                rows: slots.compactMap { sl in
                    guard let wr = rep.walls[sl.wallID] else { return nil }
                    let ports = wr.dataRuns.filter { $0.feed == sl.feed && $0.processorID == proc.id }.map(\.label)
                    return [sl.name, "\((wr.feeds[safe: sl.feed]?.cells.filter { wr.wall.isEnabled($0) }.count ?? 0)) in C\(sl.cols.lowerBound + 1)–\(sl.cols.upperBound) R\(sl.rows.lowerBound + 1)–\(sl.rows.upperBound)", "\(sl.x)", "\(sl.y)", "\(sl.w)", "\(sl.h)",
                            "\(wr.spec.pxW)×\(wr.spec.pxH)", ports.isEmpty ? "—" : ports.count == 1 ? ports[0] : "\(ports.first!) … \(ports.last!)"]
                }, rowHeight: 13 * k, fontSize: 8 * k)
    }

    // MARK: Cover sheet

    static func coverSheet(_ s: Sheet, _ a: CGRect, _ p: LEDProject, _ rep: Report, _ index: [(String, String, String)]) {
        let k = s.k
        s.text(p.name.uppercased(), CGPoint(x: a.minX, y: a.minY + 34 * k), 30 * k, bold: true)
        let sub = [p.client, p.venue, p.titleBlock.showDates].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        s.text(sub.isEmpty ? "LED VIDEO SYSTEM — DATA & POWER DRAWINGS" : sub, CGPoint(x: a.minX, y: a.minY + 58 * k), 11 * k, color: .darkGray)
        s.line(CGPoint(x: a.minX, y: a.minY + 70 * k), CGPoint(x: a.maxX, y: a.minY + 70 * k), width: 1.2)

        let colW = a.width * 0.48
        s.text("SHEET INDEX", CGPoint(x: a.minX, y: a.minY + 92 * k), 10 * k, bold: true)
        let rows = [["LED-000", "Cover & Sheet Index", "GENERAL"]] + index.map { [$0.0, $0.1, $0.2] }
        s.table(CGPoint(x: a.minX, y: a.minY + 100 * k), width: colW, columns: [("SHEET", 0.9, .left), ("TITLE", 2.6, .left), ("VIEW", 1.4, .left)],
                rows: Array(rows.prefix(Int((a.height - 110 * k) / (12 * k)) - 1)), rowHeight: 12 * k, fontSize: 7.5 * k)

        let rx = a.minX + colW + 24 * k, rw = a.width - colW - 24 * k
        let t = rep.totals
        s.text("SYSTEM SUMMARY", CGPoint(x: rx, y: a.minY + 92 * k), 10 * k, bold: true)
        let y2 = s.table(CGPoint(x: rx, y: a.minY + 100 * k), width: rw, columns: [("ITEM", 1.3, .left), ("VALUE", 2, .left)], rows: [
            ["Walls", "\(p.walls.count)"], ["Panels", "\(t.panels)"], ["Pixels", F.mp(t.pixels)],
            ["Processors", Dictionary(grouping: p.processors, by: \.spec.name).sorted { $0.key < $1.key }
                .map { "\($0.value.count) × \($0.key)" }.joined(separator: ", ").ifEmpty("—")],
            ["Data runs", "\(t.dataRuns)"], ["Circuits", "\(t.circuits) × \(Int(p.settings.breakerAmps)) A \(p.settings.voltage.label)"],
            ["Weight", F.weight(t.kg)], ["Power", "max \(F.kw(t.wMax)) · typical \(F.kw(t.wAvg))"],
            ["Signal", "\(fmt(p.settings.frameRate)) Hz · \(p.settings.bitDepth)-bit"],
        ], rowHeight: 13 * k, fontSize: 8 * k)
        s.text("GENERAL NOTES", CGPoint(x: rx, y: y2 + 24 * k), 10 * k, bold: true)
        s.textBox(p.titleBlock.generalNotes, CGRect(x: rx, y: y2 + 32 * k, width: rw, height: a.maxY - y2 - 40 * k), 8 * k)
    }

    // MARK: System overview

    static func systemSheet(_ s: Sheet, _ a: CGRect, _ p: LEDProject, _ rep: Report) {
        let k = s.k
        heading(s, a, "System Overview — Signal Flow", "Media servers → processors & distros → walls")
        let colW = (a.width - 80 * k) / 3
        let colX = [a.minX, a.minX + colW + 40 * k, a.minX + 2 * (colW + 40 * k)]
        var anchors: [String: CGPoint] = [:]
        func box(_ r: CGRect, _ title: String, _ lines: [String], _ color: NSColor) {
            s.rect(r, fill: .white, stroke: color, width: 1.6, radius: 5)
            s.text(title, CGPoint(x: r.minX + 8 * k, y: r.minY + 15 * k), 10 * k, bold: true)
            for (i, l) in lines.enumerated() { s.text(l, CGPoint(x: r.minX + 8 * k, y: r.minY + 29 * k + CGFloat(i) * 11 * k), 7.5 * k) }
        }
        var y = a.minY + 50 * k
        for srv in p.servers {
            let h = 46 * k + CGFloat(srv.outputs.count) * 14 * k
            box(CGRect(x: colX[0], y: y, width: colW, height: h), srv.name, [srv.gpu], .black)
            for (kk, o) in srv.outputs.enumerated() {
                let oy = y + 42 * k + CGFloat(kk) * 14 * k
                s.text("OUT \(kk + 1): \(o.w)×\(o.h) @ \(fmt(o.hz))", CGPoint(x: colX[0] + 14 * k, y: oy + 3 * k), 7.5 * k)
                anchors["\(srv.id):\(kk)"] = CGPoint(x: colX[0] + colW, y: oy)
            }
            y += h + 14 * k
        }
        y = a.minY + 50 * k
        let blue = NSColor(red: 0.11, green: 0.39, blue: 0.95, alpha: 1)
        for proc in p.processors {
            guard let r = rep.processors[proc.id] else { continue }
            let spec = proc.spec
            let distros = spec.usesDistros ? " · distros " + (0..<r.distrosUsed).map(proc.distroName).joined(separator: ", ").ifEmpty("none") : ""
            box(CGRect(x: colX[1], y: y, width: colW, height: 74 * k), proc.name,
                ["\(spec.vendor) \(spec.name)", "Input \(proc.inputW)×\(proc.inputH)", "Ports \(r.portsNeeded)/\(r.portsAvailable)\(distros)", "Load \(F.mp(r.pixelsUsed)) of \(F.mp(spec.maxPixels))"], blue)
            if let sid = proc.sourceID, let an = anchors["\(sid):\(proc.sourceOutput)"] { s.curve(from: an, to: CGPoint(x: colX[1], y: y + 22 * k), color: blue, width: 1.5) }
            anchors[proc.id.uuidString] = CGPoint(x: colX[1] + colW, y: y + 37 * k)
            y += 88 * k
        }
        y = a.minY + 50 * k
        for wall in p.walls {
            guard let wr = rep.walls[wall.id] else { continue }
            let ports = wr.dataRuns.map(\.label)
            let range = ports.isEmpty ? "—" : ports.count == 1 ? ports[0] : "\(ports.first!) … \(ports.last!)"
            let col = NSColor(hex: wall.colorHex)
            let where_ = wall.isSplit ? "split \(wr.feeds.map(\.tag).joined(separator: "/"))" : "at \(wall.canvasX),\(wall.canvasY)"
            box(CGRect(x: colX[2], y: y, width: colW, height: 58 * k), wall.name,
                ["\(wall.cols)×\(wall.rows) \(wr.spec.name)", "\(wr.resW)×\(wr.resH) \(where_) · \(wr.dataRuns.count) ports (\(range))", "\(wr.powerRuns.count) circuits · \(F.weight(wr.kg))"], col)
            for pid in wall.processorIDs {
                let n = wr.dataRuns.filter { $0.processorID == pid }.count
                if let an = anchors[pid.uuidString] { s.curve(from: an, to: CGPoint(x: colX[2], y: y + 29 * k), color: col, width: 1 + min(5, CGFloat(n) / 4)) }
            }
            y += 68 * k
            if y > a.maxY - 60 * k { break }
        }
    }
}

