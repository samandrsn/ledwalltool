import SwiftUI
import WallKit

struct ResourcesView: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selection: Selection?
    @Binding var workspace: Workspace

    var body: some View {
        let p = store.project, rep = store.report, s = p.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Checks") {
                    if rep.issues.isEmpty {
                        Label("Every wall is fully connected, and no processor, port, input or circuit is over capacity.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(rep.issues) { i in
                                Button { go(i) } label: {
                                    Label { Text(i.message).frame(maxWidth: .infinity, alignment: .leading) } icon: { Image(systemName: i.level.symbol).foregroundStyle(i.level.color) }
                                        .padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                section("Processors & Distribution") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(p.processors) { proc in if let r = rep.processors[proc.id] { ProcessorCard(report: r, selection: $selection) } }
                    }
                }

                if !p.servers.isEmpty {
                    section("Media Servers") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
                            ForEach(p.servers) { srv in
                                if let r = rep.servers[srv.id] {
                                    GroupBox {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Meter(label: "Outputs used", value: Double(r.feeds.count), max: Double(srv.outputs.count), format: { "\(Int($0))" })
                                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                                ForEach(srv.outputs.indices, id: \.self) { k in
                                                    GridRow {
                                                        Text("Out \(k + 1)").foregroundStyle(.secondary)
                                                        Text(verbatim: "\(srv.outputs[k].w)×\(srv.outputs[k].h) @ \(fmt(srv.outputs[k].hz))")
                                                        Text((r.feeds[k] ?? []).compactMap { id in p.processors.first { $0.id == id }?.name }.joined(separator: ", ").ifEmpty("—"))
                                                    }
                                                }
                                            }
                                            Text(verbatim: "Mosaic desktop \(r.canvasW)×\(r.canvasH)").font(.caption).foregroundStyle(.secondary)
                                        }
                                        .monospacedDigit()
                                    } label: { Text("\(srv.name)  ").bold() + Text(srv.gpu).foregroundColor(.secondary) }
                                }
                            }
                        }
                    }
                }

                section("Walls — Weight & Power") {
                    ScrollView(.horizontal) { GroupBox {
                        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                            GridRow {
                                ForEach(["Wall", "Panel", "Layout", "Size", "Res", "Weight", "kW max", "kW typ", "A @ \(Int(s.voltage.volts)) V", "Circuits", "Ports", "Processor"], id: \.self) {
                                    Text($0).foregroundStyle(.secondary).font(.caption)
                                }
                            }
                            Divider()
                            ForEach(p.walls) { w in
                                if let wr = rep.walls[w.id] {
                                    GridRow {
                                        Text(w.name).gridColumnAlignment(.leading)
                                        Text(wr.spec.name).gridColumnAlignment(.leading).lineLimit(1)
                                        Text(verbatim: "\(w.cols)×\(w.rows) (\(wr.panelCount))")
                                        Text(verbatim: "\(F.length(wr.widthM, s.units)) × \(F.length(wr.heightM, s.units))")
                                        Text(verbatim: "\(wr.resW)×\(wr.resH)")
                                        Text(F.weight(wr.kg))
                                        Text(String(format: "%.2f", wr.wMax / 1000))
                                        Text(String(format: "%.2f", wr.wAvg / 1000))
                                        Text(String(format: "%.1f", wr.wMax / s.voltage.volts))
                                        Text("\(wr.powerRuns.count)")
                                        Text("\(wr.dataRuns.count)")
                                        Text(w.processorIDs.compactMap { id in p.processors.first { $0.id == id }?.name }.joined(separator: " + ").ifEmpty("—"))
                                    }
                                }
                            }
                            Divider()
                            let t = rep.totals
                            GridRow {
                                Text("Total").bold().gridColumnAlignment(.leading)
                                Text("")
                                Text("\(t.panels)").bold()
                                Text("")
                                Text(F.mp(t.pixels)).bold()
                                Text(F.weight(t.kg)).bold()
                                Text(String(format: "%.2f", t.wMax / 1000)).bold()
                                Text(String(format: "%.2f", t.wAvg / 1000)).bold()
                                Text(String(format: "%.1f", t.wMax / s.voltage.volts)).bold()
                                Text("\(t.circuits)").bold()
                                Text("\(t.dataRuns)").bold()
                                Text("")
                            }
                        }
                        .font(.callout).monospacedDigit()
                        .padding(4)
                    } }
                }

                section("Power Service") {
                    FlowLayout(spacing: 14, lineSpacing: 14) {
                        GroupBox("Amps — max / typical") {
                            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                                ForEach(Service.allCases) { sv in
                                    GridRow {
                                        Text(sv.rawValue).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                        Text(F.amps(Analysis.amps(rep.totals.wMax, sv)))
                                        Text(F.amps(Analysis.amps(rep.totals.wAvg, sv))).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .monospacedDigit().padding(4)
                        }
                        GroupBox("Circuits needed (\(Int(s.breakerAmps)) A @ \(Int(s.derate * 100))%)") {
                            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                                GridRow {
                                    Text("Wall").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                    ForEach(CircuitVoltage.allCases) { Text("\(Int($0.volts)) V").foregroundStyle(.secondary) }
                                }
                                ForEach(p.walls) { w in
                                    if let wr = rep.walls[w.id] {
                                        GridRow {
                                            Text(w.name)
                                            ForEach(CircuitVoltage.allCases) { v in
                                                Text("\(Int(ceil(Double(wr.panelCount) / Double(Analysis.circuitCapacity(p, wr.spec, voltage: v)))))")
                                            }
                                        }
                                    }
                                }
                            }
                            .monospacedDigit().padding(4)
                        }
                        if s.threePhase {
                            GroupBox("Phase balance (max)") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(["L1", "L2", "L3"], id: \.self) { l in
                                        LabeledContent(l, value: F.amps(rep.totals.lineAmps[l] ?? 0))
                                    }
                                    Divider()
                                    Text(rep.totals.feeder208.map { "Suggested feeder: \($0) A 3Φ 208Y/120" } ?? "Split across multiple services")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .monospacedDigit().padding(4).frame(minWidth: 200)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1300, alignment: .leading)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }

    private func go(_ i: Issue) {
        if let w = i.wallID { selection = .wall(w); store.focusWallID = w; workspace = .map }
        else if let p = i.processorID { selection = .processor(p) }
    }
}

struct Meter: View {
    let label: String
    let value: Double
    let max: Double
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        let pct = max > 0 ? value / max : 0
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text("\(format(value)) / \(format(max))  (\(Int((pct * 100).rounded()))%)").monospacedDigit()
            }
            .font(.callout)
            ProgressView(value: min(1, pct))
                .tint(pct > 1 ? .red : pct > 0.85 ? .orange : .green)
        }
    }
}

struct ProcessorCard: View {
    @EnvironmentObject private var store: ProjectStore
    let report: ProcessorReport
    @Binding var selection: Selection?

    var body: some View {
        let r = report, proc = r.processor, spec = r.spec
        let capOver = r.portsNeeded > r.portsAvailable || r.pixelsUsed > spec.maxPixels || r.ports.values.contains { $0.pixels > r.portCapacity }
        let bad = store.report.issues.contains { $0.level == .error && $0.processorID == proc.id }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Meter(label: "Ports", value: Double(r.portsNeeded), max: Double(r.portsAvailable), format: { "\(Int($0))" })
                if spec.usesDistros {
                    Meter(label: "Distros (\(spec.distributorName))", value: Double(r.distrosNeeded), max: Double(max(r.distrosUsed, 1)), format: { "\(Int($0))" })
                }
                Meter(label: "Pixel load (MP)", value: Double(r.pixelsUsed) / 1e6, max: Double(spec.maxPixels) / 1e6)
                Meter(label: "Input width used", value: Double(r.canvasUsedW), max: Double(proc.inputW), format: { "\(Int($0))" })
                Meter(label: "Input height used", value: Double(r.canvasUsedH), max: Double(proc.inputH), format: { "\(Int($0))" })
                Text(verbatim: "Input \(proc.inputW)×\(proc.inputH) (max \(spec.maxInputW)×\(spec.maxInputH)) · \(r.portCapacity.formatted()) px/port\(proc.backup ? " · backup on" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                let n = max(r.portsAvailable, r.portsNeeded)
                let perRow = spec.usesDistros ? spec.portsPerDistributor : min(10, max(4, n))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: perRow), spacing: 3) {
                    ForEach(0..<n, id: \.self) { i in
                        let load = r.ports[i]
                        let pct = Double(load?.pixels ?? 0) / Double(max(1, r.portCapacity))
                        let over = pct > 1 || i >= r.portsAvailable
                        VStack(alignment: .leading, spacing: 1) {
                            Text(proc.portLabel(i)).font(.system(size: 9.5, weight: .medium))
                            Text(load == nil ? "—" : "\(Int((pct * 100).rounded()))%").font(.system(size: 9.5))
                        }
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).padding(.vertical, 3)
                        .background(alignment: .bottomLeading) {
                            GeometryReader { g in Rectangle().fill(over ? Color.red : .green).frame(width: g.size.width * min(1, pct), height: 2).frame(maxHeight: .infinity, alignment: .bottom) }
                        }
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(over ? Color.red : load == nil ? .secondary : .primary)
                        .help(load.map { "\($0.panels) panels, \($0.pixels.formatted()) px — \($0.runs.joined(separator: ", "))" } ?? "Free")
                    }
                }
                if capOver {
                    let fits = Analysis.modelsThatFit(store.project, r).map(\.spec.name)
                    Label(fits.isEmpty ? "No single unit fits — split across processors." : "Would fit on: \(fits.joined(separator: ", "))", systemImage: "lightbulb")
                        .font(.caption).foregroundStyle(.orange)
                } else if bad {
                    Label("Canvas placement issue — use Auto-Pack or move walls in Pixel Map.", systemImage: "lightbulb").font(.caption).foregroundStyle(.orange)
                }
            }
        } label: {
            HStack {
                Button(proc.name) { selection = .processor(proc.id) }.buttonStyle(.plain).bold()
                if bad { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
                Spacer()
                Text("\(spec.vendor) \(spec.name)").foregroundStyle(.secondary)
            }
        }
    }
}
