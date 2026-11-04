import Foundation

/// The media-server composition (e.g. a Resolume comp) that content is built at.
public struct CompSettings: Codable, Hashable, Sendable {
    public var width = 3840
    public var height = 2160
    public init() {}
}

/// Where a wall's content sits in the comp. Nil on a wall = placed by the stage layout.
public struct CompPlacement: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    /// Leave this wall out of the comp (e.g. fed from another server).
    public var hidden = false
    public init(x: Int, y: Int, hidden: Bool = false) { self.x = x; self.y = y; self.hidden = hidden }
}

/// A wall's rectangle in the comp, in pixels from the top-left.
public struct CompRect: Hashable, Sendable {
    public var wallID: UUID
    public var x: Int, y: Int, w: Int, h: Int
    public var placed: Bool
}

/// One slice for the media server's output mapping: a comp region and where it lands on an output.
public struct CompSlice: Hashable, Sendable {
    public var name: String
    public var wallID: UUID
    public var feed: Int
    public var compX: Int, compY: Int, w: Int, h: Int
    public var processor: String
    public var server: String
    public var output: Int?
    /// Position on the media server's (mosaic) desktop, and on the single output.
    public var desktopX: Int?, desktopY: Int?
    public var outputX: Int, outputY: Int
}

public enum Comp {
    /// Every visible wall's rectangle in the comp.
    public static func rects(_ p: LEDProject, _ rep: Report) -> [CompRect] {
        let auto = stageLayout(p, rep)
        return p.walls.compactMap { w in
            guard let wr = rep.walls[w.id], w.comp?.hidden != true else { return nil }
            let pos = w.comp.map { ($0.x, $0.y) } ?? auto[w.id] ?? (0, 0)
            return CompRect(wallID: w.id, x: pos.0, y: pos.1, w: wr.resW, h: wr.resH, placed: w.comp != nil)
        }
    }

    /// Unrolled stage layout: walls with their headers above and wings beside them,
    /// groups left to right in stage order, bottom-aligned, starting at 0,0.
    public static func stageLayout(_ p: LEDProject, _ rep: Report) -> [UUID: (Int, Int)] {
        var pos: [UUID: (Int, Int)] = [:]
        func size(_ id: UUID) -> (Int, Int) { rep.walls[id].map { ($0.resW, $0.resH) } ?? (0, 0) }
        func place(_ w: Wall, _ x: Int, _ y: Int, _ seen: inout Set<UUID>) {
            guard seen.insert(w.id).inserted, let wr = rep.walls[w.id] else { return }
            pos[w.id] = (x, y)
            for c in p.walls where c.attach?.wallID == w.id {
                let (cw, ch) = size(c.id)
                let a = c.attach!
                switch a.edge {
                case .top: place(c, x + Int(a.offset.rounded()) * wr.spec.pxW, y - ch, &seen)
                case .right, .left:
                    let up = Int((a.offset * 1000 / wr.spec.mmH * Double(wr.spec.pxH)).rounded())
                    place(c, a.edge == .right ? x + wr.resW : x - cw, y + wr.resH - ch - up, &seen)
                }
            }
        }
        let roots = p.walls.filter { w in w.attach.map { a in !p.walls.contains { $0.id == a.wallID } } ?? true }
            .sorted { $0.position.x < $1.position.x }
        var cursor = 0
        var seen = Set<UUID>()
        for root in roots {
            var group: [UUID: (Int, Int)] = [:]
            let before = Set(pos.keys)
            place(root, 0, 0, &seen)
            for (k, v) in pos where !before.contains(k) { group[k] = v }
            guard !group.isEmpty else { continue }
            let minX = group.map { $0.value.0 }.min()!
            let maxX = group.map { $0.value.0 + size($0.key).0 }.max()!
            let maxY = group.map { $0.value.1 + size($0.key).1 }.max()!
            for (k, v) in group { pos[k] = (v.0 - minX + cursor, v.1 - maxY) }
            cursor += maxX - minX
        }
        // Bottom-aligned groups sit on a shared baseline; shift so the tallest touches the top.
        let minY = pos.values.map(\.1).min() ?? 0
        for k in pos.keys { pos[k]!.1 -= minY }
        // Anything left (attachment cycles) goes to the right.
        for w in p.walls where pos[w.id] == nil { pos[w.id] = (cursor, 0); cursor += size(w.id).0 }
        return pos
    }

    /// Smallest comp that holds every wall.
    public static func fit(_ rects: [CompRect]) -> (Int, Int) {
        (max(1, rects.map { $0.x + $0.w }.max() ?? 1), max(1, rects.map { $0.y + $0.h }.max() ?? 1))
    }

    /// Comp → output slices, one per wall section (split walls give one slice per processor).
    public static func slices(_ p: LEDProject, _ rep: Report) -> [CompSlice] {
        var out: [CompSlice] = []
        for r in rects(p, rep) {
            guard let w = p.walls.first(where: { $0.id == r.wallID }), let wr = rep.walls[w.id] else { continue }
            for f in wr.feeds where !f.isEmpty {
                let proc = p.processors.first { $0.id == f.processorID }
                let server = proc.flatMap { pr in p.servers.first { $0.id == pr.sourceID } }
                let cell = server.flatMap { s in rep.servers[s.id]?.cells.first { $0.index == proc!.sourceOutput } }
                let dx = (f.cols.lowerBound) * wr.spec.pxW, dy = (w.rows - f.rows.upperBound) * wr.spec.pxH
                out.append(CompSlice(
                    name: f.tag.isEmpty ? w.name : "\(w.name) \(f.tag)", wallID: w.id, feed: f.index,
                    compX: r.x + dx, compY: r.y + dy, w: f.cols.count * wr.spec.pxW, h: f.rows.count * wr.spec.pxH,
                    processor: proc?.name ?? "—", server: server?.name ?? "—", output: cell.map { $0.index + 1 },
                    desktopX: cell.map { $0.x + f.canvasX }, desktopY: cell.map { $0.y + f.canvasY },
                    outputX: f.canvasX, outputY: f.canvasY))
            }
        }
        return out
    }
}
