import Foundation

extension LEDProject {
    /// A sample arena set for screenshots and first-time exploring: two IMAG walls, a curved center wall
    /// split across three processors with a tilted header, four SX40s on one 4-output media server.
    public static func demo() -> LEDProject {
        var p = LEDProject()
        p.name = "Demo Arena Set"
        p.client = "Demo Productions"
        p.venue = "Example Arena"
        p.designer = "LED Wall Tool"
        p.titleBlock.company = "Your Company"
        p.titleBlock.showDates = "Load-in Day 1"
        p.settings.voltage = .v208
        p.panelTypes = [PanelType(PanelLibrary.all[0]), PanelType(PanelLibrary.all[2])]
        let upad = p.panelTypes[0].id

        let server = MediaServer(name: "Media Server")
        p.servers = [server]
        p.processors = (0..<4).map { i in
            var pr = Processor(index: i)
            pr.sourceID = server.id
            pr.sourceOutput = i
            return pr
        }
        let ids = p.processors.map(\.id)

        var left = Wall(name: "IMAG Left", colorHex: Wall.palette[0], panelTypeID: upad, cols: 12, rows: 7)
        left.position = Vec3(-12.5, 1, 1.5); left.yaw = 15; left.rigging = .flown
        left.processorID = ids[0]

        var center = Wall(name: "Center", colorHex: Wall.palette[1], panelTypeID: upad, cols: 20, rows: 9)
        center.position = Vec3(-5, 0, 0)
        center.colAngles = Array(repeating: 2, count: 19)
        center.processorID = ids[1]
        center.assign(Set((10..<20).flatMap { c in (0..<9).map { Cell(c, $0) } }), to: ids[2])
        center.assign(Set((0..<20).flatMap { c in (0..<2).map { Cell(c, $0) } }), to: ids[3])
        center.zones![0].canvasX = 0; center.zones![0].canvasY = 0
        center.zones![1].canvasX = 0; center.zones![1].canvasY = 0

        var header = Wall(name: "Center Header", colorHex: Wall.palette[3], panelTypeID: upad, cols: 20, rows: 2)
        header.attach = Attachment(wallID: center.id, edge: .top, angle: 10)
        header.rigging = .flown
        header.processorID = ids[3]
        header.canvasY = 384 + 1344

        var right = Wall(name: "IMAG Right", colorHex: Wall.palette[2], panelTypeID: upad, cols: 12, rows: 7)
        right.position = Vec3(6.5, 1, 0); right.yaw = -15; right.rigging = .flown
        right.processorID = ids[3]
        right.canvasY = 384

        p.walls = [left, center, header, right]
        let rects = Comp.rects(p, Analysis.analyze(p))
        let fit = Comp.fit(rects)
        p.comp.width = fit.0; p.comp.height = fit.1
        return p
    }
}
