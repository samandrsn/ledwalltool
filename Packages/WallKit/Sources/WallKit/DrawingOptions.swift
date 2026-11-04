import Foundation

/// Title-block content that appears on every drawing sheet.
public struct TitleBlock: Codable, Hashable, Sendable {
    public var company = ""
    public var checkedBy = ""
    public var approvedBy = ""
    public var showDates = ""
    public var revisions: [Revision] = [Revision(rev: "A", date: Date(), description: "Issued for build", by: "")]
    public var generalNotes = """
    1. All panel positions shown viewed from the side noted in the title block.
    2. Data runs are numbered in chain order from the processor/distro port.
    3. Verify all panel, processor and power specifications against manufacturer data.
    4. Power circuits sized at the breaker rating and load limit shown; balance phases as noted.
    """
    public init() {}

    private enum CodingKeys: String, CodingKey { case company, checkedBy, approvedBy, showDates, revisions, generalNotes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TitleBlock()
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? d.company
        checkedBy = try c.decodeIfPresent(String.self, forKey: .checkedBy) ?? d.checkedBy
        approvedBy = try c.decodeIfPresent(String.self, forKey: .approvedBy) ?? d.approvedBy
        showDates = try c.decodeIfPresent(String.self, forKey: .showDates) ?? d.showDates
        revisions = try c.decodeIfPresent([Revision].self, forKey: .revisions) ?? d.revisions
        generalNotes = try c.decodeIfPresent(String.self, forKey: .generalNotes) ?? d.generalNotes
    }

    public var currentRevision: String { revisions.last?.rev ?? "—" }
}

public struct Revision: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var rev: String
    public var date: Date
    public var description: String
    public var by: String
    public init(rev: String, date: Date, description: String, by: String) {
        self.rev = rev; self.date = date; self.description = description; self.by = by
    }
}

public enum PaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case tabloid, archC, archD, a3, a1, letter
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .tabloid: return "Tabloid 11 × 17 in"
        case .archC: return "ARCH C 18 × 24 in"
        case .archD: return "ARCH D 24 × 36 in"
        case .a3: return "A3 297 × 420 mm"
        case .a1: return "A1 594 × 841 mm"
        case .letter: return "Letter 8.5 × 11 in"
        }
    }
    /// Landscape size in points.
    public var points: (w: Double, h: Double) {
        switch self {
        case .tabloid: return (17 * 72, 11 * 72)
        case .archC: return (24 * 72, 18 * 72)
        case .archD: return (36 * 72, 24 * 72)
        case .a3: return (420 / 25.4 * 72, 297 / 25.4 * 72)
        case .a1: return (841 / 25.4 * 72, 594 / 25.4 * 72)
        case .letter: return (11 * 72, 8.5 * 72)
        }
    }
}

public enum ViewSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case audience, rear, both
    public var id: String { rawValue }
    public var label: String {
        switch self { case .audience: return "Audience Side"; case .rear: return "Rear (Build) Side"; case .both: return "Both" }
    }
}

/// Which sheets go into the drawing set, and how they look. Saved with the project.
public struct DrawingOptions: Codable, Hashable, Sendable {
    public var paper = PaperSize.tabloid
    public var side = ViewSide.both
    public var cover = true
    public var system = true
    public var data = true
    public var power = true
    public var structure = true
    public var cableSchedule = true
    public var bom = true
    public var pixelMaps = true
    public var dimensions = true
    public var panelIDs = true
    public var gridZones = true
    public var asBuiltStamp = false
    /// Spare-parts allowance for the bill of materials, percent.
    public var sparesPercent = 5
    /// Walls to include; empty = all.
    public var wallIDs: Set<UUID> = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case paper, side, cover, system, data, power, structure, cableSchedule, bom, pixelMaps, dimensions, panelIDs, gridZones, asBuiltStamp, sparesPercent, wallIDs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DrawingOptions()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        paper = try v(.paper, d.paper); side = try v(.side, d.side)
        cover = try v(.cover, d.cover); system = try v(.system, d.system); data = try v(.data, d.data); power = try v(.power, d.power)
        structure = try v(.structure, d.structure); cableSchedule = try v(.cableSchedule, d.cableSchedule); bom = try v(.bom, d.bom)
        pixelMaps = try v(.pixelMaps, d.pixelMaps); dimensions = try v(.dimensions, d.dimensions); panelIDs = try v(.panelIDs, d.panelIDs)
        gridZones = try v(.gridZones, d.gridZones); asBuiltStamp = try v(.asBuiltStamp, d.asBuiltStamp)
        sparesPercent = try v(.sparesPercent, d.sparesPercent); wallIDs = try v(.wallIDs, d.wallIDs)
    }
}

// MARK: - Bill of materials & cable schedule

public struct BOMLine: Hashable, Sendable {
    public var category: String
    public var item: String
    public var qty: Int
    public var spares: Int
    public var note: String
    public var total: Int { qty + spares }
}

public struct CableLine: Hashable, Sendable {
    public var wall: String
    public var run: String
    public var kind: WiringKind
    public var panels: Int
    public var start: Cell?
    public var end: Cell?
    public var jumpers: Int
    public var load: String
    public var phase: String
}

public enum Schedules {
    public static func cables(_ p: LEDProject, _ rep: Report, walls: [Wall]) -> [CableLine] {
        var out: [CableLine] = []
        for w in walls {
            guard let wr = rep.walls[w.id] else { continue }
            for r in wr.dataRuns {
                out.append(CableLine(wall: w.name, run: r.label, kind: .data, panels: r.cells.count, start: r.cells.first, end: r.cells.last,
                                     jumpers: max(0, r.cells.count - 1), load: "\(Int(r.loadPercent.rounded()))%", phase: ""))
            }
            for r in wr.powerRuns {
                out.append(CableLine(wall: w.name, run: r.label, kind: .power, panels: r.cells.count, start: r.cells.first, end: r.cells.last,
                                     jumpers: max(0, r.cells.count - 1), load: String(format: "%.1f A", r.amps), phase: r.phase ?? ""))
            }
        }
        return out
    }

    public static func bom(_ p: LEDProject, _ rep: Report, walls: [Wall], sparesPercent: Int) -> [BOMLine] {
        func spares(_ n: Int) -> Int { n == 0 ? 0 : Int((Double(n) * Double(sparesPercent) / 100).rounded(.up)) }
        var lines: [BOMLine] = []
        var byType: [UUID: Int] = [:]
        for w in walls { if let id = p.panelType(w.panelTypeID)?.id { byType[id, default: 0] += w.panelCount } }
        for t in p.panelTypes where byType[t.id] != nil {
            let n = byType[t.id]!
            lines.append(BOMLine(category: "LED", item: "\(t.spec.mfr) \(t.spec.name)", qty: n, spares: spares(n), note: "\(t.spec.pxW)×\(t.spec.pxH) px, \(fmt(t.spec.kg)) kg"))
        }
        let procIDs = Set(walls.flatMap(\.processorIDs))
        var models: [ProcessorModel: Int] = [:]
        var distros = 0
        for pr in p.processors where procIDs.contains(pr.id) {
            models[pr.model, default: 0] += 1
            if let r = rep.processors[pr.id], pr.spec.usesDistros { distros += r.distrosUsed }
        }
        for (m, n) in models.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append(BOMLine(category: "Processing", item: "\(m.spec.vendor) \(m.spec.name)", qty: n, spares: 0, note: ""))
        }
        if distros > 0 { lines.append(BOMLine(category: "Processing", item: "Brompton XD distribution unit", qty: distros, spares: 0, note: "10× 1G ports each")) }
        let dataRuns = walls.compactMap { rep.walls[$0.id] }.flatMap(\.dataRuns)
        let powerRuns = walls.compactMap { rep.walls[$0.id] }.flatMap(\.powerRuns)
        let dJ = dataRuns.reduce(0) { $0 + max(0, $1.cells.count - 1) }, pJ = powerRuns.reduce(0) { $0 + max(0, $1.cells.count - 1) }
        lines.append(BOMLine(category: "Data", item: "Data home run (etherCON Cat6 / fiber)", qty: dataRuns.count, spares: spares(dataRuns.count), note: "Port to first panel"))
        lines.append(BOMLine(category: "Data", item: "Panel-to-panel data jumper", qty: dJ, spares: spares(dJ), note: ""))
        if distros > 0 { lines.append(BOMLine(category: "Data", item: "Processor-to-distro trunk (10G fiber)", qty: distros, spares: 0, note: "")) }
        lines.append(BOMLine(category: "Power", item: "Power home run (\(Int(p.settings.breakerAmps)) A circuit)", qty: powerRuns.count, spares: spares(powerRuns.count), note: p.settings.voltage.label))
        lines.append(BOMLine(category: "Power", item: "Panel-to-panel power jumper", qty: pJ, spares: spares(pJ), note: ""))
        let outputs = Set(p.processors.filter { procIDs.contains($0.id) && $0.sourceID != nil }.map { "\($0.sourceID!)-\($0.sourceOutput)" }).count
        if outputs > 0 { lines.append(BOMLine(category: "Video", item: "Media server output to processor (DP/HDMI/SDI)", qty: outputs, spares: 0, note: "")) }
        return lines
    }
}
