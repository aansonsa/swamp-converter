import Foundation

/// Paper size and margins shared by the PDF, DOCX and ODT writers.
struct DocPageSetup: Equatable, Sendable {
    var width: Double      // points
    var height: Double
    var margin: Double     // points, all four sides

    static let mmToPt = 72.0 / 25.4

    /// "a4", "letter", "a5", "legal"; "auto" = Letter in the US, Canada and Mexico, A4 elsewhere.
    static func size(named id: String) -> (width: Double, height: Double) {
        switch id.lowercased() {
        case "letter": return (612, 792)
        case "a5": return (419.5276, 595.2756)
        case "legal": return (612, 1008)
        case "auto":
            let region = Locale.current.region?.identifier ?? ""
            return ["US", "CA", "MX"].contains(region) ? (612, 792) : (595.2756, 841.8898)
        default: return (595.2756, 841.8898)
        }
    }

    init(width: Double, height: Double, margin: Double) { self.width = width; self.height = height; self.margin = margin }

    init(size id: String = "a4", marginMillimetres mm: Double = 20) {
        let s = Self.size(named: id)
        self.init(width: s.width, height: s.height, margin: max(0, mm) * Self.mmToPt)
    }

    var contentWidth: Double { max(36, width - 2 * margin) }
    var contentHeight: Double { max(36, height - 2 * margin) }
    var widthTwips: Int { Int((width * 20).rounded()) }
    var heightTwips: Int { Int((height * 20).rounded()) }
    var marginTwips: Int { Int((margin * 20).rounded()) }
    var widthCM: String { String(format: "%.3fcm", width / 72 * 2.54) }
    var heightCM: String { String(format: "%.3fcm", height / 72 * 2.54) }
    var marginCM: String { String(format: "%.3fcm", margin / 72 * 2.54) }
}
