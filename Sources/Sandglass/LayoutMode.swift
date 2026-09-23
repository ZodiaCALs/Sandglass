import SwiftUI

/// Where the filmstrip sits relative to the photo.
enum LayoutMode: String, CaseIterable, Identifiable {
    case filmstripLeft
    case filmstripRight
    case photoOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .filmstripLeft: return "Left"
        case .filmstripRight: return "Right"
        case .photoOnly: return "Photo only"
        }
    }

    var systemImage: String {
        switch self {
        case .filmstripLeft: return "rectangle.lefthalf.inset.filled"
        case .filmstripRight: return "rectangle.righthalf.inset.filled"
        case .photoOnly: return "rectangle.inset.filled"
        }
    }

    var help: String {
        switch self {
        case .filmstripLeft: return "Filmstrip on the left"
        case .filmstripRight: return "Filmstrip on the right"
        case .photoOnly: return "Hide the filmstrip — just the photo"
        }
    }

    var showsFilmstrip: Bool { self != .photoOnly }
}
