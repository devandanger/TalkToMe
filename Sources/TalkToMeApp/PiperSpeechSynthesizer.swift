import AVFoundation
import Foundation

struct PiperVoiceModel: Identifiable, Hashable {
    let id: String
    let name: String
    let languageCode: String
    let languageName: String
    let quality: String
    let modelURL: URL
    let configURL: URL

    var displayName: String {
        "\(languageName) - \(name) (\(languageCode), \(quality))"
    }
}

@MainActor
final class PiperSpeechSynthesizer: NSObject, AVAudioPlayerDelegate {
    private static let selectedModelDefaultsKey = "TalkToMe.SelectedPiperModelID"

    private var player: AVAudioPlayer?
    var availableModels: [PiperVoiceModel] = []
    var selectedModelID: String? {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: Self.selectedModelDefaultsKey)
        }
    }
    var onFinished: (() -> Void)?
    var diagnosticsCenter: AppDiagnosticsController?

    override init() {
        selectedModelID = UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey)
        super.init()
        refreshModels()
    }

    func speak(_ text: String) async throws {
        let wavURL = try await synthesize(text)
        let player = try AVAudioPlayer(contentsOf: wavURL)
        self.player = player
        player.delegate = self
        player.prepareToPlay()
        player.play()
        diagnosticsCenter?.log("Playing Piper WAV: \(wavURL.lastPathComponent).", source: "Piper TTS")
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: piperExecutableURL?.path ?? "")
            && selectedModel != nil
    }

    func diagnostics() -> String {
        let binary = piperExecutableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        let selected = selectedModel?.displayName ?? "none"
        let languages = availableModels.map(\.languageCode).joined(separator: ", ")
        return "Piper binary: \(binary ? "found" : "missing"). Models: \(availableModels.count). Selected: \(selected). Languages: \(languages.isEmpty ? "none" : languages)."
    }

    func refreshModels() {
        #if os(macOS)
        availableModels = discoverModels()
        if let selectedModelID, availableModels.contains(where: { $0.id == selectedModelID }) {
            return
        }
        selectedModelID = availableModels.first(where: { $0.languageCode == "sl_SI" })?.id ?? availableModels.first?.id
        #else
        availableModels = []
        selectedModelID = nil
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.onFinished?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            if let error {
                self.diagnosticsCenter?.log(error, source: "Piper TTS")
            }
            self.player = nil
            self.onFinished?()
        }
    }

    private func synthesize(_ text: String) async throws -> URL {
        #if os(macOS)
        guard let piperExecutableURL, let selectedModel, let espeakDataURL, let libraryURL else {
            throw PiperSpeechError.resourcesMissing
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkToMe-Piper-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let process = Process()
        process.executableURL = piperExecutableURL
        process.arguments = [
            "--model", selectedModel.modelURL.path,
            "--config", selectedModel.configURL.path,
            "--output_file", outputURL.path,
        ]
        process.currentDirectoryURL = piperExecutableURL.deletingLastPathComponent()
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DYLD_LIBRARY_PATH": libraryURL.path,
            "ESPEAK_DATA_PATH": espeakDataURL.path,
        ]) { _, new in new }

        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(text.utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown Piper error."
            throw PiperSpeechError.synthesisFailed(errorText)
        }

        diagnosticsCenter?.log("Synthesized Piper audio for \(text.count) characters.", source: "Piper TTS")
        return outputURL
        #else
        throw PiperSpeechError.resourcesMissing
        #endif
    }

    private var selectedModel: PiperVoiceModel? {
        availableModels.first { $0.id == selectedModelID } ?? availableModels.first
    }

    private var piperExecutableURL: URL? {
        Bundle.main.url(forResource: "piper", withExtension: nil, subdirectory: "Piper/bin")
    }

    private var espeakDataURL: URL? {
        Bundle.main.url(forResource: "espeak-ng-data", withExtension: nil, subdirectory: "Piper/bin")
    }

    private var libraryURL: URL? {
        Bundle.main.url(forResource: "lib", withExtension: nil, subdirectory: "Piper/bin")
    }

    private func discoverModels() -> [PiperVoiceModel] {
        guard let voicesURL = Bundle.main.url(forResource: "voices", withExtension: nil, subdirectory: "Piper"),
              let voiceDirectories = try? FileManager.default.contentsOfDirectory(
                at: voicesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        return voiceDirectories.compactMap { directoryURL in
            guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let modelURL = try? FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ).first(where: { $0.pathExtension == "onnx" })
            else {
                return nil
            }

            let configURL = directoryURL.appendingPathComponent("\(modelURL.lastPathComponent).json")
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                return nil
            }

            let metadata = Self.readMetadata(from: configURL)
            return PiperVoiceModel(
                id: directoryURL.lastPathComponent,
                name: metadata.dataset ?? directoryURL.lastPathComponent,
                languageCode: metadata.languageCode ?? "unknown",
                languageName: metadata.languageName ?? "Unknown",
                quality: metadata.quality ?? "unknown",
                modelURL: modelURL,
                configURL: configURL
            )
        }
        .sorted { lhs, rhs in
            if lhs.languageCode == rhs.languageCode {
                return lhs.name < rhs.name
            }
            return lhs.languageCode < rhs.languageCode
        }
    }

    private static func readMetadata(from configURL: URL) -> (dataset: String?, languageCode: String?, languageName: String?, quality: String?) {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, nil, nil, nil)
        }

        let audio = root["audio"] as? [String: Any]
        let language = root["language"] as? [String: Any]
        return (
            root["dataset"] as? String,
            language?["code"] as? String,
            language?["name_english"] as? String,
            audio?["quality"] as? String
        )
    }
}

enum PiperSpeechError: LocalizedError {
    case resourcesMissing
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            return "Piper resources are missing from the app bundle."
        case .synthesisFailed(let details):
            return "Piper synthesis failed: \(details)"
        }
    }
}
