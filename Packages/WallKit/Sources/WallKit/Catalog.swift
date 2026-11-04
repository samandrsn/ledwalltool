import Foundation

// Device catalogs. Spec values are typical published figures — verify against current
// manufacturer spec sheets before deployment. Everything is editable per project.

public struct PanelSpec: Codable, Hashable, Sendable {
    public var mfr: String
    public var name: String
    public var pxW: Int
    public var pxH: Int
    public var mmW: Double
    public var mmH: Double
    public var mmD: Double
    public var kg: Double
    public var wMax: Double
    public var wAvg: Double
    /// 0 = no limit beyond pixel capacity.
    public var maxPerPort: Int = 0
    /// Max panels on one powerCON/TRUE1 daisy chain; 0 = no limit.
    public var maxPerPowerLink: Int = 0
}

public enum PanelLibrary {
    public static let all: [PanelSpec] = [
        PanelSpec(mfr: "Unilumin", name: "UPAD IV 2.6 (500×500)", pxW: 192, pxH: 192, mmW: 500, mmH: 500, mmD: 79, kg: 7.5, wMax: 160, wAvg: 55),
        PanelSpec(mfr: "Unilumin", name: "UPAD IV 2.6 (500×1000)", pxW: 192, pxH: 384, mmW: 500, mmH: 1000, mmD: 79, kg: 13.5, wMax: 320, wAvg: 110),
        PanelSpec(mfr: "Absen", name: "Polaris PL3.9 XL (500×1000)", pxW: 128, pxH: 256, mmW: 500, mmH: 1000, mmD: 85, kg: 12.0, wMax: 280, wAvg: 95),
        PanelSpec(mfr: "Absen", name: "A3 Pro 3.9 (500×500)", pxW: 128, pxH: 128, mmW: 500, mmH: 500, mmD: 80, kg: 7.6, wMax: 160, wAvg: 55),
        PanelSpec(mfr: "Absen", name: "A3 Pro 3.9 (500×1000)", pxW: 128, pxH: 256, mmW: 500, mmH: 1000, mmD: 80, kg: 13.0, wMax: 300, wAvg: 100),
        PanelSpec(mfr: "Revelux", name: "2.6 (500×500) — enter specs", pxW: 192, pxH: 192, mmW: 500, mmH: 500, mmD: 80, kg: 7.5, wMax: 170, wAvg: 60),
        PanelSpec(mfr: "Revelux", name: "3.9 (500×1000) — enter specs", pxW: 128, pxH: 256, mmW: 500, mmH: 1000, mmD: 85, kg: 13.0, wMax: 300, wAvg: 100),
        PanelSpec(mfr: "ROE", name: "Black Pearl BP2 V2", pxW: 176, pxH: 176, mmW: 500, mmH: 500, mmD: 77, kg: 9.35, wMax: 190, wAvg: 95),
        PanelSpec(mfr: "Generic", name: "2.6 mm (500×500)", pxW: 192, pxH: 192, mmW: 500, mmH: 500, mmD: 80, kg: 8, wMax: 180, wAvg: 60),
        PanelSpec(mfr: "Generic", name: "3.9 mm (500×500)", pxW: 128, pxH: 128, mmW: 500, mmH: 500, mmD: 80, kg: 8, wMax: 160, wAvg: 55),
    ]
}

public struct ProcessorSpec: Hashable, Sendable {
    public var vendor: String
    public var name: String
    public var maxInputW: Int
    public var maxInputH: Int
    public var maxPixels: Int
    /// Ethernet ports on the processor itself (Novastar, Tessera S-series).
    public var directPorts: Int
    /// Trunks to distribution units (Brompton SX40 → XD). 0 = no distros.
    public var trunks: Int
    public var distributorName: String
    public var portsPerDistributor: Int
    /// Pixels per 1G port at 60 Hz, 8-bit.
    public var portPixels: Int
    /// Port capacity halves above 8-bit (Novastar).
    public var halfAbove8Bit: Bool

    public var usesDistros: Bool { trunks > 0 }
    public var maxPorts: Int { usesDistros ? trunks * portsPerDistributor : directPorts }
}

public enum ProcessorModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case bromptonSX40, bromptonS8, bromptonS4
    case novaVX4S, novaVX6S, novaUHDJr, novaMX20, novaMX30, novaMX40Pro
    case custom

    public var id: String { rawValue }

    public var spec: ProcessorSpec {
        switch self {
        case .bromptonSX40: return .init(vendor: "Brompton", name: "Tessera SX40", maxInputW: 4096, maxInputH: 2160, maxPixels: 4096 * 2160, directPorts: 0, trunks: 4, distributorName: "XD", portsPerDistributor: 10, portPixels: 525_000, halfAbove8Bit: false)
        case .bromptonS8: return .init(vendor: "Brompton", name: "Tessera S8", maxInputW: 4096, maxInputH: 2160, maxPixels: 8 * 525_000, directPorts: 8, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 525_000, halfAbove8Bit: false)
        case .bromptonS4: return .init(vendor: "Brompton", name: "Tessera S4", maxInputW: 2048, maxInputH: 1080, maxPixels: 4 * 525_000, directPorts: 4, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 525_000, halfAbove8Bit: false)
        case .novaVX4S: return .init(vendor: "Novastar", name: "VX4S", maxInputW: 3840, maxInputH: 1920, maxPixels: 2_300_000, directPorts: 4, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 650_000, halfAbove8Bit: true)
        case .novaVX6S: return .init(vendor: "Novastar", name: "VX6s", maxInputW: 10240, maxInputH: 8192, maxPixels: 3_900_000, directPorts: 6, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 650_000, halfAbove8Bit: true)
        case .novaUHDJr: return .init(vendor: "Novastar", name: "NovaPro UHD Jr", maxInputW: 4096, maxInputH: 2160, maxPixels: 10_400_000, directPorts: 16, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 650_000, halfAbove8Bit: true)
        case .novaMX20: return .init(vendor: "Novastar", name: "COEX MX20", maxInputW: 4096, maxInputH: 2160, maxPixels: 3_900_000, directPorts: 6, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 650_000, halfAbove8Bit: true)
        case .novaMX30: return .init(vendor: "Novastar", name: "COEX MX30", maxInputW: 4096, maxInputH: 2160, maxPixels: 6_500_000, directPorts: 10, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 650_000, halfAbove8Bit: true)
        case .novaMX40Pro: return .init(vendor: "Novastar", name: "COEX MX40 Pro", maxInputW: 4096, maxInputH: 2160, maxPixels: 9_000_000, directPorts: 20, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 650_000, halfAbove8Bit: true)
        case .custom: return .init(vendor: "Custom", name: "Custom processor", maxInputW: 3840, maxInputH: 2160, maxPixels: 8_294_400, directPorts: 8, trunks: 0, distributorName: "", portsPerDistributor: 0, portPixels: 650_000, halfAbove8Bit: false)
        }
    }
}

public enum CircuitVoltage: String, Codable, CaseIterable, Identifiable, Sendable {
    case v120 = "120", v208 = "208", v230 = "230", v240 = "240"
    public var id: String { rawValue }
    public var volts: Double { Double(rawValue)! }
    public var label: String {
        switch self {
        case .v120: return "120 V 1Φ"
        case .v208: return "208 V 1Φ (L-L)"
        case .v230: return "230 V 1Φ"
        case .v240: return "240 V 1Φ"
        }
    }
}

/// Common curve-block / hinge angles in degrees. Positive = concave.
public let anglePresets: [Double] = [-15, -10, -7.5, -5, -2.5, 0, 2.5, 5, 7.5, 10, 15, 90, -90]

public let resolutionPresets: [(Int, Int)] = [(1920, 1080), (2048, 1080), (2560, 1440), (3840, 2160), (4096, 2160)]

public let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 72, 90, 100, 119.88, 120, 144, 240]
