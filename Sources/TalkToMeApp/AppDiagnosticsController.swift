import Foundation
import Observation

struct AppDiagnosticEntry: Identifiable, Equatable {
    enum Level: String {
        case info = "Info"
        case warning = "Warning"
        case error = "Error"
    }

    let id = UUID()
    let date = Date()
    let level: Level
    let source: String
    let message: String
}

@Observable
@MainActor
final class AppDiagnosticsController {
    private(set) var entries: [AppDiagnosticEntry] = []

    func log(_ message: String, level: AppDiagnosticEntry.Level = .info, source: String) {
        entries.append(.init(level: level, source: source, message: message))
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
    }

    func log(_ error: Error, source: String) {
        log(error.localizedDescription, level: .error, source: source)
    }

    func clear() {
        entries.removeAll()
    }
}
