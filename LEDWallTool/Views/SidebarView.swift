import SwiftUI
import WallKit

struct SidebarView: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selection: Selection?

    var body: some View {
        let p = store.project, rep = store.report
        List(selection: $selection) {
            Section {
                HStack {
                    Label("Project Settings", systemImage: "gearshape")
                    Spacer()
                    if rep.errorCount > 0 {
                        Text("\(rep.errorCount)").foregroundStyle(.red).monospacedDigit().font(.caption)
                    }
                }
                .contentShape(Rectangle())
                .tag(Selection.project)
            } header: { Text(p.name) }

            Section {
                ForEach(p.walls) { w in
                    HStack {
                        Label { Text(w.name) } icon: { Image(systemName: w.attach == nil ? "square.grid.3x3.fill" : "square.grid.3x3.topleft.filled").foregroundStyle(Color(hex: w.colorHex)) }
                        Spacer()
                        statusIcon(rep.worstLevel(wall: w.id))
                        Text(verbatim: "\(w.cols)×\(w.rows)").foregroundStyle(.secondary).monospacedDigit().font(.caption)
                    }
                    .tag(Selection.wall(w.id))
                    .contextMenu {
                        Button("Add Header on Top") { selection = store.addAttached(to: w.id, edge: .top).map { .wall($0) } }
                        Button("Add Right Wing") { selection = store.addAttached(to: w.id, edge: .right).map { .wall($0) } }
                        Button("Add Left Wing") { selection = store.addAttached(to: w.id, edge: .left).map { .wall($0) } }
                        Divider()
                        Button("Duplicate") { selection = store.duplicateWall(w.id).map { .wall($0) } }
                        Button("Delete", role: .destructive) { store.deleteWall(w.id); selection = .project }
                    }
                }
                .onMove { store.project.walls.move(fromOffsets: $0, toOffset: $1) }
            } header: { header("Walls") { selection = .wall(store.addWall()) } }

            Section {
                ForEach(p.processors) { pr in
                    let r = rep.processors[pr.id]
                    HStack {
                        Label(pr.name, systemImage: "cpu")
                        Spacer()
                        statusIcon(rep.worstLevel(processor: pr.id))
                        if let r { Text("\(r.portsNeeded)/\(r.portsAvailable)").foregroundStyle(.secondary).monospacedDigit().font(.caption) }
                    }
                    .tag(Selection.processor(pr.id))
                    .contextMenu {
                        Button("Auto-Pack Canvas") { store.autoPack(pr.id) }
                        Button("Delete", role: .destructive) { store.deleteProcessor(pr.id); selection = .project }
                    }
                }
            } header: { header("Processors") { selection = .processor(store.addProcessor()) } }

            Section {
                ForEach(p.servers) { s in
                    HStack {
                        Label(s.name, systemImage: "display.2")
                        Spacer()
                        Text("\(s.outputs.count) out").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(Selection.server(s.id))
                    .contextMenu { Button("Delete", role: .destructive) { store.deleteServer(s.id); selection = .project } }
                }
            } header: { header("Media Servers") { selection = .server(store.addServer()) } }

            Section {
                ForEach(p.panelTypes) { t in
                    HStack {
                        Label(t.title, systemImage: "square.grid.2x2")
                        Spacer()
                        Text(verbatim: "\(t.spec.pxW)×\(t.spec.pxH)").foregroundStyle(.secondary).monospacedDigit().font(.caption)
                    }
                    .tag(Selection.panelType(t.id))
                    .contextMenu {
                        Button("Delete", role: .destructive) { store.deletePanelType(t.id); selection = .project }
                            .disabled(p.walls.contains { $0.panelTypeID == t.id })
                    }
                }
            } header: {
                HStack {
                    Text("Panel Types")
                    Spacer()
                    Menu {
                        ForEach(Array(PanelLibrary.all.enumerated()), id: \.offset) { _, spec in
                            Button("\(spec.mfr) \(spec.name)") { selection = .panelType(store.addPanelType(spec)) }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Add a panel type from the library")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func header(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add \(title.dropLast().lowercased())")
        }
    }

    @ViewBuilder private func statusIcon(_ level: IssueLevel?) -> some View {
        if let level, level > .info {
            Image(systemName: level.symbol).foregroundStyle(level.color).font(.caption)
        }
    }
}
