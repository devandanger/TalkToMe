import Foundation

enum SpeechOutputEngine: String, CaseIterable, Identifiable {
    case appleSystem
    case piperLocal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleSystem:
            return "Apple System"
        case .piperLocal:
            return "Piper Local"
        }
    }
}
