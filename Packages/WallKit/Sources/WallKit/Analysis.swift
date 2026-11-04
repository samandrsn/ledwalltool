import Foundation

public enum IssueLevel: Int, Comparable, Sendable {
    case info, warning, error
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct Issue: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var level: IssueLevel
    public var message: String
    public var wallID: UUID?
    public var processorID: UUID?
    public var kind: WiringKind?
}

public struct DataRun: Hashable, Sendable {
    public var cells: [Cell]
    public var explicitPort: Int?
    public var pixels: Int
    /// Which section of a split wall (0 when not split) and the processor driving it.
    public var feed = 0
    public var processorID: UUID?
    public var portIndex = 0
    public var label = ""
    public var loadPercent = 0.0
}

public struct PowerRun: Hashable, Sendable {
    public var cells: [Cell]
    public var watts: Double
    public var amps: Double
    public var label = ""
    public var phase: String?
}

public struct WallReport: Sendable {
    public var wall: Wall
    public var spec: PanelSpec
    public var panelCount: Int
    public var pixels: Int
    public var resW: Int, resH: Int
    public var widthM: Double, heightM: Double
    public var kg: Double
    public var wMax: Double, wAvg: Double
    /// Smallest panels-per-port limit across the wall's processors.
    public var dataCap: Int
    /// Panels-per-port limit for each feed (section).
    public var dataCaps: [Int]
    public var feeds: [Feed]
    public var powerCap: Int
    public var dataRuns: [DataRun]
    public var powerRuns: [PowerRun]
}

public struct PortLoad: Hashable, Sendable {
    public var pixels = 0
    public var panels = 0
    public var runs: [String] = []
}

/// One wall (or one section of a split wall) placed on a processor's input canvas.
public struct CanvasSlot: Hashable, Sendable {
    public var wallID: UUID
    public var feed: Int
    public var name: String
    public var x: Int, y: Int, w: Int, h: Int
    public var pixels: Int
    public var cols: Range<Int>, rows: Range<Int>
}

public struct ProcessorReport: Sendable {
    public var processor: Processor
    public var spec: ProcessorSpec
    public var portCapacity: Int
    public var ports: [Int: PortLoad]
    public var portsNeeded: Int
    public var portsAvailable: Int
    public var hardMax: Int
    public var distrosNeeded: Int
    public var distrosUsed: Int
    public var pixelsUsed: Int
    public var wallIDs: [UUID]
    public var slots: [CanvasSlot]
    public var canvasUsedW: Int
    public var canvasUsedH: Int
}

public struct MosaicCell: Hashable, Sendable { public var index: Int; public var x: Int, y: Int, w: Int, h: Int }

public struct ServerReport: Sendable {
    public var server: MediaServer
    public var feeds: [Int: [UUID]]
    public var cells: [MosaicCell]
    public var canvasW: Int, canvasH: Int
}

public struct Totals: Sendable {
    public var panels = 0
    public var pixels = 0
    public var kg = 0.0
    public var wMax = 0.0
    public var wAvg = 0.0
    public var circuits = 0
    public var dataRuns = 0
    public var lineAmps: [String: Double] = ["L1": 0, "L2": 0, "L3": 0]
    public var btuPerHour: Double { wAvg * 3.412 }
    public var feeder208: Int? {
        let leg = max(Analysis.amps(wMax, .threePhase208), lineAmps.values.max() ?? 0)
        return [30, 60, 100, 200, 400, 600, 800, 1200].first { Double($0) * 0.8 >= leg }
    }
}

public enum Service: String, CaseIterable, Identifiable, Sendable {
    case single120 = "120 V 1Φ", single208 = "208 V 1Φ", threePhase208 = "208 V 3Φ per leg",
         single230 = "230 V 1Φ", single240 = "240 V 1Φ", threePhase400 = "400 V 3Φ per leg"
    public var id: String { rawValue }
}

public struct Report: Sendable {
    public var walls: [UUID: WallReport] = [:]
    public var processors: [UUID: ProcessorReport] = [:]
    public var servers: [UUID: ServerReport] = [:]
    public var issues: [Issue] = []
    public var totals = Totals()

    public func worstLevel(wall id: UUID) -> IssueLevel? { issues.filter { $0.wallID == id }.map(\.level).max() }
    public func worstLevel(processor id: UUID) -> IssueLevel? { issues.filter { $0.processorID == id }.map(\.level).max() }
    public var errorCount: Int { issues.filter { $0.level == .error }.count }
    public var warningCount: Int { issues.filter { $0.level == .warning }.count }
}

public enum Analysis {
    public static func amps(_ watts: Double, _ s: Service) -> Double {
        switch s {
        case .single120: return watts / 120
        case .single208: return watts / 208
        case .threePhase208: return watts / (3.0.squareRoot() * 208)
        case .single230: return watts / 230
        case .single240: return watts / 240
        case .threePhase400: return watts / (3.0.squareRoot() * 400)
        }
    }

    public static func portCapacity(_ project: LEDProject, _ proc: Processor?) -> Int {
        let s = project.settings
        guard let proc else { return Int(650_000 * 60 / s.frameRate) }
        var px = Double(proc.portPixelsOverride > 0 ? proc.portPixelsOverride : proc.spec.portPixels)
        px *= 60 / max(1, s.frameRate)
        if proc.spec.halfAbove8Bit && s.bitDepth > 8 { px *= 0.5 }
        return Int(px)
    }

    public static func circuitCapacity(_ project: LEDProject, _ spec: PanelSpec, voltage: CircuitVoltage? = nil) -> Int {
        let s = project.settings
        let watts = (voltage ?? s.voltage).volts * s.breakerAmps * s.derate
        var n = Int(watts / max(1, spec.wMax))
        if spec.maxPerPowerLink > 0 { n = min(n, spec.maxPerPowerLink) }
        return max(1, n)
    }

    public static func mosaic(_ server: MediaServer) -> [MosaicCell] {
        let cols = max(1, server.mosaicCols)
        var colW: [Int: Int] = [:], rowH: [Int: Int] = [:]
        for (k, o) in server.outputs.enumerated() {
            colW[k % cols] = max(colW[k % cols] ?? 0, o.w); rowH[k / cols] = max(rowH[k / cols] ?? 0, o.h)
        }
        return server.outputs.enumerated().map { k, o in
            let c = k % cols, r = k / cols
            return MosaicCell(index: k, x: (0..<c).reduce(0) { $0 + (colW[$1] ?? 0) }, y: (0..<r).reduce(0) { $0 + (rowH[$1] ?? 0) }, w: o.w, h: o.h)
        }
    }

    public static func analyze(_ project: LEDProject) -> Report {
        var rep = Report()
        let s = project.settings
        func add(_ l: IssueLevel, _ m: String, wall: UUID? = nil, proc: UUID? = nil, kind: WiringKind? = nil) {
            rep.issues.append(Issue(level: l, message: m, wallID: wall, processorID: proc, kind: kind))
        }

        // Walls
        for wall in project.walls {
            guard let pt = project.panelType(wall.panelTypeID) else { add(.error, "\(wall.name): no panel type", wall: wall.id); continue }
            let spec = pt.spec
            let feeds = wall.feeds
            let panelPx = spec.pxW * spec.pxH
            let dataCaps = feeds.map { f -> Int in
                var cap = portCapacity(project, project.processors.first { $0.id == f.processorID }) / max(1, panelPx)
                if spec.maxPerPort > 0 { cap = min(cap, spec.maxPerPort) }
                return cap
            }
            let dataCap = dataCaps.min() ?? 0
            let powerCap = circuitCapacity(project, spec)
            if dataCap < 1 { add(.error, "\(wall.name): one \(spec.name) exceeds a port's capacity at \(fmt(s.frameRate)) Hz / \(s.bitDepth)-bit", wall: wall.id, kind: .data) }
            let dResolved = Routing.resolveData(wall, caps: dataCaps.map { max(1, $0) })
            let dRuns = dResolved.map(\.run)
            let pRuns = Routing.resolve(wall, .power, cap: powerCap)

            var feedOf: [Cell: Int] = [:]
            for f in feeds { for c in f.cells { feedOf[c] = f.index } }
            for (i, r) in dResolved.enumerated() {
                if r.run.cells.contains(where: { (feedOf[$0] ?? 0) != r.feed }) {
                    add(.error, "\(wall.name): data run \(i + 1) crosses from section \(feeds[r.feed].tag) into another processor's section", wall: wall.id, kind: .data)
                }
            }
            for (kind, runs) in [(WiringKind.data, dRuns), (.power, pRuns)] {
                var seen: [Cell: Int] = [:]
                for (i, run) in runs.enumerated() {
                    let cap = kind == .power ? powerCap : dataCaps[safe: dResolved[i].feed] ?? dataCap
                    if run.cells.count > cap { add(.error, "\(wall.name): \(kind.rawValue) run \(i + 1) has \(run.cells.count) panels (max \(cap))", wall: wall.id, kind: kind) }
                    for c in run.cells { seen[c, default: 0] += 1 }
                }
                var missing = 0, dup = 0
                for c in 0..<wall.cols { for r in 0..<wall.rows where wall.isEnabled(Cell(c, r)) {
                    let n = seen[Cell(c, r)] ?? 0
                    if n == 0 { missing += 1 }
                    if n > 1 { dup += 1 }
                } }
                if missing > 0 { add(.error, "\(wall.name): \(missing) panel\(missing == 1 ? "" : "s") with no \(kind.rawValue) connection", wall: wall.id, kind: kind) }
                if dup > 0 { add(.error, "\(wall.name): \(dup) panel\(dup == 1 ? "" : "s") on more than one \(kind.rawValue) run", wall: wall.id, kind: kind) }
            }

            let count = wall.panelCount
            rep.walls[wall.id] = WallReport(
                wall: wall, spec: spec, panelCount: count, pixels: count * panelPx,
                resW: wall.cols * spec.pxW, resH: wall.rows * spec.pxH,
                widthM: Double(wall.cols) * spec.mmW / 1000, heightM: Double(wall.rows) * spec.mmH / 1000,
                kg: Double(count) * (spec.kg + wall.extraKgPerPanel), wMax: Double(count) * spec.wMax, wAvg: Double(count) * spec.wAvg,
                dataCap: dataCap, dataCaps: dataCaps, feeds: feeds, powerCap: powerCap,
                dataRuns: dResolved.map { DataRun(cells: $0.run.cells, explicitPort: $0.run.port, pixels: $0.run.cells.count * panelPx,
                                                  feed: $0.feed, processorID: feeds[safe: $0.feed]?.processorID) },
                powerRuns: pRuns.map { PowerRun(cells: $0.cells, watts: Double($0.cells.count) * spec.wMax, amps: Double($0.cells.count) * spec.wMax / s.voltage.volts) })
            for f in feeds where f.processorID == nil && !f.isEmpty {
                add(.warning, f.tag.isEmpty ? "\(wall.name): not assigned to a processor" : "\(wall.name) section \(f.tag): not assigned to a processor", wall: wall.id)
            }
        }

        // Processors: port allocation
        for proc in project.processors {
            let spec = proc.spec
            let cap = portCapacity(project, proc)
            let walls = project.walls.filter { $0.processorIDs.contains(proc.id) && rep.walls[$0.id] != nil }
            var ports: [Int: PortLoad] = [:]
            var explicit = Set<Int>()
            for w in walls { for r in rep.walls[w.id]!.dataRuns where r.processorID == proc.id { if let p = r.explicitPort { explicit.insert(p) } } }
            var next = 0
            var slots: [CanvasSlot] = []
            for w in walls {
                var wr = rep.walls[w.id]!
                for f in wr.feeds where f.processorID == proc.id && !f.isEmpty {
                    let px = f.cells.filter(w.isEnabled).count * wr.spec.pxW * wr.spec.pxH
                    slots.append(CanvasSlot(wallID: w.id, feed: f.index, name: f.tag.isEmpty ? w.name : "\(w.name) \(f.tag)",
                                            x: f.canvasX, y: f.canvasY, w: f.cols.count * wr.spec.pxW, h: f.rows.count * wr.spec.pxH,
                                            pixels: px, cols: f.cols, rows: f.rows))
                }
                for i in wr.dataRuns.indices where wr.dataRuns[i].processorID == proc.id {
                    var idx: Int
                    if let p = wr.dataRuns[i].explicitPort { idx = p } else {
                        while explicit.contains(next) || ports[next] != nil { next += 1 }
                        idx = next; next += 1
                    }
                    wr.dataRuns[i].portIndex = idx
                    wr.dataRuns[i].label = proc.portLabel(idx)
                    wr.dataRuns[i].loadPercent = 100 * Double(wr.dataRuns[i].pixels) / Double(max(1, cap))
                    var load = ports[idx] ?? PortLoad()
                    load.pixels += wr.dataRuns[i].pixels; load.panels += wr.dataRuns[i].cells.count; load.runs.append("\(w.name) run \(i + 1)")
                    ports[idx] = load
                }
                rep.walls[w.id] = wr
            }
            let needed = (ports.keys.max() ?? -1) + 1
            let distNeeded = spec.usesDistros ? Int(ceil(Double(needed) / Double(spec.portsPerDistributor))) : 0
            let distUsed = spec.usesDistros ? (proc.autoDistros ? distNeeded : proc.distros) : 0
            var avail = spec.usesDistros ? spec.portsPerDistributor * min(distUsed, spec.trunks) : spec.directPorts
            var hardMax = spec.maxPorts
            if proc.backup { avail /= 2; hardMax /= 2 }
            let pixelsUsed = slots.reduce(0) { $0 + $1.pixels }
            let usedW = slots.map { $0.x + $0.w }.max() ?? 0
            let usedH = slots.map { $0.y + $0.h }.max() ?? 0
            rep.processors[proc.id] = ProcessorReport(processor: proc, spec: spec, portCapacity: cap, ports: ports, portsNeeded: needed,
                                                      portsAvailable: avail, hardMax: hardMax, distrosNeeded: distNeeded, distrosUsed: distUsed,
                                                      pixelsUsed: pixelsUsed, wallIDs: walls.map(\.id), slots: slots, canvasUsedW: usedW, canvasUsedH: usedH)
            let n = proc.name
            for (idx, p) in ports.sorted(by: { $0.key < $1.key }) {
                if p.pixels > cap { add(.error, "Port \(proc.portLabel(idx)): \(p.pixels.formatted()) px exceeds port capacity \(cap.formatted()) px", proc: proc.id) }
                if p.runs.count > 1 { add(.warning, "Port \(proc.portLabel(idx)): shared by \(p.runs.count) runs", proc: proc.id) }
            }
            if needed > hardMax {
                add(.error, "\(n): needs \(needed) ports; \(spec.name) supports \(hardMax)\(spec.usesDistros ? " (\(spec.trunks) distros)" : "")\(proc.backup ? " with backup" : "")", proc: proc.id)
            } else if needed > avail {
                add(.error, "\(n): needs \(needed) ports but only \(avail) available — add \(spec.usesDistros ? "distro \(proc.distroName(distUsed))" : "ports")", proc: proc.id)
            }
            if pixelsUsed > spec.maxPixels { add(.error, "\(n): pixel load \(pixelsUsed.formatted()) exceeds \(spec.name) capacity \(spec.maxPixels.formatted())", proc: proc.id) }
            if proc.inputW > spec.maxInputW || proc.inputH > spec.maxInputH { add(.error, "\(n): input \(proc.inputW)×\(proc.inputH) exceeds \(spec.name) max \(spec.maxInputW)×\(spec.maxInputH)", proc: proc.id) }

            for r in slots where r.x < 0 || r.y < 0 || r.x + r.w > proc.inputW || r.y + r.h > proc.inputH {
                add(.error, "\(r.name): canvas \(r.w)×\(r.h) at \(r.x),\(r.y) falls outside \(n)'s input \(proc.inputW)×\(proc.inputH)", wall: r.wallID, proc: proc.id)
            }
            for i in slots.indices { for j in slots.indices where j > i {
                let a = slots[i], b = slots[j]
                if a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h {
                    add(.warning, "\(a.name) and \(b.name) overlap on \(n)'s input canvas (mirrored content)", proc: proc.id)
                }
            } }
        }

        // Media servers
        for server in project.servers {
            var feeds: [Int: [UUID]] = [:]
            for proc in project.processors where proc.sourceID == server.id {
                guard let o = server.outputs[safe: proc.sourceOutput] else { add(.error, "\(proc.name): \(server.name) has no output \(proc.sourceOutput + 1)", proc: proc.id); continue }
                if proc.inputW > o.w || proc.inputH > o.h { add(.error, "\(proc.name): input \(proc.inputW)×\(proc.inputH) larger than \(server.name) output \(proc.sourceOutput + 1) (\(o.w)×\(o.h))", proc: proc.id) }
                if abs(o.hz - s.frameRate) > 0.01 { add(.warning, "\(server.name) output \(proc.sourceOutput + 1) runs at \(fmt(o.hz)) Hz but the project is \(fmt(s.frameRate)) Hz", proc: proc.id) }
                feeds[proc.sourceOutput, default: []].append(proc.id)
            }
            for (o, procs) in feeds where procs.count > 1 { add(.info, "\(server.name) output \(o + 1) feeds \(procs.count) processors (needs a splitter/DA; identical canvas)") }
            if server.outputs.count > server.mosaicCols * server.mosaicRows { add(.warning, "\(server.name): mosaic grid \(server.mosaicCols)×\(server.mosaicRows) is smaller than its \(server.outputs.count) outputs") }
            let cells = mosaic(server)
            rep.servers[server.id] = ServerReport(server: server, feeds: feeds, cells: cells,
                                                  canvasW: cells.map { $0.x + $0.w }.max() ?? 0, canvasH: cells.map { $0.y + $0.h }.max() ?? 0)
        }
        for proc in project.processors where proc.sourceID == nil { add(.info, "\(proc.name): no media server output assigned", proc: proc.id) }

        // Power: label circuits, balance phases round-robin across the whole set.
        let legs = s.voltage == .v120 ? ["L1", "L2", "L3"] : ["L1-L2", "L2-L3", "L3-L1"]
        var ci = 0
        for w in project.walls {
            guard var wr = rep.walls[w.id] else { continue }
            for i in wr.powerRuns.indices {
                wr.powerRuns[i].label = "\(w.labelCode)-C\(i + 1)"
                if s.threePhase {
                    let leg = legs[ci % 3]
                    wr.powerRuns[i].phase = leg
                    for l in leg.split(separator: "-") { rep.totals.lineAmps[String(l), default: 0] += wr.powerRuns[i].amps }
                }
                if wr.powerRuns[i].amps > s.breakerAmps * s.derate + 1e-6 {
                    add(.error, "\(w.name) \(wr.powerRuns[i].label): \(fmt1(wr.powerRuns[i].amps)) A exceeds \(fmt(s.breakerAmps)) A × \(Int(s.derate * 100))%", wall: w.id, kind: .power)
                }
                ci += 1
            }
            rep.walls[w.id] = wr
        }

        for wr in rep.walls.values {
            rep.totals.panels += wr.panelCount; rep.totals.pixels += wr.pixels; rep.totals.kg += wr.kg
            rep.totals.wMax += wr.wMax; rep.totals.wAvg += wr.wAvg
            rep.totals.circuits += wr.powerRuns.count; rep.totals.dataRuns += wr.dataRuns.count
        }
        rep.issues.sort { $0.level > $1.level }
        return rep
    }

    /// Processor models that could carry this processor's load on their own.
    public static func modelsThatFit(_ project: LEDProject, _ pr: ProcessorReport) -> [ProcessorModel] {
        ProcessorModel.allCases.filter { m in
            guard m != .custom else { return false }
            var p = pr.processor; p.model = m
            let cap = portCapacity(project, p), s = m.spec
            let need = pr.ports.values.reduce(0) { $0 + Int(ceil(Double($1.pixels) / Double(max(1, cap)))) }
            return need <= (pr.processor.backup ? s.maxPorts / 2 : s.maxPorts) && pr.pixelsUsed <= s.maxPixels
                && pr.processor.inputW <= s.maxInputW && pr.processor.inputH <= s.maxInputH
        }
    }
}

public func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression) }
public func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }
