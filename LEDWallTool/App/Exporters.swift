import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WallKit

@MainActor
enum Exporters {
    static func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }

    static func exportDrawingsPDF(_ store: ProjectStore) {
        save(Drawings.pdf(store.project, store.report), name: "\(store.project.name) drawings.pdf", type: .pdf)
    }

    static func printDrawings(_ store: ProjectStore) {
        guard let doc = PDFDocument(data: Drawings.pdf(store.project, store.report)) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = .landscape
        let paper = store.project.drawing.paper.points
        info.paperSize = NSSize(width: paper.w, height: paper.h)
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        op.jobTitle = "\(store.project.name) drawings"
        if let w = NSApp.keyWindow { op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    /// Native-resolution PNG of one processor's input canvas, for content creators.
    static func pixelMapPNG(_ store: ProjectStore, _ procID: UUID) -> Data? {
        guard let proc = store.project.processors.first(where: { $0.id == procID }) else { return nil }
        let project = store.project, report = store.report
        let view = Canvas { ctx, _ in PixelMapRenderer.draw(ctx, project, report, proc, labels: true) }
            .frame(width: CGFloat(proc.inputW), height: CGFloat(proc.inputH))
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func exportPixelMap(_ store: ProjectStore, _ procID: UUID) {
        guard let proc = store.project.processors.first(where: { $0.id == procID }), let png = pixelMapPNG(store, procID) else { return }
        save(png, name: "\(store.project.name) — \(proc.name) pixel map \(proc.inputW)x\(proc.inputH).png", type: .png)
    }

    static func exportPixelMaps(_ store: ProjectStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for one pixel-map PNG per processor."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for proc in store.project.processors {
            if let png = pixelMapPNG(store, proc.id) {
                try? png.write(to: dir.appendingPathComponent("\(store.project.name) — \(proc.name) \(proc.inputW)x\(proc.inputH).png"))
            }
        }
    }

    static func exportCSV(_ store: ProjectStore) {
        let p = store.project, rep = store.report
        var rows = [["Section", "Item", "Detail", "Panels", "Pixels", "Load %", "Watts max", "Amps", "Phase"]]
        for w in p.walls {
            guard let wr = rep.walls[w.id] else { continue }
            rows.append(["Wall", w.name, "\(w.cols)x\(w.rows) \(wr.spec.mfr) \(wr.spec.name); \(wr.resW)x\(wr.resH); \(F.weight(wr.kg))", "\(wr.panelCount)", "\(wr.pixels)", "", "\(Int(wr.wMax))", "", ""])
            for r in wr.dataRuns { rows.append(["Data", w.name, r.label, "\(r.cells.count)", "\(r.pixels)", String(format: "%.1f", r.loadPercent), "", "", ""]) }
            for r in wr.powerRuns { rows.append(["Power", w.name, r.label, "\(r.cells.count)", "", "", "\(Int(r.watts))", String(format: "%.2f", r.amps), r.phase ?? ""]) }
        }
        for proc in p.processors {
            guard let r = rep.processors[proc.id] else { continue }
            rows.append(["Processor", proc.name, "\(proc.spec.name); ports \(r.portsNeeded)/\(r.portsAvailable); input \(proc.inputW)x\(proc.inputH)", "", "\(r.pixelsUsed)",
                         String(format: "%.1f", 100 * Double(r.pixelsUsed) / Double(proc.spec.maxPixels)), "", "", ""])
        }
        for i in rep.issues { rows.append(["Issue", "\(i.level)", i.message, "", "", "", "", "", ""]) }
        let csv = rows.map { $0.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") }.joined(separator: "\n")
        save(Data(csv.utf8), name: "\(p.name) resources.csv", type: .commaSeparatedText)
    }

    static func exportPanelLibrary(_ store: ProjectStore) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(store.project.panelTypes.map(\.spec)) else { return }
        save(d, name: "Panel Library.json", type: .json)
    }

    static func importPanelLibrary(_ store: ProjectStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let specs = try JSONDecoder().decode([PanelSpec].self, from: Data(contentsOf: url))
            store.project.panelTypes += specs.map(PanelType.init)
        } catch { store.alert("Couldn't import \(url.lastPathComponent)", error.localizedDescription) }
    }
}
