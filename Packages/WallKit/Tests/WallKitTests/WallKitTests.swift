import XCTest
import simd
@testable import WallKit

final class WallKitTests: XCTestCase {
    func testStarterProjectIsFullyConnected() {
        let p = LEDProject.starter()
        let rep = Analysis.analyze(p)
        let wr = rep.walls[p.walls[0].id]!
        XCTAssertEqual(wr.panelCount, 128)
        XCTAssertEqual(wr.dataCap, 14)               // 525,000 px / (192×192)
        XCTAssertEqual(wr.powerCap, 20)              // 208 V × 20 A × 80% / 160 W
        XCTAssertEqual(wr.dataRuns.reduce(0) { $0 + $1.cells.count }, 128)
        XCTAssertTrue(rep.issues.filter { $0.level == .error }.isEmpty, "\(rep.issues.map(\.message))")
    }

    func testPortLabelsUseHouseConvention() {
        var proc = Processor(index: 0)
        XCTAssertEqual(proc.distros, 2)
        XCTAssertEqual(proc.portLabel(0), "1A-1")
        XCTAssertEqual(proc.portLabel(12), "1B-3")
        proc.model = .novaMX30
        XCTAssertEqual(proc.portLabel(2), "1-P3")
    }

    func testOverCapacityIsFlagged() {
        var p = LEDProject.starter()
        p.walls[0].cols = 40; p.walls[0].rows = 12   // 480 panels > 2 XDs worth of ports
        let rep = Analysis.analyze(p)
        XCTAssertTrue(rep.issues.contains { $0.level == .error && $0.message.contains("add distro 1C") }, "\(rep.issues.map(\.message))")
    }

    func testEveryPresetCoversEveryPanelOnce() {
        var wall = LEDProject.starter().walls[0]
        wall.disabled = [Cell(0, 7), Cell(15, 7)]
        for preset in PatternPreset.allCases {
            for chunk in Chunking.allCases {
                var pat = RunPattern(); pat.preset = preset; pat.chunk = chunk
                let runs = Routing.generate(wall, cap: 14, pattern: pat)
                let all = runs.flatMap { $0 }
                XCTAssertEqual(all.count, wall.panelCount, "\(preset) \(chunk)")
                XCTAssertEqual(Set(all).count, all.count, "\(preset) \(chunk) duplicates")
                XCTAssertTrue(runs.allSatisfy { $0.count <= 14 }, "\(preset) \(chunk) over cap")
            }
        }
    }

    func testHeaderFollowsCurvedParent() {
        var p = LEDProject.starter()
        p.walls[0].colAngles = p.walls[0].colAngles.map { _ in 5 }
        var header = Wall(name: "Header", colorHex: "FF9F43", panelTypeID: p.walls[0].panelTypeID, cols: 16, rows: 2)
        header.attach = Attachment(wallID: p.walls[0].id, edge: .top, angle: 0)
        p.walls.append(header)
        let g = Geometry.compute(p)
        let parentTop = g[p.walls[0].id]!.panel(9, 7).apply(SIMD3(0, 0.5, 0))
        let headerBottom = g[header.id]!.panel(9, 0).origin
        XCTAssertEqual(simd_distance(parentTop, headerBottom), 0, accuracy: 1e-9)
    }

    func testCornerWingMeetsParentEdge() {
        var p = LEDProject.starter()
        var wing = Wall(name: "R Wing", colorHex: "2ED573", panelTypeID: p.walls[0].panelTypeID, cols: 6, rows: 8)
        wing.attach = Attachment(wallID: p.walls[0].id, edge: .right, angle: 90)
        p.walls.append(wing)
        let g = Geometry.compute(p)
        let parentRight = g[p.walls[0].id]!.colFrames[16].origin
        XCTAssertEqual(simd_distance(parentRight, g[wing.id]!.colFrames[0].origin), 0, accuracy: 1e-9)
        // 90° concave: the wing runs toward the audience (+Z).
        XCTAssertGreaterThan(g[wing.id]!.colFrames[6].origin.z, 2.9)
    }

    func testRadiusAngleRoundTrip() {
        let a = Geometry.angle(forRadius: 10, panelWidth: 0.5)
        XCTAssertEqual(Geometry.radius(forAngle: a, panelWidth: 0.5), 10, accuracy: 1e-9)
    }

    func testProjectRoundTripsThroughJSON() throws {
        var p = LEDProject.starter()
        p.walls[0].disabled = [Cell(1, 1)]
        p.walls[0].data.custom = true
        p.walls[0].data.runs = [Run(cells: [Cell(0, 0), Cell(0, 1)], port: 3)]
        let back = try JSONDecoder().decode(LEDProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    func testOlderProjectFilesStillOpen() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LEDProject.starter())) as! [String: Any]
        json["titleBlock"] = nil; json["drawing"] = nil
        let p = try JSONDecoder().decode(LEDProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(p.drawing, DrawingOptions())
        XCTAssertEqual(p.walls.count, 1)
    }

    func testScheduleAndBOMCountsMatchRuns() {
        let p = LEDProject.starter()
        let rep = Analysis.analyze(p)
        let cables = Schedules.cables(p, rep, walls: p.walls)
        let wr = rep.walls[p.walls[0].id]!
        XCTAssertEqual(cables.filter { $0.kind == .data }.count, wr.dataRuns.count)
        let bom = Schedules.bom(p, rep, walls: p.walls, sparesPercent: 10)
        let panels = bom.first { $0.category == "LED" }!
        XCTAssertEqual(panels.qty, 128)
        XCTAssertEqual(panels.spares, 13)
        let jumpers = bom.first { $0.item.hasPrefix("Panel-to-panel data") }!
        XCTAssertEqual(jumpers.qty, 128 - wr.dataRuns.count)
    }

    func testWallSplitAcrossTwoProcessors() {
        var p = LEDProject.starter()
        let p2 = Processor(index: 1)
        p.processors.append(p2)
        p.walls[0].cols = 40; p.walls[0].rows = 10                    // too big for one SX40's 2 XDs
        p.walls[0].split = WallSplit(axis: .columns, sections: [WallSection(start: 20, processorID: p2.id)])
        let wall = p.walls[0]
        XCTAssertEqual(wall.feeds.map(\.cols), [0..<20, 20..<40])
        let rep = Analysis.analyze(p)
        let wr = rep.walls[wall.id]!
        // Every run stays inside one section and is labelled on that section's processor.
        for r in wr.dataRuns {
            XCTAssertTrue(r.cells.allSatisfy { wall.feedIndex($0) == r.feed })
            XCTAssertTrue(r.label.hasPrefix(r.feed == 0 ? "1" : "2"), r.label)
        }
        XCTAssertEqual(wr.dataRuns.reduce(0) { $0 + $1.cells.count }, 400)
        XCTAssertEqual(rep.processors[p2.id]!.slots.map(\.w), [20 * 192])
        XCTAssertEqual(rep.processors[p.processors[0].id]!.pixelsUsed + rep.processors[p2.id]!.pixelsUsed, wr.pixels)
        XCTAssertFalse(rep.issues.contains { $0.level == .error }, "\(rep.issues.map(\.message))")

        // A hand-wired run that crosses the split is flagged.
        p.walls[0].data.custom = true
        p.walls[0].data.runs = [Run(cells: [Cell(19, 0), Cell(20, 0)])]
        XCTAssertTrue(Analysis.analyze(p).issues.contains { $0.message.contains("crosses") })
    }

    func testCompStageLayoutUnrollsHeadersAndWings() {
        var p = LEDProject.starter()
        let main = p.walls[0]                                         // 16×8 of 192 px → 3072×1536
        var header = Wall(name: "Header", colorHex: "FF9F43", panelTypeID: main.panelTypeID, cols: 16, rows: 2)
        header.attach = Attachment(wallID: main.id, edge: .top, angle: 0)
        var wing = Wall(name: "Wing", colorHex: "2ED573", panelTypeID: main.panelTypeID, cols: 4, rows: 4)
        wing.attach = Attachment(wallID: main.id, edge: .right, angle: 90)
        p.walls += [header, wing]
        let rects = Dictionary(uniqueKeysWithValues: Comp.rects(p, Analysis.analyze(p)).map { ($0.wallID, $0) })
        XCTAssertEqual(rects[header.id].map { [$0.x, $0.y] }, [0, 0])
        XCTAssertEqual(rects[main.id].map { [$0.x, $0.y] }, [0, 384])
        XCTAssertEqual(rects[wing.id].map { [$0.x, $0.y, $0.w] }, [3072, 384 + 1536 - 768, 768])
        XCTAssertTrue(Comp.fit(Array(rects.values)) == (3840, 1920))

        p.walls[2].comp = CompPlacement(x: 0, y: 0, hidden: true)
        XCTAssertEqual(Comp.rects(p, Analysis.analyze(p)).count, 2)
        XCTAssertEqual(Comp.slices(p, Analysis.analyze(p)).first { $0.wallID == main.id }?.output, 1)
    }

    func testPaintedZonesCenterSplitPlusBottomRows() {
        var p = LEDProject.starter()                                  // 16×8
        let p2 = Processor(index: 1), p3 = Processor(index: 2)
        p.processors += [p2, p3]
        var w = p.walls[0]
        w.assign(Set((8..<16).flatMap { c in (0..<8).map { Cell(c, $0) } }), to: p2.id)   // right half → 2
        w.assign(Set((0..<16).flatMap { c in (0..<2).map { Cell(c, $0) } }), to: p3.id) // bottom 2 rows → 3
        p.walls[0] = w
        let feeds = w.feeds
        XCTAssertEqual(feeds.map(\.cells.count), [48, 48, 32])
        XCTAssertEqual(feeds[1].rows, 2..<8)
        XCTAssertEqual(feeds[2].cols, 0..<16)
        let rep = Analysis.analyze(p)
        let wr = rep.walls[w.id]!
        for r in wr.dataRuns { XCTAssertTrue(r.cells.allSatisfy { feeds[r.feed].contains($0) }) }
        XCTAssertEqual(wr.dataRuns.reduce(0) { $0 + $1.cells.count }, 128)
        XCTAssertEqual(rep.processors[p3.id]!.slots.first.map { [$0.w, $0.h] }, [16 * 192, 2 * 192])
        XCTAssertEqual(Set(wr.dataRuns.map { $0.label.prefix(1) }), ["1", "2", "3"])

        // Handing panels back to the wall's own processor shrinks the zone.
        w.assign(Set((0..<16).map { Cell($0, 0) }), to: w.processorID)
        XCTAssertEqual(w.feeds.map(\.cells.count), [64, 48, 16])
    }

    func testDemoProjectHasNoErrors() {
        let p = LEDProject.demo()
        let rep = Analysis.analyze(p)
        XCTAssertEqual(rep.errorCount, 0, "\(rep.issues.map(\.message))")
        XCTAssertEqual(rep.walls[p.walls[1].id]!.feeds.count, 3)
    }
}
