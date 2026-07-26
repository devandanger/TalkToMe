import AVFoundation
import Foundation
import Observation

struct SpeechVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String

    var displayName: String {
        "\(name) (\(language), \(quality))"
    }
}

@Observable
@MainActor
final class SpokenResponseController: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var availableVoices: [SpeechVoiceOption] = []
    var selectedVoiceIdentifier: String?
    var isSpeaking = false
    var diagnostics = "System speech synthesis ready."
    @ObservationIgnored var onFinishedSpeaking: (() -> Void)?
    @ObservationIgnored var diagnosticsCenter: AppDiagnosticsController?

    override init() {
        super.init()
        synthesizer.delegate = self
        refreshVoices()
        preferLanguage("sl-SI")
    }

    func refreshVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        availableVoices = voices
            .sorted { lhs, rhs in
                if lhs.language == rhs.language {
                    return lhs.name < rhs.name
                }
                return lhs.language < rhs.language
            }
            .map {
                SpeechVoiceOption(
                    id: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    quality: Self.describe($0.quality)
                )
            }
        let premiumCount = voices.filter { $0.quality == .premium || $0.quality == .enhanced }.count
        diagnostics = "\(voices.count) voices installed; \(premiumCount) enhanced or premium voices."
        diagnosticsCenter?.log(diagnostics, source: "Speech Output")
    }

    func preferLanguage(_ language: String) {
        if let exactVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == language }) {
            selectedVoiceIdentifier = exactVoice.identifier
            diagnosticsCenter?.log("Selected voice \(exactVoice.name) for \(language).", source: "Speech Output")
            return
        }

        let languagePrefix = language.split(separator: "-").first.map(String.init) ?? language
        if let matchingVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix(languagePrefix) }) {
            selectedVoiceIdentifier = matchingVoice.identifier
            diagnosticsCenter?.log("Selected voice \(matchingVoice.name) for \(matchingVoice.language).", source: "Speech Output")
        }
    }

    func hasVoice(for language: String) -> Bool {
        let languagePrefix = language.split(separator: "-").first.map(String.init) ?? language
        return AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language == language || $0.language.hasPrefix(languagePrefix)
        }
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = selectedVoiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        isSpeaking = true
        diagnosticsCenter?.log("Speaking response with \(utterance.voice?.name ?? "system voice").", source: "Speech Output")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            onFinishedSpeaking?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }

    private static func describe(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default:
            return "default"
        case .enhanced:
            return "enhanced"
        case .premium:
            return "premium"
        @unknown default:
            return "unknown"
        }
    }
}
