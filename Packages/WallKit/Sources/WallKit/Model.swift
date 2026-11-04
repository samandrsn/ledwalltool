import Foundation

/// A panel position in a wall: c = column (0 = left), r = row (0 = bottom).
public struct Cell: Codable, Hashable, Sendable {
    public var c: Int
    public var r: Int
    public init(_ c: Int, _ r: Int) { self.c = c; self.r = r }
}

public struct PanelType: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var spec: PanelSpec
    public init(_ spec: PanelSpec) { self.spec = spec }
    public var title: String { "\(spec.mfr) \(spec.name)" }
}

// MARK: - Wiring

public enum PatternPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case recommend, snakeV, snakeH, rasterV, rasterH, uV, cH, centerV, centerH
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .recommend: return "Auto-recommend"
        case .snakeV: return "N — Vertical Snake"
        case .snakeH: return "S — Horizontal Snake (Zig-Zag)"
        case .rasterV: return "Straight Vertical (Up/Down)"
        case .rasterH: return "Z — Straight Horizontal"
        case .uV: return "U — Vertical, Returns to Start Edge"
        case .cH: return "C — Horizontal, Returns to Start Side"
        case .centerV: return "Center-Out Vertical Snake"
        case .centerH: return "Center-Out Horizontal Snake"
        }
    }
}

public enum StartCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, bottomLeft, bottomRight, topLeft, topRight
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: return "From Rigging"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        }
    }
}

public enum Chunking: String, Codable, CaseIterable, Identifiable, Sendable {
    case lines, fill, balanced
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .lines: return "Whole Lines per Run"
        case .fill: return "Fill Each Run to Max"
        case .balanced: return "Balanced (Equal Runs)"
        }
    }
}

public struct RunPattern: Codable, Hashable, Sendable {
    public var preset: PatternPreset = .recommend
    public var start: StartCorner = .auto
    public var chunk: Chunking = .lines
    public var maxPerRun: Int = 0
    public init() {}
}

/// One data port or power circuit: an ordered chain of panels.
public struct Run: Codable, Hashable, Sendable {
    public var cells: [Cell]
    /// Explicit port index on the processor; nil = assigned automatically.
    public var port: Int?
    public init(cells: [Cell] = [], port: Int? = nil) { self.cells = cells; self.port = port }
}

public struct Wiring: Codable, Hashable, Sendable {
    public var custom = false
    public var pattern = RunPattern()
    public var runs: [Run] = []
    public init() {}
}

public enum WiringKind: String, CaseIterable, Identifiable, Sendable {
    case data, power
    public var id: String { rawValue }
}

// MARK: - Wall

public enum AttachEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case right, left, top
    public var id: String { rawValue }
    public var label: String {
        switch self { case .right: return "Right Edge"; case .left: return "Left Edge"; case .top: return "Top (Header)" }
    }
}

public struct Attachment: Codable, Hashable, Sendable {
    public var wallID: UUID
    public var edge: AttachEdge
    /// Corner angle (left/right; + concave) or header tilt (top; + toward audience).
    public var angle: Double
    /// Meters up the parent's edge (left/right) or column offset (top).
    public var offset: Double
    public init(wallID: UUID, edge: AttachEdge, angle: Double, offset: Double = 0) {
        self.wallID = wallID; self.edge = edge; self.angle = angle; self.offset = offset
    }
}

public enum Rigging: String, Codable, CaseIterable, Identifiable, Sendable {
    case ground, flown
    public var id: String { rawValue }
    public var label: String { self == .ground ? "Ground Stacked" : "Flown" }
}

public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
}

public enum SplitAxis: String, Codable, CaseIterable, Identifiable, Sendable {
    case columns, rows
    public var id: String { rawValue }
    public var label: String { self == .columns ? "Left / Right (by column)" : "Top / Bottom (by row)" }
}

/// Older split format (left/right or top/bottom ranges). Read for compatibility and converted to zones on edit.
public struct WallSection: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Int
    public var processorID: UUID?
    public var canvasX = 0
    public var canvasY = 0
    public init(start: Int, processorID: UUID?) { self.start = start; self.processorID = processorID }
}

public struct WallSplit: Codable, Hashable, Sendable {
    public var axis = SplitAxis.columns
    public var sections: [WallSection] = []
    public init(axis: SplitAxis = .columns, sections: [WallSection] = []) { self.axis = axis; self.sections = sections }
}

/// Panels of a wall driven by another processor (any shape: half the wall, the bottom rows, a few columns).
public struct WallZone: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var processorID: UUID?
    public var canvasX = 0
    public var canvasY = 0
    public var cells: Set<Cell> = []
    public init(processorID: UUID?, cells: Set<Cell> = []) { self.processorID = processorID; self.cells = cells }
}

/// A resolved region of a wall and the processor that drives it. Feed 0 is the wall's own processor.
public struct Feed: Hashable, Sendable {
    public var index: Int
    /// The zone behind this feed; nil for feed 0.
    public var zoneID: UUID?
    public var processorID: UUID?
    public var canvasX: Int
    public var canvasY: Int
    /// Every panel position in this feed (cut-outs included).
    public var cells: Set<Cell>
    /// Bounding box of `cells`; the feed's footprint on its processor's canvas.
    public var cols: Range<Int>
    public var rows: Range<Int>
    /// "S1", "S2"… when the wall has more than one feed, empty otherwise.
    public var tag: String
    public var isEmpty: Bool { cells.isEmpty }
    public func contains(_ c: Cell) -> Bool { cells.contains(c) }
    /// Position of a panel on the processor's input canvas, in panel units from the feed's top-left.
    public func canvasCell(_ c: Cell) -> (x: Int, y: Int) { (c.c - cols.lowerBound, rows.upperBound - 1 - c.r) }
}

public struct Wall: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// Short code for circuit labels; empty = derived from the name.
    public var code = ""
    public var colorHex: String
    public var panelTypeID: UUID?
    public var cols: Int { didSet { fitAngles() } }
    public var rows: Int { didSet { fitAngles() } }
    public var position = Vec3(0, 0, 0)
    /// Degrees.
    public var yaw = 0.0, pitch = 0.0, roll = 0.0
    /// Hinge angles between adjacent columns (cols-1). + concave, − convex.
    public var colAngles: [Double]
    /// Hinge angles between adjacent rows (rows-1). + tilts upper rows toward the audience.
    public var rowAngles: [Double]
    public var attach: Attachment?
    /// Removed panels (cut-outs, irregular shapes).
    public var disabled: Set<Cell> = []
    public var rigging: Rigging = .ground
    /// Frames, bumpers, curve blocks.
    public var extraKgPerPanel = 0.0
    public var processorID: UUID?
    public var canvasX = 0
    public var canvasY = 0
    /// Older range-based split; superseded by `zones`.
    public var split: WallSplit?
    /// Panels driven by other processors; everything else is on `processorID`.
    public var zones: [WallZone]?
    /// Position in the content comp; nil = follow the stage layout.
    public var comp: CompPlacement?
    public var data = Wiring()
    public var power = Wiring()

    public init(name: String, colorHex: String, panelTypeID: UUID?, cols: Int, rows: Int) {
        self.name = name; self.colorHex = colorHex; self.panelTypeID = panelTypeID
        self.cols = cols; self.rows = rows
        colAngles = Array(repeating: 0, count: max(0, cols - 1))
        rowAngles = Array(repeating: 0, count: max(0, rows - 1))
    }

    public mutating func fitAngles() {
        func fit(_ a: [Double], _ n: Int) -> [Double] { Array((a + Array(repeating: 0, count: max(0, n))).prefix(max(0, n))) }
        colAngles = fit(colAngles, cols - 1)
        rowAngles = fit(rowAngles, rows - 1)
        disabled = disabled.filter { $0.c < cols && $0.r < rows }
    }

    public subscript(kind: WiringKind) -> Wiring {
        get { kind == .data ? data : power }
        set { if kind == .data { data = newValue } else { power = newValue } }
    }

    /// Zones in effect: the older split format converted, then painted zones (later ones win).
    public var zoneList: [WallZone] {
        var out: [WallZone] = []
        if let split {
            let n = split.axis == .columns ? cols : rows
            let secs = split.sections.sorted { $0.start < $1.start }.filter { $0.start > 0 && $0.start < n }
            for (i, sec) in secs.enumerated() {
                let range = sec.start..<(i + 1 < secs.count ? secs[i + 1].start : n)
                var z = WallZone(processorID: sec.processorID)
                z.id = sec.id; z.canvasX = sec.canvasX; z.canvasY = sec.canvasY
                for a in range { for b in 0..<(split.axis == .columns ? rows : cols) { z.cells.insert(split.axis == .columns ? Cell(a, b) : Cell(b, a)) } }
                out.append(z)
            }
        }
        return out + (zones ?? [])
    }

    /// Converts the older split format into zones so it can be edited like any other.
    public mutating func migrateSplit() {
        guard split != nil else { return }
        let z = zoneList
        split = nil
        zones = z
    }

    /// Which zone (1-based; 0 = the wall's own processor) owns each panel position.
    public func feedOwner() -> [Cell: Int] {
        var owner: [Cell: Int] = [:]
        for (i, z) in zoneList.enumerated() { for c in z.cells where c.c < cols && c.r < rows { owner[c] = i + 1 } }
        return owner
    }

    /// The regions of this wall and the processor driving each. Feed 0 is the wall's own processor;
    /// empty zones are dropped.
    public var feeds: [Feed] {
        let zs = zoneList
        let owner = feedOwner()
        var buckets = Array(repeating: Set<Cell>(), count: zs.count + 1)
        for c in 0..<cols { for r in 0..<rows { buckets[owner[Cell(c, r)] ?? 0].insert(Cell(c, r)) } }
        func box(_ s: Set<Cell>) -> (Range<Int>, Range<Int>) {
            guard !s.isEmpty else { return (0..<0, 0..<0) }
            return (s.map(\.c).min()!..<(s.map(\.c).max()! + 1), s.map(\.r).min()!..<(s.map(\.r).max()! + 1))
        }
        let b0 = box(buckets[0])
        var out = [Feed(index: 0, zoneID: nil, processorID: processorID, canvasX: canvasX, canvasY: canvasY, cells: buckets[0], cols: b0.0, rows: b0.1, tag: "")]
        for (i, z) in zs.enumerated() where !buckets[i + 1].isEmpty {
            let b = box(buckets[i + 1])
            out.append(Feed(index: out.count, zoneID: z.id, processorID: z.processorID, canvasX: z.canvasX, canvasY: z.canvasY,
                            cells: buckets[i + 1], cols: b.0, rows: b.1, tag: ""))
        }
        if out.count > 1 { for i in out.indices { out[i].tag = "S\(i + 1)" } }
        return out
    }

    public var isSplit: Bool { feeds.count > 1 }

    public func feedIndex(_ cell: Cell) -> Int { feeds.firstIndex { $0.contains(cell) } ?? 0 }

    /// Every processor driving any part of this wall.
    public var processorIDs: [UUID] {
        var out: [UUID] = []
        for f in feeds where !f.isEmpty { if let id = f.processorID, !out.contains(id) { out.append(id) } }
        return out
    }

    /// Sets the canvas position of feed `index` (0 = the wall's own).
    public mutating func setCanvas(feed index: Int, x: Int, y: Int) {
        if index == 0 { canvasX = x; canvasY = y; return }
        guard let zid = feeds[safe: index]?.zoneID else { return }
        migrateSplit()
        guard let i = zones?.firstIndex(where: { $0.id == zid }) else { return }
        zones![i].canvasX = x; zones![i].canvasY = y
    }

    /// Hands panels to a processor: the wall's own processor takes them back, any other gets (or grows) its zone.
    public mutating func assign(_ cells: Set<Cell>, to processor: UUID?) {
        migrateSplit()
        var zs = zones ?? []
        for i in zs.indices { zs[i].cells.subtract(cells) }
        if processor != processorID {
            if let i = zs.firstIndex(where: { $0.processorID == processor }) { zs[i].cells.formUnion(cells) }
            else { zs.append(WallZone(processorID: processor, cells: cells)) }
        }
        zs.removeAll { $0.cells.isEmpty }
        zones = zs.isEmpty ? nil : zs
    }

    public func isEnabled(_ cell: Cell) -> Bool { !disabled.contains(cell) }
    public var panelCount: Int { cols * rows - disabled.count }

    /// "Main Wall" → MW, "Header" → HEAD.
    public var labelCode: String {
        if !code.isEmpty { return code }
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1 { return words.map { $0.allSatisfy(\.isNumber) ? $0 : String($0.prefix(1)) }.joined().uppercased() }
        return String((words.first ?? "W").prefix(4)).uppercased()
    }

    public static let palette = ["4F8CFF", "FF9F43", "2ED573", "A29BFE", "FF6B81", "1DD1A1", "FECA57", "54A0FF"]
}

// MARK: - Processors & sources

public struct Processor: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// House convention: processors are numbered (1, 2, 3); distros are lettered per processor (1A, 1B).
    public var number: String
    public var model: ProcessorModel { didSet { clampToModel() } }
    public var inputW: Int
    public var inputH: Int
    public var distros: Int
    public var autoDistros = false
    public var backup = false
    public var portPixelsOverride = 0
    public var sourceID: UUID?
    public var sourceOutput = 0

    public init(index: Int, model: ProcessorModel = .bromptonSX40) {
        let s = model.spec
        name = "Processor \(index + 1)"
        number = "\(index + 1)"
        self.model = model
        inputW = min(s.maxInputW, 3840); inputH = min(s.maxInputH, 2160)
        distros = s.usesDistros ? min(2, s.trunks) : 0
    }

    mutating func clampToModel() {
        let s = model.spec
        inputW = min(inputW, s.maxInputW); inputH = min(inputH, s.maxInputH)
        distros = s.usesDistros ? min(max(distros, 2), s.trunks) : 0
    }

    public var spec: ProcessorSpec { model.spec }

    /// Distro name, e.g. 1A, 1B.
    public func distroName(_ d: Int) -> String { number + String(UnicodeScalar(UInt8(65 + d))) }

    /// "1A-3" (processor 1, distro A, port 3) or "1-P3" for direct-port processors.
    public func portLabel(_ i: Int) -> String {
        let s = spec
        if s.usesDistros { return "\(distroName(i / s.portsPerDistributor))-\(i % s.portsPerDistributor + 1)" }
        return "\(number)-P\(i + 1)"
    }
}

public struct VideoOutput: Codable, Hashable, Sendable {
    public var w: Int, h: Int, hz: Double
    public init(w: Int = 3840, h: Int = 2160, hz: Double = 60) { self.w = w; self.h = h; self.hz = hz }
}

public struct MediaServer: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var gpu = "NVIDIA Quadro / RTX (4× DP)"
    public var outputs: [VideoOutput] = Array(repeating: VideoOutput(), count: 4)
    public var mosaicCols = 4
    public var mosaicRows = 1
    public init(name: String) { self.name = name }
}

// MARK: - Project

public enum UnitSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case imperial, metric
    public var id: String { rawValue }
}

public enum PowerBasis: String, Codable, CaseIterable, Identifiable, Sendable {
    case max, typical
    public var id: String { rawValue }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var frameRate = 60.0
    public var bitDepth = 8
    public var voltage = CircuitVoltage.v208
    public var breakerAmps = 20.0
    /// 0.8 = 80% continuous-load rule.
    public var derate = 0.8
    public var threePhase = true
    public var powerBasis = PowerBasis.max
    public var units = UnitSystem.imperial
    public init() {}
}

public struct RoomModelRef: Codable, Hashable, Sendable {
    public var path: String
    /// Meters per model unit (SketchUp exports are usually inches → 0.0254).
    public var scale: Double = 1
    public var offset = Vec3(0, 0, 0)
    public var rotY = 0.0
    public var opacity = 0.6
    public var visible = true
    public init(path: String, scale: Double) { self.path = path; self.scale = scale }
}

public struct LEDProject: Codable, Hashable, Sendable {
    public var name = "Untitled Set"
    public var client = ""
    public var venue = ""
    public var designer = ""
    public var settings = ProjectSettings()
    public var panelTypes: [PanelType] = []
    public var walls: [Wall] = []
    public var processors: [Processor] = []
    public var servers: [MediaServer] = []
    public var room: RoomModelRef?
    public var titleBlock = TitleBlock()
    public var drawing = DrawingOptions()
    public var comp = CompSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case name, client, venue, designer, settings, panelTypes, walls, processors, servers, room, titleBlock, drawing, comp
    }

    // Tolerant decoding so older project files keep opening as fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Set"
        client = try c.decodeIfPresent(String.self, forKey: .client) ?? ""
        venue = try c.decodeIfPresent(String.self, forKey: .venue) ?? ""
        designer = try c.decodeIfPresent(String.self, forKey: .designer) ?? ""
        settings = try c.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? ProjectSettings()
        panelTypes = try c.decodeIfPresent([PanelType].self, forKey: .panelTypes) ?? []
        walls = try c.decodeIfPresent([Wall].self, forKey: .walls) ?? []
        processors = try c.decodeIfPresent([Processor].self, forKey: .processors) ?? []
        servers = try c.decodeIfPresent([MediaServer].self, forKey: .servers) ?? []
        room = try c.decodeIfPresent(RoomModelRef.self, forKey: .room)
        titleBlock = try c.decodeIfPresent(TitleBlock.self, forKey: .titleBlock) ?? TitleBlock()
        drawing = try c.decodeIfPresent(DrawingOptions.self, forKey: .drawing) ?? DrawingOptions()
        comp = try c.decodeIfPresent(CompSettings.self, forKey: .comp) ?? CompSettings()
    }

    /// A starter set: one SX40 fed by output 1 of a 4-output media server, driving one wall.
    public static func starter() -> LEDProject {
        var p = LEDProject()
        p.panelTypes = [PanelType(PanelLibrary.all[0]), PanelType(PanelLibrary.all[2])]
        let server = MediaServer(name: "Media Server 1")
        var proc = Processor(index: 0)
        proc.sourceID = server.id
        var wall = Wall(name: "Main Wall", colorHex: Wall.palette[0], panelTypeID: p.panelTypes[0].id, cols: 16, rows: 8)
        wall.position = Vec3(-4, 0, 0)
        wall.processorID = proc.id
        p.servers = [server]; p.processors = [proc]; p.walls = [wall]
        return p
    }

    public func panelType(_ id: UUID?) -> PanelType? { panelTypes.first { $0.id == id } ?? panelTypes.first }
    public func wallIndex(_ id: UUID) -> Int? { walls.firstIndex { $0.id == id } }
    public func processorIndex(_ id: UUID) -> Int? { processors.firstIndex { $0.id == id } }
    public func serverIndex(_ id: UUID) -> Int? { servers.firstIndex { $0.id == id } }
    public func panelTypeIndex(_ id: UUID) -> Int? { panelTypes.firstIndex { $0.id == id } }
}
