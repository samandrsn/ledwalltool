import Foundation
import simd

// Panel geometry in meters. Y up; walls face +Z (the audience side).
// Column hinge > 0 = concave (wall wraps toward the audience), < 0 = convex.
// Row hinge > 0 = upper rows tilt toward the audience.

public typealias Mat4 = simd_double4x4

@inline(__always) func rad(_ d: Double) -> Double { d * .pi / 180 }

public enum M4 {
    public static let identity = matrix_identity_double4x4
    public static func translate(_ x: Double, _ y: Double, _ z: Double) -> Mat4 {
        var m = identity; m.columns.3 = SIMD4(x, y, z, 1); return m
    }
    public static func rotX(_ deg: Double) -> Mat4 {
        let c = cos(rad(deg)), s = sin(rad(deg))
        return Mat4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }
    public static func rotY(_ deg: Double) -> Mat4 {
        let c = cos(rad(deg)), s = sin(rad(deg))
        return Mat4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }
    public static func rotZ(_ deg: Double) -> Mat4 {
        let c = cos(rad(deg)), s = sin(rad(deg))
        return Mat4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }
}

public extension Mat4 {
    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { let v = self * SIMD4(p, 1); return SIMD3(v.x, v.y, v.z) }
    var origin: SIMD3<Double> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
}

public struct PanelSize: Sendable { public var w: Double, h: Double, d: Double }
public extension PanelSpec { var size: PanelSize { PanelSize(w: mmW / 1000, h: mmH / 1000, d: (mmD > 0 ? mmD : 80) / 1000) } }

public struct WallGeometry: Sendable {
    public let size: PanelSize
    /// Frames at the bottom-left of each column; cols+1 entries (last = right edge).
    public let colFrames: [Mat4]
    /// Row walk in the column's local frame; rows+1 entries (last = top edge).
    public let rowFrames: [Mat4]

    /// Frame at the panel's bottom-left front corner; the panel spans local [0,w]×[0,h], depth −Z.
    public func panel(_ c: Int, _ r: Int) -> Mat4 { colFrames[c] * rowFrames[r] }
    public func center(_ c: Int, _ r: Int) -> SIMD3<Double> { panel(c, r).apply(SIMD3(size.w / 2, size.h / 2, 0)) }
}

public enum Geometry {
    static func colWalk(_ wall: Wall, _ w: Double) -> [Mat4] {
        var f = [M4.identity]
        for c in 0..<wall.cols {
            let a = c < wall.cols - 1 ? wall.colAngles[safe: c] ?? 0 : 0
            f.append(f[c] * M4.translate(w, 0, 0) * M4.rotY(-a))
        }
        return f
    }
    static func rowWalk(_ wall: Wall, _ h: Double) -> [Mat4] {
        var f = [M4.identity]
        for r in 0..<wall.rows {
            let a = r < wall.rows - 1 ? wall.rowAngles[safe: r] ?? 0 : 0
            f.append(f[r] * M4.translate(0, h, 0) * M4.rotX(a))
        }
        return f
    }

    public static func compute(_ project: LEDProject) -> [UUID: WallGeometry] {
        var out: [UUID: WallGeometry] = [:]
        var visiting = Set<UUID>()

        func base(_ w: Wall) -> Mat4 {
            M4.translate(w.position.x, w.position.y, w.position.z) * M4.rotY(w.yaw) * M4.rotX(w.pitch) * M4.rotZ(w.roll)
        }

        @discardableResult
        func build(_ wall: Wall) -> WallGeometry? {
            if let g = out[wall.id] { return g }
            guard let pt = project.panelType(wall.panelTypeID) else { return nil }
            let size = pt.spec.size
            let cw = colWalk(wall, size.w), rw = rowWalk(wall, size.h)
            visiting.insert(wall.id)
            defer { visiting.remove(wall.id) }
            var cols: [Mat4]
            if let a = wall.attach, !visiting.contains(a.wallID),
               let parent = project.walls.first(where: { $0.id == a.wallID }), let pg = build(parent) {
                switch a.edge {
                case .top:
                    // Header rows continue the parent's columns, so it follows the parent's curve exactly.
                    let off = Int(a.offset.rounded())
                    let top = pg.rowFrames[parent.rows]
                    cols = []
                    for c in 0...wall.cols {
                        let pc = c + off
                        if pc >= 0 && pc <= parent.cols { cols.append(pg.colFrames[pc] * top * M4.rotX(a.angle)) }
                        else if c > 0 { cols.append(cols[c - 1] * M4.translate(size.w, 0, 0) * M4.rotY(-(wall.colAngles[safe: c - 1] ?? 0))) }
                        else { cols.append(pg.colFrames[0] * top * M4.rotX(a.angle) * M4.translate(Double(off) * size.w, 0, 0)) }
                    }
                case .left:
                    let target = pg.colFrames[0] * M4.translate(0, a.offset, 0) * M4.rotY(a.angle)
                    let b = target * cw[wall.cols].inverse
                    cols = cw.map { b * $0 }
                case .right:
                    let b = pg.colFrames[parent.cols] * M4.translate(0, a.offset, 0) * M4.rotY(-a.angle)
                    cols = cw.map { b * $0 }
                }
            } else {
                let b = base(wall)
                cols = cw.map { b * $0 }
            }
            let g = WallGeometry(size: size, colFrames: cols, rowFrames: rw)
            out[wall.id] = g
            return g
        }
        for w in project.walls { build(w) }
        return out
    }

    /// Top-down polyline of the wall's bottom edge in its own frame (x, z).
    public static func plan(_ wall: Wall, _ spec: PanelSpec) -> [SIMD2<Double>] {
        colWalk(wall, spec.size.w).map { SIMD2($0.origin.x, $0.origin.z) }
    }
    /// Side polyline of the wall's left edge in its own frame (z, y).
    public static func section(_ wall: Wall, _ spec: PanelSpec) -> [SIMD2<Double>] {
        rowWalk(wall, spec.size.h).map { SIMD2($0.origin.z, $0.origin.y) }
    }

    public static func angle(forRadius r: Double, panelWidth w: Double) -> Double { 2 * asin(min(1, w / (2 * r))) * 180 / .pi }
    public static func radius(forAngle a: Double, panelWidth w: Double) -> Double { a == 0 ? .infinity : w / (2 * sin(abs(a) * .pi / 360)) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
