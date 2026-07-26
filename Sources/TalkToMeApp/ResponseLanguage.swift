import Foundation

enum ResponseLanguage: String, CaseIterable, Identifiable {
    case slovenian
    case english
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slovenian:
            return "Slovenian"
        case .english:
            return "English"
        case .system:
            return "System"
        }
    }

    var voiceLanguageCode: String? {
        switch self {
        case .slovenian:
            return "sl-SI"
        case .english:
            return "en-US"
        case .system:
            return nil
        }
    }

    var promptInstruction: String {
        switch self {
        case .slovenian:
            return "Reply in Slovenian using natural Slovenian phrasing."
        case .english:
            return "Reply in English."
        case .system:
            return "Reply in the user's current language when clear; otherwise use the system language."
        }
    }
}
