import AppKit
import SwiftUI
import WallKit

enum F {
    static func length(_ m: Double, _ u: UnitSystem) -> String {
        if u == .metric { return String(format: "%.2f m", m) }
        let inches = m * 39.3701
        let ft = Int(inches / 12)
        return String(format: "%d′ %.1f″", ft, inches - Double(ft) * 12)
    }
    static func weight(_ kg: Double) -> String { "\(Int((kg * 2.20462).rounded()).formatted()) lb / \(Int(kg.rounded()).formatted()) kg" }
    static func kw(_ w: Double) -> String { String(format: "%.2f kW", w / 1000) }
    static func mp(_ px: Int) -> String { String(format: "%.2f MP", Double(px) / 1e6) }
    static func amps(_ a: Double) -> String { String(format: "%.1f A", a) }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Distinct colours for runs; power circuits are offset so the two layers don't share colours.
enum RunPalette {
    static let hex = ["FF5A5F", "FFB400", "3EC300", "00A8E8", "B07CFF", "FF7AC6", "00D2B4", "FF8C42",
                      "7BDFF2", "C3F73A", "F25F5C", "FFE066", "70C1B3", "9B5DE5", "F15BB5", "00BBF9",
                      "FEE440", "00F5D4", "E76F51", "8ECAE6"]
    static func hex(_ i: Int, _ kind: WiringKind) -> String { hex[(i + (kind == .power ? 3 : 0)) % hex.count] }
    static func color(_ i: Int, _ kind: WiringKind) -> Color { Color(hex: hex(i, kind)) }
    static func ns(_ i: Int, _ kind: WiringKind) -> NSColor { NSColor(hex: hex(i, kind)) }
}

extension IssueLevel {
    var symbol: String {
        switch self { case .error: return "xmark.octagon.fill"; case .warning: return "exclamationmark.triangle.fill"; case .info: return "info.circle.fill" }
    }
    var color: Color {
        switch self { case .error: return .red; case .warning: return .orange; case .info: return .blue }
    }
}
