import Foundation
import Observation

#if canImport(FoundationModels)
import FoundationModels
#endif

@Observable
@MainActor
final class AppleIntelligenceController {
    var response = ""
    var diagnostics = "Checking availability..."
    var isGenerating = false

    func refreshDiagnostics() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            diagnostics = Self.describe(model.availability, languages: model.supportedLanguages)
        } else {
            diagnostics = "Requires iOS 26.0 or macOS 26.0."
        }
        #else
        diagnostics = "FoundationModels framework is unavailable in this SDK."
        #endif
    }

    func respond(to transcript: String, instructions: String) async {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }

        isGenerating = true
        response = ""
        defer {
            isGenerating = false
            refreshDiagnostics()
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                response = "Apple Intelligence is not available on this device right now. Check the diagnostics below."
                return
            }

            do {
                let session = LanguageModelSession(
                    model: model,
                    instructions: Instructions(instructions)
                )
                let result = try await session.respond(to: Prompt(trimmedTranscript))
                response = result.content
            } catch {
                response = "Foundation Models request failed: \(error.localizedDescription)"
            }
        } else {
            response = "This demo needs iOS 26.0 or macOS 26.0 for Foundation Models."
        }
        #else
        response = "Build with Xcode 26 or newer to enable the FoundationModels framework."
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func describe(_ availability: SystemLanguageModel.Availability, languages: Set<Locale.Language>) -> String {
        switch availability {
        case .available:
            let languageList = languages.map(\.minimalIdentifier).sorted().prefix(6).joined(separator: ", ")
            return "Available. Languages: \(languageList)"
        case .unavailable(.deviceNotEligible):
            return "Unavailable: this device is not Apple Intelligence eligible."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Unavailable: Apple Intelligence is disabled in Settings."
        case .unavailable(.modelNotReady):
            return "Unavailable: the on-device model is not ready or still downloading."
        case .unavailable(let reason):
            return "Unavailable: \(String(describing: reason))."
        @unknown default:
            return "Unknown Foundation Models availability."
        }
    }
    #endif
}
