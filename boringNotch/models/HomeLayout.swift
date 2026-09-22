import Defaults

enum HomePanel: String, CaseIterable, Identifiable {
    case media, agenda, shelf, utilities

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .media: return "play.rectangle"
        case .agenda: return "calendar"
        case .shelf: return "tray"
        case .utilities: return "slider.horizontal.3"
        }
    }
}

/// Small value-only preferences: no services or display observers are needed.
enum HomeLayout {
    static let sharedKey = "default"
    static let defaultPanels: [HomePanel] = [.media, .utilities]

    static func panels(from saved: [String]?) -> [HomePanel] {
        var panels: [HomePanel] = []
        for raw in saved ?? [] {
            if let panel = HomePanel(rawValue: raw), !panels.contains(panel) {
                panels.append(panel)
            }
        }
        for panel in defaultPanels where panels.count < 2 && !panels.contains(panel) {
            panels.append(panel)
        }
        return Array(panels.prefix(3))
    }

    static func key(screenUUID: String?, allDisplays: Bool) -> String {
        allDisplays ? (screenUUID ?? sharedKey) : sharedKey
    }
}

extension Defaults.Keys {
    static let enableHomeLayout = Key<Bool>("enableHomeLayout", default: false)
    static let homeLayouts = Key<[String: [String]]>("homeLayouts", default: [:])
}
