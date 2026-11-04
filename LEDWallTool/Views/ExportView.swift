import PDFKit
import SwiftUI
import WallKit

/// Drawing-set export: choose sheets, viewing side, paper and title-block details with a live preview.
struct ExportView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var pdf = Data()
    @State private var pageCount = 0

    var body: some View {
        let o = $store.project.drawing, tb = $store.project.titleBlock
        HStack(spacing: 0) {
            Form {
                Section("Sheets") {
                    Toggle("Cover & sheet index", isOn: o.cover)
                    Toggle("System overview (signal flow)", isOn: o.system)
                    Toggle("Data maps", isOn: o.data)
                    Toggle("Power maps", isOn: o.power)
                    Toggle("Structure & build (panel IDs, curve blocks, weights)", isOn: o.structure)
                    Toggle("Cable schedule", isOn: o.cableSchedule)
                    Toggle("Bill of materials", isOn: o.bom)
                    Toggle("Pixel maps (per processor)", isOn: o.pixelMaps)
                }
                Section {
                    Picker("Wall views", selection: o.side) { ForEach(ViewSide.allCases) { Text($0.label).tag($0) } }
                    Picker("Paper", selection: o.paper) { ForEach(PaperSize.allCases) { Text($0.label).tag($0) } }
                    Toggle("Overall dimensions", isOn: o.dimensions)
                    Toggle("Panel IDs (column.row)", isOn: o.panelIDs)
                    Toggle("Border grid zones", isOn: o.gridZones)
                    Toggle("AS BUILT stamp", isOn: o.asBuiltStamp)
                    Stepper("BOM spares: \(store.project.drawing.sparesPercent)%", value: o.sparesPercent, in: 0...50)
                } header: { Text("Layout") } footer: { Text("Rear (build side) sheets mirror the wall so crews working behind it see panels where they stand.") }
                Section {
                    Toggle("All walls", isOn: Binding(get: { store.project.drawing.wallIDs.isEmpty },
                                                      set: { all in store.project.drawing.wallIDs = all ? [] : Set(store.project.walls.map(\.id)) }))
                    if !store.project.drawing.wallIDs.isEmpty {
                        ForEach(store.project.walls) { w in
                            Toggle(w.name, isOn: Binding(get: { store.project.drawing.wallIDs.contains(w.id) }, set: { on in
                                if on { store.project.drawing.wallIDs.insert(w.id) } else if store.project.drawing.wallIDs.count > 1 { store.project.drawing.wallIDs.remove(w.id) }
                            }))
                        }
                    }
                } header: { Text("Walls") }
                Section("Title Block") {
                    TextField("Company", text: tb.company)
                    TextField("Drawn by", text: $store.project.designer)
                    TextField("Checked by", text: tb.checkedBy)
                    TextField("Approved by", text: tb.approvedBy)
                    TextField("Show dates", text: tb.showDates)
                }
                Section {
                    ForEach(tb.revisions) { $r in
                        HStack {
                            TextField("Rev", text: $r.rev, prompt: Text("Rev")).frame(width: 34)
                            DatePicker("Date", selection: $r.date, displayedComponents: .date)
                            TextField("Description", text: $r.description, prompt: Text("Description"))
                            TextField("By", text: $r.by, prompt: Text("By")).frame(width: 40)
                        }
                        .labelsHidden()
                    }
                    .onDelete { store.project.titleBlock.revisions.remove(atOffsets: $0) }
                    Button { addRevision() } label: { Label("Add Revision", systemImage: "plus") }
                } header: { Text("Revisions") }
                Section("General Notes (cover sheet)") {
                    TextEditor(text: tb.generalNotes).font(.callout).frame(minHeight: 90)
                }
            }
            .formStyle(.grouped)
            .frame(width: 400)

            Divider()

            VStack(spacing: 0) {
                PDFPreview(data: pdf)
                HStack {
                    Text("\(pageCount) sheet\(pageCount == 1 ? "" : "s") · \(store.project.drawing.paper.label)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button { Exporters.printDrawings(store) } label: { Label("Print…", systemImage: "printer") }
                    Button { Exporters.exportDrawingsPDF(store) } label: { Label("Export PDF…", systemImage: "square.and.arrow.up") }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
                .background(.bar)
            }
        }
        .frame(width: 1240, height: 780)
        .task(id: store.project.drawing) { await regenerate() }
        .task(id: store.project.titleBlock) { await regenerate() }
    }

    private func addRevision() {
        let last = store.project.titleBlock.revisions.last?.rev ?? "@"
        let next: String
        if let n = Int(last) { next = "\(n + 1)" }
        else if let c = last.unicodeScalars.last, c.value < 90, last.count == 1 { next = String(UnicodeScalar(c.value + 1)!) }
        else { next = last + "1" }
        store.project.titleBlock.revisions.append(Revision(rev: next, date: Date(), description: "", by: store.project.designer))
    }

    private func regenerate() async {
        try? await Task.sleep(for: .milliseconds(200))   // debounce typing
        guard !Task.isCancelled else { return }
        pdf = Drawings.pdf(store.project, store.report)
        pageCount = PDFDocument(data: pdf)?.pageCount ?? 0
    }
}

struct PDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = NSColor(white: 0.16, alpha: 1)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        guard context.coordinator.last != data else { return }
        context.coordinator.last = data
        let page = v.currentPage.flatMap { v.document?.index(for: $0) } ?? 0
        v.document = PDFDocument(data: data)
        if let doc = v.document, page < doc.pageCount, let pg = doc.page(at: page) { v.go(to: pg) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last: Data? }
}
