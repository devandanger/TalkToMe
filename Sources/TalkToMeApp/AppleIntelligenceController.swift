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
    private(set) var lastPrompt = ""
    @ObservationIgnored var diagnosticsCenter: AppDiagnosticsController?

    func refreshDiagnostics() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            diagnostics = Self.describe(model.availability, languages: model.supportedLanguages)
            diagnosticsCenter?.log(diagnostics, source: "Foundation Models")
        } else {
            diagnostics = "Requires iOS 26.0 or macOS 26.0."
        }
        #else
        diagnostics = "FoundationModels framework is unavailable in this SDK."
        #endif
    }

    func respond(to transcript: String, history: [ConversationMessage], instructions: String, responseLanguage: ConversationLanguage) async {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        let promptText = Self.promptText(for: trimmedTranscript, history: history, responseLanguage: responseLanguage)
        lastPrompt = promptText

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
                diagnosticsCenter?.log(response, level: .warning, source: "Foundation Models")
                return
            }

            do {
                diagnosticsCenter?.log("Sending prompt to Foundation Models.", source: "Foundation Models")
                let session = LanguageModelSession(
                    model: model,
                    instructions: Instructions(instructions)
                )
                let result = try await session.respond(to: Prompt(promptText))
                response = result.content
                diagnosticsCenter?.log("Received Foundation Models response.", source: "Foundation Models")
            } catch {
                response = "Foundation Models request failed: \(error.localizedDescription)"
                diagnosticsCenter?.log(error, source: "Foundation Models")
            }
        } else {
            response = "This demo needs iOS 26.0 or macOS 26.0 for Foundation Models."
        }
        #else
        response = "Build with Xcode 26 or newer to enable the FoundationModels framework."
        #endif
    }

    private static func promptText(for transcript: String, history: [ConversationMessage], responseLanguage: ConversationLanguage) -> String {
        let priorConversation = history
            .map { message in
                switch message.role {
                case .user:
                    return "User said:\n\(message.text)"
                case .assistant:
                    return "Assistant replied:\n\(message.text)"
                case .foundationRequest:
                    return ""
                }
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if priorConversation.isEmpty {
            return """
            \(responseLanguage.promptInstruction)

            Reply directly to the current user message. Do not prefix your response with a speaker name.

            Current user message:
            \(transcript)
            """
        }

        return """
        Conversation so far:
        \(priorConversation)

        \(responseLanguage.promptInstruction)

        Reply directly to the current user message. Do not prefix your response with a speaker name.

        Current user message:
        \(transcript)
        """
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func describe(_ availability: SystemLanguageModel.Availability, languages: Set<Locale.Language>) -> String {
        switch availability {
        case .available:
            let languageList = languages.map(\.minimalIdentifier).sorted().joined(separator: ", ")
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
