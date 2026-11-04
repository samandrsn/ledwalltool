import SwiftUI
import WallKit

extension ProjectStore {
    func wallBinding(_ id: UUID) -> Binding<Wall>? {
        guard let w = project.walls.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.project.walls.first { $0.id == id } ?? w },
                       set: { v in if let i = self.project.wallIndex(id) { self.project.walls[i] = v } })
    }
    func processorBinding(_ id: UUID) -> Binding<Processor>? {
        guard let x = project.processors.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.project.processors.first { $0.id == id } ?? x },
                       set: { v in if let i = self.project.processorIndex(id) { self.project.processors[i] = v } })
    }
    func serverBinding(_ id: UUID) -> Binding<MediaServer>? {
        guard let x = project.servers.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.project.servers.first { $0.id == id } ?? x },
                       set: { v in if let i = self.project.serverIndex(id) { self.project.servers[i] = v } })
    }
    func panelTypeBinding(_ id: UUID) -> Binding<PanelType>? {
        guard let x = project.panelTypes.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.project.panelTypes.first { $0.id == id } ?? x },
                       set: { v in if let i = self.project.panelTypeIndex(id) { self.project.panelTypes[i] = v } })
    }
}

struct InspectorView: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selection: Selection?

    var body: some View {
        Group {
            switch selection ?? .project {
            case .project: ProjectInspector()
            case .wall(let id):
                if let b = store.wallBinding(id) { WallInspector(wall: b, selection: $selection) } else { ProjectInspector() }
            case .processor(let id):
                if let b = store.processorBinding(id) { ProcessorInspector(proc: b, selection: $selection) } else { ProjectInspector() }
            case .server(let id):
                if let b = store.serverBinding(id) { ServerInspector(server: b, selection: $selection) } else { ProjectInspector() }
            case .panelType(let id):
                if let b = store.panelTypeBinding(id) { PanelTypeInspector(type: b, selection: $selection) } else { ProjectInspector() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Right-aligned numeric field with a unit suffix.
struct NumberField<V: BinaryFloatingPoint>: View {
    let label: String
    @Binding var value: V
    var unit = ""
    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                CommitField(label: label, value: Binding(get: { Double(value) }, set: { value = V($0) }))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 90)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Number entry that only commits on Return or when the field loses focus, so partial input
/// like "4." or "-" isn't parsed and reformatted while you type.
struct CommitField: View {
    let label: String
    @Binding var value: Double
    var integer = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand { text = format(value); focused = false }
            .onChange(of: focused) { _, f in if !f { commit() } }
            // Follow outside changes (steppers, undo, drags) unless there's an unsaved edit in progress.
            .onChange(of: value) { old, v in if !focused || text == format(old) { text = format(v) } }
            .onAppear { text = format(value) }
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if let v = Double(cleaned), v.isFinite, v != value { value = v }
        text = format(value)
    }

    private func format(_ v: Double) -> String { integer ? String(Int(v.rounded())) : fmt((v * 1000).rounded() / 1000) }
}

struct IntField: View {
    let label: String
    @Binding var value: Int
    var unit = ""
    var range: ClosedRange<Int> = 0...1_000_000
    var stepper = false
    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                CommitField(label: label, value: Binding(get: { Double(value) }, set: { value = min(max(Int($0.rounded()), range.lowerBound), range.upperBound) }), integer: true)
                    .labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 80).monospacedDigit()
                if stepper { Stepper(label, value: $value, in: range).labelsHidden() }
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Project

struct ProjectInspector: View {
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        let t = store.report.totals
        Form {
            Section("Project") {
                TextField("Name", text: $store.project.name)
                TextField("Client", text: $store.project.client)
                TextField("Venue", text: $store.project.venue)
                TextField("Drawn by", text: $store.project.designer)
            }
            Section {
                Picker("Frame rate", selection: $store.project.settings.frameRate) {
                    ForEach(frameRates, id: \.self) { Text("\(fmt($0)) Hz").tag($0) }
                }
                Picker("Bit depth", selection: $store.project.settings.bitDepth) {
                    Text("8-bit").tag(8); Text("10-bit").tag(10); Text("12-bit").tag(12)
                }
            } header: { Text("Signal") } footer: { Text("Port capacity scales with frame rate; Novastar halves above 8-bit.") }
            Section("Power") {
                Picker("Circuits", selection: $store.project.settings.voltage) {
                    ForEach(CircuitVoltage.allCases) { Text($0.label).tag($0) }
                }
                Picker("Breaker", selection: $store.project.settings.breakerAmps) {
                    ForEach([15.0, 16, 20, 30, 32], id: \.self) { Text("\(Int($0)) A").tag($0) }
                }
                Picker("Load limit", selection: $store.project.settings.derate) {
                    Text("80% (continuous)").tag(0.8); Text("100%").tag(1.0)
                }
                Toggle("Three-phase distro (balance legs)", isOn: $store.project.settings.threePhase)
                Picker("Units", selection: $store.project.settings.units) {
                    Text("Feet / pounds").tag(UnitSystem.imperial); Text("Meters / kilograms").tag(UnitSystem.metric)
                }
            }
            Section("Totals") {
                LabeledContent("Panels", value: t.panels.formatted())
                LabeledContent("Pixels", value: F.mp(t.pixels))
                LabeledContent("Weight", value: F.weight(t.kg))
                LabeledContent("Power max / typical", value: "\(F.kw(t.wMax)) / \(F.kw(t.wAvg))")
                LabeledContent("Heat (typical)", value: "\(Int(t.btuPerHour).formatted()) BTU/h")
                LabeledContent("Data runs", value: "\(t.dataRuns)")
                LabeledContent("Circuits", value: "\(t.circuits) × \(Int(store.project.settings.breakerAmps)) A")
            }
            Section("Amps — max / typical") {
                ForEach(Service.allCases) { s in
                    LabeledContent(s.rawValue, value: "\(F.amps(Analysis.amps(t.wMax, s))) / \(F.amps(Analysis.amps(t.wAvg, s)))")
                }
            }
            if store.project.settings.threePhase {
                Section {
                    ForEach(["L1", "L2", "L3"], id: \.self) { l in LabeledContent(l, value: F.amps(t.lineAmps[l] ?? 0)) }
                } header: { Text("Phase balance (max)") } footer: {
                    Text(t.feeder208.map { "Suggested 208Y/120 3Φ feeder: \($0) A (80% continuous)." } ?? "Over 1200 A — split across services.")
                }
            }
            Section { Text("Catalog specs are typical figures. Verify panel and processor specs against current manufacturer data before deployment.").font(.caption).foregroundStyle(.secondary) }
        }
        .monospacedDigit()
    }
}

// MARK: - Wall

struct WallInspector: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var wall: Wall
    @Binding var selection: Selection?
    @State private var radius = 10.0
    @State private var colAnglesText = ""
    @State private var rowAnglesText = ""

    var body: some View {
        let p = store.project, wr = store.report.walls[wall.id], units = p.settings.units
        let spec = p.panelType(wall.panelTypeID)?.spec
        Form {
            Section {
                TextField("Name", text: $wall.name)
                TextField("Label code", text: $wall.code, prompt: Text(wall.labelCode))
                ColorPicker("Color", selection: Binding(get: { Color(hex: wall.colorHex) }, set: { wall.colorHex = $0.hex }), supportsOpacity: false)
                Picker("Panel", selection: $wall.panelTypeID) {
                    ForEach(p.panelTypes) { Text($0.title).tag(Optional($0.id)) }
                }
                IntField(label: "Columns", value: $wall.cols, range: 1...400, stepper: true)
                IntField(label: "Rows", value: $wall.rows, range: 1...200, stepper: true)
                Picker("Rigging", selection: $wall.rigging) { ForEach(Rigging.allCases) { Text($0.label).tag($0) } }
                NumberField(label: "Extra per panel", value: $wall.extraKgPerPanel, unit: "kg")
            } header: { Text("Wall") } footer: { Text("Extra weight covers frames, bumpers and curve blocks. Rigging sets where auto-wiring starts.") }

            if let wr {
                Section("Summary") {
                    LabeledContent("Size", value: "\(F.length(wr.widthM, units)) × \(F.length(wr.heightM, units))")
                    LabeledContent("Resolution", value: "\(wr.resW) × \(wr.resH)")
                    LabeledContent("Panels", value: "\(wr.panelCount)\(wall.disabled.isEmpty ? "" : " (\(wall.disabled.count) removed)")")
                    LabeledContent("Weight", value: F.weight(wr.kg))
                    LabeledContent("Power max / typical", value: "\(F.kw(wr.wMax)) / \(F.kw(wr.wAvg))")
                    LabeledContent("Data", value: "\(wr.dataRuns.count) ports · ≤\(wr.dataCap) per port")
                    LabeledContent("Power", value: "\(wr.powerRuns.count) circuits · ≤\(wr.powerCap) per circuit")
                }
                .monospacedDigit()
            }

            processorSections(p)

            Section {
                Toggle("Include in comp", isOn: Binding(get: { wall.comp?.hidden != true }, set: { show in
                    let r = Comp.rects(store.project, store.report).first { $0.wallID == wall.id }
                    wall.comp = CompPlacement(x: wall.comp?.x ?? r?.x ?? 0, y: wall.comp?.y ?? r?.y ?? 0, hidden: !show)
                }))
                if wall.comp?.hidden != true {
                    let r = Comp.rects(store.project, store.report).first { $0.wallID == wall.id }
                    IntField(label: "Comp X", value: Binding(get: { r?.x ?? 0 }, set: { wall.comp = CompPlacement(x: $0, y: r?.y ?? 0) }), unit: "px")
                    IntField(label: "Comp Y", value: Binding(get: { r?.y ?? 0 }, set: { wall.comp = CompPlacement(x: r?.x ?? 0, y: $0) }), unit: "px")
                }
            } header: { Text("Content Comp") } footer: { Text(wall.comp == nil ? "Placed by the stage layout. Drag it in the Comp view to pin it." : "") }

            Section {
                Picker("Attach to", selection: Binding(get: { wall.attach?.wallID }, set: { id in
                    wall.attach = id.map { Attachment(wallID: $0, edge: wall.attach?.edge ?? .right, angle: wall.attach?.angle ?? 90) }
                })) {
                    Text("Free standing").tag(UUID?.none)
                    ForEach(p.walls.filter { $0.id != wall.id }) { Text($0.name).tag(Optional($0.id)) }
                }
                if let a = wall.attach {
                    Picker("Edge", selection: Binding(get: { a.edge }, set: { wall.attach?.edge = $0 })) {
                        ForEach(AttachEdge.allCases) { Text($0.label).tag($0) }
                    }
                    NumberField(label: a.edge == .top ? "Tilt" : "Corner angle", value: Binding(get: { a.angle }, set: { wall.attach?.angle = $0 }), unit: "°")
                    NumberField(label: a.edge == .top ? "Column offset" : "Height offset", value: Binding(get: { a.offset }, set: { wall.attach?.offset = $0 }), unit: a.edge == .top ? "cols" : "m")
                } else {
                    NumberField(label: "X", value: $wall.position.x, unit: "m")
                    NumberField(label: "Y (height)", value: $wall.position.y, unit: "m")
                    NumberField(label: "Z (depth)", value: $wall.position.z, unit: "m")
                    NumberField(label: "Yaw", value: $wall.yaw, unit: "°")
                    NumberField(label: "Pitch", value: $wall.pitch, unit: "°")
                    NumberField(label: "Roll", value: $wall.roll, unit: "°")
                }
            } header: { Text("Placement") } footer: {
                if let a = wall.attach {
                    Text(a.edge == .top ? "Headers follow the parent wall's curve. Tilt + leans toward the audience." : "Corner + is concave (inside), − convex (outside); 90° is a square corner.")
                }
            }

            Section {
                let uniform = wall.colAngles.first.flatMap { f in wall.colAngles.allSatisfy { $0 == f } ? f : nil }
                LabeledContent("All column hinges") {
                    HStack {
                        Menu(uniform.map { "\(fmt($0))°" } ?? "Mixed") {
                            ForEach(anglePresets.filter { abs($0) < 90 }, id: \.self) { a in Button("\(a > 0 ? "+" : "")\(fmt(a))°") { wall.colAngles = wall.colAngles.map { _ in a } } }
                        }
                        .fixedSize()
                    }
                }
                if let spec, let u = uniform, u != 0 {
                    LabeledContent("Radius", value: F.length(Geometry.radius(forAngle: u, panelWidth: spec.size.w), units))
                }
                LabeledContent("Curve to radius") {
                    HStack(spacing: 4) {
                        CommitField(label: "Radius", value: $radius).labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 60)
                        Text("m").foregroundStyle(.secondary)
                        Button("Apply") {
                            if let spec, radius > 0 {
                                let a = (Geometry.angle(forRadius: radius, panelWidth: spec.size.w) * 100).rounded() / 100
                                wall.colAngles = wall.colAngles.map { _ in a }
                            }
                        }
                    }
                }
                LabeledContent("Column hinges") {
                    TextField("Column hinges", text: $colAnglesText, prompt: Text("0, 5, 5…"))
                        .labelsHidden()
                        .onSubmit { wall.colAngles = parse(colAnglesText, wall.cols - 1) }
                }
                LabeledContent("Row hinges") {
                    TextField("Row hinges", text: $rowAnglesText, prompt: Text("0, 0, 10…"))
                        .labelsHidden()
                        .onSubmit { wall.rowAngles = parse(rowAnglesText, wall.rows - 1) }
                }
                HStack {
                    Button("Flip Concave/Convex") { wall.colAngles = wall.colAngles.map { -$0 } }
                    Button("Flatten") { wall.colAngles = wall.colAngles.map { _ in 0 }; wall.rowAngles = wall.rowAngles.map { _ in 0 } }
                    Button("Restore Panels") { wall.disabled = [] }.disabled(wall.disabled.isEmpty)
                }
            } header: { Text("Curves & Hinges") } footer: {
                Text("Column hinges: + concave, − convex. Row hinges: + tilts upper rows toward the audience. In the 2D map's Structure layer, click any angle tag to set one hinge (curve blocks).")
            }
            .onAppear(perform: syncAngleText)
            .onChange(of: wall.colAngles) { _, _ in syncAngleText() }
            .onChange(of: wall.rowAngles) { _, _ in syncAngleText() }

            Section("Build") {
                Button("Add Header on Top") { selection = store.addAttached(to: wall.id, edge: .top).map { .wall($0) } }
                Button("Add Right Wing (90°)") { selection = store.addAttached(to: wall.id, edge: .right).map { .wall($0) } }
                Button("Add Left Wing (90°)") { selection = store.addAttached(to: wall.id, edge: .left).map { .wall($0) } }
                Button("Duplicate Wall") { selection = store.duplicateWall(wall.id).map { .wall($0) } }
                Button("Delete Wall", role: .destructive) { let id = wall.id; selection = .project; store.deleteWall(id) }
            }
        }
    }

    private func syncAngleText() {
        colAnglesText = wall.colAngles.map(fmt).joined(separator: ", ")
        rowAnglesText = wall.rowAngles.map(fmt).joined(separator: ", ")
    }

    private func parse(_ s: String, _ n: Int) -> [Double] {
        var a = s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        while a.count < max(0, n) { a.append(a.last ?? 0) }
        return Array(a.prefix(max(0, n)))
    }

    // MARK: Processors (the wall's own, plus zones driven by others)

    @ViewBuilder
    private func processorSections(_ p: LEDProject) -> some View {
        let feeds = wall.feeds
        let multi = feeds.count > 1
        Section {
            processorPicker(multi ? "Main processor" : "Processor", Binding(get: { wall.processorID }, set: { wall.processorID = $0 }), place: wall.id)
            if !(multi && feeds[0].isEmpty) {
                IntField(label: "Canvas X", value: $wall.canvasX, unit: "px")
                IntField(label: "Canvas Y", value: $wall.canvasY, unit: "px")
            }
            if multi { feedSummary(feeds[0]) }
            Menu {
                Section("Left / Right") {
                    ForEach(2...4, id: \.self) { n in Button("\(n) Processors") { store.splitWall(wall.id, into: n, axis: .columns) } }
                }
                Section("Top / Bottom") {
                    ForEach(2...3, id: \.self) { n in Button("\(n) Processors") { store.splitWall(wall.id, into: n, axis: .rows) } }
                }
                if multi {
                    Divider()
                    Button("All Panels Back to Main Processor") { store.splitWall(wall.id, into: 1, axis: .columns) }
                }
            } label: { Label(multi ? "Quick Split (replaces zones)" : "Split Across Processors", systemImage: "rectangle.split.2x1") }
            .disabled(wall.cols < 2 && wall.rows < 2)
        } header: { Text(multi ? "Data — \(feeds[0].tag) Main" : "Data") } footer: {
            Text("To give any panels or data runs to another processor or distro, paint them in the 2D Map's Processors layer, or right-click a run.")
        }
        if multi {
            ForEach(feeds.dropFirst(), id: \.index) { f in zoneSection(f) }
        }
    }

    @ViewBuilder
    private func zoneSection(_ f: Feed) -> some View {
        if let zid = f.zoneID {
            Section {
                processorPicker("Processor", zoneBinding(zid, \.processorID, nil), place: zid)
                IntField(label: "Canvas X", value: zoneBinding(zid, \.canvasX, 0), unit: "px")
                IntField(label: "Canvas Y", value: zoneBinding(zid, \.canvasY, 0), unit: "px")
                feedSummary(f)
                Button(role: .destructive) { store.assign(f.cells, wall: wall.id, to: wall.processorID) } label: {
                    Label("Return to Main Processor", systemImage: "arrow.uturn.backward")
                }
            } header: { Text("\(f.tag) · \(store.project.processors.first { $0.id == f.processorID }?.name ?? "No processor")") }
        }
    }

    private func feedSummary(_ f: Feed) -> some View {
        let caps = store.report.walls[wall.id]?.dataCaps ?? []
        let runs = store.report.walls[wall.id]?.dataRuns.filter { $0.feed == f.index } ?? []
        let panels = f.cells.filter(wall.isEnabled).count
        return Group {
            LabeledContent("Panels", value: f.isEmpty ? "None" : "\(panels) · C\(f.cols.lowerBound + 1)–\(f.cols.upperBound) R\(f.rows.lowerBound + 1)–\(f.rows.upperBound)")
            LabeledContent("Ports", value: runs.isEmpty ? "—" : "\(runs.count) · \(runs.first!.label) … \(runs.last!.label) · ≤\(caps[safe: f.index] ?? 0)/port")
        }
        .monospacedDigit()
    }

    private func zoneBinding<T>(_ zid: UUID, _ kp: WritableKeyPath<WallZone, T>, _ d: T) -> Binding<T> {
        Binding(get: { wall.zoneList.first { $0.id == zid }?[keyPath: kp] ?? d },
                set: { v in
                    var w = wall; w.migrateSplit()
                    if let i = w.zones?.firstIndex(where: { $0.id == zid }) { w.zones![i][keyPath: kp] = v }
                    wall = w
                })
    }

    /// Picking a processor also finds that feed a free spot on the new processor's canvas.
    private func processorPicker(_ title: String, _ sel: Binding<UUID?>, place: UUID) -> some View {
        Picker(title, selection: Binding(get: { sel.wrappedValue }, set: { v in
            sel.wrappedValue = v; var w = wall; store.placeCanvas(&w, only: [place]); wall = w
        })) {
            Text("None").tag(UUID?.none)
            ForEach(store.project.processors) { Text($0.name).tag(Optional($0.id)) }
        }
    }
}

// MARK: - Processor

struct ProcessorInspector: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var proc: Processor
    @Binding var selection: Selection?

    var body: some View {
        let p = store.project, r = store.report.processors[proc.id], spec = proc.spec
        Form {
            Section {
                TextField("Name", text: $proc.name)
                TextField("Number", text: $proc.number)
                Picker("Model", selection: $proc.model) {
                    ForEach(["Brompton", "Novastar", "Custom"], id: \.self) { vendor in
                        Section(vendor) {
                            ForEach(ProcessorModel.allCases.filter { $0.spec.vendor == vendor }) { Text($0.spec.name).tag($0) }
                        }
                    }
                }
            } header: { Text("Processor") } footer: {
                spec.usesDistros ? Text("Distros are lettered per processor: \(proc.distroName(0)), \(proc.distroName(1))… Ports read like \(proc.portLabel(2)).") : Text("Ports read like \(proc.portLabel(2)).")
            }
            Section("Input") {
                IntField(label: "Width", value: $proc.inputW, unit: "px")
                IntField(label: "Height", value: $proc.inputH, unit: "px")
                LabeledContent("Preset") {
                    Menu("\(proc.inputW)×\(proc.inputH)") {
                        ForEach(resolutionPresets, id: \.0) { w, h in Button("\(w)×\(h)") { proc.inputW = w; proc.inputH = h } }
                    }
                    .fixedSize()
                }
            }
            Section {
                if spec.usesDistros {
                    Toggle("Size distros automatically", isOn: $proc.autoDistros)
                    if !proc.autoDistros {
                        IntField(label: "\(spec.distributorName) distros", value: $proc.distros, range: 0...spec.trunks, stepper: true)
                    }
                }
                Toggle("Redundant ports (halves usable)", isOn: $proc.backup)
                IntField(label: "Port capacity override", value: $proc.portPixelsOverride, unit: "px")
            } header: { Text("Distribution") } footer: { Text("Override is pixels per port at 60 Hz 8-bit; 0 uses the model default.") }
            Section("Source") {
                Picker("Media server", selection: $proc.sourceID) {
                    Text("None").tag(UUID?.none)
                    ForEach(p.servers) { Text($0.name).tag(Optional($0.id)) }
                }
                if let s = p.servers.first(where: { $0.id == proc.sourceID }) {
                    Picker("Output", selection: $proc.sourceOutput) {
                        ForEach(s.outputs.indices, id: \.self) { k in Text(verbatim: "Out \(k + 1) — \(s.outputs[k].w)×\(s.outputs[k].h)").tag(k) }
                    }
                }
            }
            if let r {
                Section("Capacity") {
                    LabeledContent("Model limits", value: "\(spec.maxInputW)×\(spec.maxInputH) · \(F.mp(spec.maxPixels))")
                    LabeledContent("Per port", value: "\(r.portCapacity.formatted()) px @ \(fmt(p.settings.frameRate)) Hz")
                    LabeledContent("Ports", value: "\(r.portsNeeded) used / \(r.portsAvailable) available")
                    if spec.usesDistros {
                        LabeledContent("Distros", value: (0..<max(r.distrosUsed, 0)).map(proc.distroName).joined(separator: ", ").ifEmpty("None") + " · need \(r.distrosNeeded)")
                    }
                    LabeledContent("Pixel load", value: "\(F.mp(r.pixelsUsed)) (\(Int(100 * Double(r.pixelsUsed) / Double(spec.maxPixels)))%)")
                    LabeledContent("Walls", value: r.slots.map(\.name).joined(separator: ", ").ifEmpty("None"))
                }
                .monospacedDigit()
            }
            Section {
                Button("Auto-Pack Canvas") { store.autoPack(proc.id) }
                Button("Delete Processor", role: .destructive) { let id = proc.id; selection = .project; store.deleteProcessor(id) }
            }
        }
    }
}

// MARK: - Media server

struct ServerInspector: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var server: MediaServer
    @Binding var selection: Selection?

    var body: some View {
        let r = store.report.servers[server.id]
        Form {
            Section {
                TextField("Name", text: $server.name)
                TextField("GPU", text: $server.gpu)
                IntField(label: "Outputs", value: Binding(get: { server.outputs.count }, set: { n in
                    let n = max(1, min(16, n))
                    while server.outputs.count < n { server.outputs.append(server.outputs.last ?? VideoOutput()) }
                    server.outputs = Array(server.outputs.prefix(n))
                }), range: 1...16, stepper: true)
                IntField(label: "Mosaic columns", value: $server.mosaicCols, range: 1...16, stepper: true)
                IntField(label: "Mosaic rows", value: $server.mosaicRows, range: 1...16, stepper: true)
            } header: { Text("Media Server") } footer: {
                if let r { Text(verbatim: "Mosaic desktop \(r.canvasW)×\(r.canvasH)") }
            }
            ForEach(server.outputs.indices, id: \.self) { k in
                Section {
                    IntField(label: "Width", value: $server.outputs[k].w, unit: "px")
                    IntField(label: "Height", value: $server.outputs[k].h, unit: "px")
                    Picker("Refresh", selection: $server.outputs[k].hz) { ForEach(frameRates, id: \.self) { Text("\(fmt($0)) Hz").tag($0) } }
                } header: {
                    let feeds = store.project.processors.filter { $0.sourceID == server.id && $0.sourceOutput == k }.map(\.name)
                    Text("Output \(k + 1)\(feeds.isEmpty ? " — unused" : " → " + feeds.joined(separator: ", "))")
                }
            }
            Section { Button("Delete Media Server", role: .destructive) { let id = server.id; selection = .project; store.deleteServer(id) } }
        }
    }
}

// MARK: - Panel type

struct PanelTypeInspector: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var type: PanelType
    @Binding var selection: Selection?

    var body: some View {
        let used = store.project.walls.filter { $0.panelTypeID == type.id }.count
        Form {
            Section {
                LabeledContent("Load preset") {
                    Menu("Library") {
                        ForEach(Array(PanelLibrary.all.enumerated()), id: \.offset) { _, s in Button("\(s.mfr) \(s.name)") { type.spec = s } }
                    }
                    .fixedSize()
                }
                TextField("Manufacturer", text: $type.spec.mfr)
                TextField("Model", text: $type.spec.name)
            } header: { Text("Panel Type") }
            Section("Pixels & Size") {
                IntField(label: "Pixels wide", value: $type.spec.pxW, range: 1...4096)
                IntField(label: "Pixels high", value: $type.spec.pxH, range: 1...4096)
                NumberField(label: "Width", value: $type.spec.mmW, unit: "mm")
                NumberField(label: "Height", value: $type.spec.mmH, unit: "mm")
                NumberField(label: "Depth", value: $type.spec.mmD, unit: "mm")
                LabeledContent("Pitch", value: String(format: "%.2f mm", type.spec.mmW / Double(max(1, type.spec.pxW))))
            }
            Section("Weight & Power") {
                NumberField(label: "Weight", value: $type.spec.kg, unit: "kg")
                NumberField(label: "Max power", value: $type.spec.wMax, unit: "W")
                NumberField(label: "Typical power", value: $type.spec.wAvg, unit: "W")
                ForEach(CircuitVoltage.allCases) { v in
                    LabeledContent("Per circuit @ \(Int(v.volts)) V", value: "\(Analysis.circuitCapacity(store.project, type.spec, voltage: v)) panels")
                }
            }
            Section {
                IntField(label: "Max per data port", value: $type.spec.maxPerPort)
                IntField(label: "Max per power link", value: $type.spec.maxPerPowerLink)
            } header: { Text("Limits") } footer: { Text("0 = no limit. Power link is the manufacturer's max panels on one powerCON/TRUE1 daisy chain.") }
            Section {
                Text("Verify against the current manufacturer spec sheet.").font(.caption).foregroundStyle(.orange)
                Button("Duplicate Panel Type") { var t = type; t.id = UUID(); t.spec.name += " copy"; store.project.panelTypes.append(t); selection = .panelType(t.id) }
                Button("Delete Panel Type", role: .destructive) { let id = type.id; selection = .project; store.deletePanelType(id) }
                    .disabled(used > 0)
                    .help(used > 0 ? "Used by \(used) wall(s)" : "")
            }
        }
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
