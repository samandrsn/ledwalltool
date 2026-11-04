import Foundation

/// Data & power run generation. A run is an ordered chain of panels: one data port or one circuit.
public enum Routing {
    struct Shape { var vertical: Bool; var serpentine: Bool; var evenLines: Bool; var fromCenter: Bool }

    static func shape(_ p: PatternPreset) -> Shape {
        switch p {
        case .recommend, .snakeV: return Shape(vertical: true, serpentine: true, evenLines: false, fromCenter: false)
        case .snakeH: return Shape(vertical: false, serpentine: true, evenLines: false, fromCenter: false)
        case .rasterV: return Shape(vertical: true, serpentine: false, evenLines: false, fromCenter: false)
        case .rasterH: return Shape(vertical: false, serpentine: false, evenLines: false, fromCenter: false)
        case .uV: return Shape(vertical: true, serpentine: true, evenLines: true, fromCenter: false)
        case .cH: return Shape(vertical: false, serpentine: true, evenLines: true, fromCenter: false)
        case .centerV: return Shape(vertical: true, serpentine: true, evenLines: false, fromCenter: true)
        case .centerH: return Shape(vertical: false, serpentine: true, evenLines: false, fromCenter: true)
        }
    }

    public static func resolvedStart(_ wall: Wall, _ s: StartCorner) -> StartCorner {
        s == .auto ? (wall.rigging == .flown ? .topLeft : .bottomLeft) : s
    }

    /// Groups → lines → cells; each line ordered forward from the start edge.
    static func lines(_ wall: Wall, vertical: Bool, start: StartCorner, fromCenter: Bool) -> [[[Cell]]] {
        let left = start == .bottomLeft || start == .topLeft
        let bottom = start == .bottomLeft || start == .bottomRight
        func seq(_ n: Int, _ fwd: Bool) -> [Int] { fwd ? Array(0..<n) : Array((0..<n).reversed()) }
        let mid = (wall.cols + 1) / 2
        var groups: [[[Cell]]] = []
        if vertical {
            let colLine = { (c: Int) in seq(wall.rows, bottom).map { Cell(c, $0) }.filter(wall.isEnabled) }
            if fromCenter && wall.cols > 1 {
                groups = [(0..<mid).reversed().map(colLine), (mid..<wall.cols).map(colLine)]
            } else {
                groups = [seq(wall.cols, left).map(colLine)]
            }
        } else {
            let rowsOrder = seq(wall.rows, bottom)
            if fromCenter && wall.cols > 1 {
                groups = [rowsOrder.map { r in (0..<mid).reversed().map { Cell($0, r) }.filter(wall.isEnabled) },
                          rowsOrder.map { r in (mid..<wall.cols).map { Cell($0, r) }.filter(wall.isEnabled) }]
            } else {
                groups = [rowsOrder.map { r in seq(wall.cols, left).map { Cell($0, r) }.filter(wall.isEnabled) }]
            }
        }
        return groups.map { $0.filter { !$0.isEmpty } }
    }

    static func snake(_ lines: [[Cell]], _ serpentine: Bool) -> [Cell] {
        lines.enumerated().flatMap { i, l in serpentine && i % 2 == 1 ? l.reversed() : l }
    }

    static func chunk(_ lines: [[Cell]], cap: Int, mode: Chunking, serpentine: Bool, even: Bool) -> [[Cell]] {
        let total = lines.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        if mode != .lines {
            let path = snake(lines, serpentine)
            let size = mode == .balanced ? Int((Double(total) / ceil(Double(total) / Double(cap))).rounded(.up)) : cap
            return stride(from: 0, to: path.count, by: size).map { Array(path[$0..<min($0 + size, path.count)]) }
        }
        // Whole lines per run; each run restarts the snake so every port starts at the same edge.
        var runs: [[Cell]] = []
        var cur: [[Cell]] = []
        func count(_ ls: [[Cell]]) -> Int { ls.reduce(0) { $0 + $1.count } }
        func flush() {
            guard !cur.isEmpty else { return }
            var carry: [Cell]? = nil
            if even && cur.count > 1 && cur.count % 2 == 1 { carry = cur.removeLast() }
            runs.append(snake(cur, serpentine))
            cur = carry.map { [$0] } ?? []
        }
        for line in lines {
            if line.count > cap {
                flush(); flush()
                runs += stride(from: 0, to: line.count, by: cap).map { Array(line[$0..<min($0 + cap, line.count)]) }
                continue
            }
            if count(cur) + line.count > cap { flush() }
            if count(cur) + line.count > cap { flush() }
            cur.append(line)
        }
        flush(); flush()
        return runs
    }

    public struct Recommendation: Sendable {
        public var runs: [[Cell]]
        public var vertical: Bool
        public var chunk: Chunking
        public var start: StartCorner
        public var summary: String {
            "\(vertical ? "Vertical (N)" : "Horizontal (S)") snake from \(start.label.lowercased()), \(chunk == .lines ? "whole lines" : "balanced fill") → \(runs.count) runs"
        }
    }

    /// Fewest runs wins; ties prefer whole-line runs, then vertical snakes.
    public static func recommend(_ wall: Wall, cap: Int, pattern: RunPattern) -> Recommendation {
        let start = resolvedStart(wall, pattern.start)
        let eff = pattern.maxPerRun > 0 ? min(cap, pattern.maxPerRun) : cap
        var best: (Int, Recommendation)?
        for vertical in [true, false] {
            for mode in [Chunking.lines, .balanced] {
                let runs = lines(wall, vertical: vertical, start: start, fromCenter: false)
                    .flatMap { chunk($0, cap: max(1, eff), mode: mode, serpentine: true, even: false) }
                let score = runs.count * 100 + (mode == .balanced ? 30 : 0) + (vertical ? 0 : 1)
                if best == nil || score < best!.0 { best = (score, Recommendation(runs: runs, vertical: vertical, chunk: mode, start: start)) }
            }
        }
        return best!.1
    }

    public static func generate(_ wall: Wall, cap: Int, pattern: RunPattern) -> [[Cell]] {
        let cap = max(1, cap)
        if pattern.preset == .recommend { return recommend(wall, cap: cap, pattern: pattern).runs }
        let s = shape(pattern.preset)
        let eff = pattern.maxPerRun > 0 ? min(cap, pattern.maxPerRun) : cap
        return lines(wall, vertical: s.vertical, start: resolvedStart(wall, pattern.start), fromCenter: s.fromCenter)
            .flatMap { chunk($0, cap: eff, mode: pattern.chunk, serpentine: s.serpentine, even: s.evenLines) }
    }

    /// The wall with every panel outside `feed` cut out, so patterns stay inside one processor's section.
    public static func masked(_ wall: Wall, to feed: Feed) -> Wall {
        var w = wall
        for c in 0..<wall.cols { for r in 0..<wall.rows where !feed.contains(Cell(c, r)) { w.disabled.insert(Cell(c, r)) } }
        return w
    }

    /// Data runs for a (possibly split) wall, each tagged with the feed it belongs to.
    /// Generated runs never cross sections; a hand-wired run belongs to the section of its first panel.
    public static func resolveData(_ wall: Wall, caps: [Int]) -> [(run: Run, feed: Int)] {
        if wall.data.custom {
            return resolve(wall, .data, cap: caps.first ?? 1).map { ($0, $0.cells.first.map(wall.feedIndex) ?? 0) }
        }
        let feeds = wall.feeds
        guard feeds.count > 1 else { return resolve(wall, .data, cap: caps.first ?? 1).map { ($0, 0) } }
        return feeds.flatMap { f in
            generate(masked(wall, to: f), cap: caps[safe: f.index] ?? 1, pattern: wall.data.pattern).map { (Run(cells: $0), f.index) }
        }
    }

    /// The runs actually in effect for a wall: hand-wired (custom) or generated.
    public static func resolve(_ wall: Wall, _ kind: WiringKind, cap: Int) -> [Run] {
        let w = wall[kind]
        if w.custom {
            return w.runs.map { Run(cells: $0.cells.filter { $0.c < wall.cols && $0.r < wall.rows && wall.isEnabled($0) }, port: $0.port) }
        }
        return generate(wall, cap: cap, pattern: w.pattern).map { Run(cells: $0) }
    }
}
