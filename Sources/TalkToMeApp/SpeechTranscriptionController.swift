@preconcurrency import AVFoundation
import Foundation
import Observation

#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

#if canImport(Speech)
import Speech
#endif

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

@Observable
@MainActor
final class SpeechTranscriptionController {
    var transcript = ""
    var status = "Idle"
    var diagnostics = "Checking SpeechAnalyzer..."
    var analyzerDiagnostics = "Checking SpeechAnalyzer..."
    var transcriberSupportedLocalesDiagnostics = "Checking supported locales..."
    var transcriberAvailableLocalesDiagnostics = "Checking installed locales..."
    var detectorDiagnostics = "Checking SpeechDetector..."
    var isRecording = false
    var isPreparing = false
    var audioInputDevices: [AudioInputDevice] = []
    var inputLanguage: ConversationLanguage = .slovenian {
        didSet {
            guard inputLanguage != oldValue else { return }
            persistInputLanguage(inputLanguage)
        }
    }
    var selectedAudioInputID: String? {
        didSet {
            guard selectedAudioInputID != oldValue else { return }
            persistSelectedAudioInputID(selectedAudioInputID)
        }
    }
    @ObservationIgnored var onTranscriptFinalized: ((String) -> Void)?
    @ObservationIgnored var diagnosticsCenter: AppDiagnosticsController?

    private let selectedAudioInputDefaultsKey = "selectedAudioInputID"
    private let inputLanguageDefaultsKey = "inputLanguage"
    private let audioEngine = AVAudioEngine()

    init() {
        selectedAudioInputID = UserDefaults.standard.string(forKey: selectedAudioInputDefaultsKey)
        if let rawInputLanguage = UserDefaults.standard.string(forKey: inputLanguageDefaultsKey),
           let savedInputLanguage = ConversationLanguage(rawValue: rawInputLanguage) {
            inputLanguage = savedInputLanguage
        }
    }

    #if canImport(Speech)
    @available(iOS 26.0, macOS 26.0, *)
    private var transcriber: SpeechTranscriber?
    @available(iOS 26.0, macOS 26.0, *)
    private var speechDetector: SpeechDetector?
    @available(iOS 26.0, macOS 26.0, *)
    private var analyzer: SpeechAnalyzer?
    @available(iOS 26.0, macOS 26.0, *)
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var audioConverter: AVAudioConverter?
    private var analyzerAudioFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var endOfSpeechTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var didDetectSpeech = false
    private var currentTurnTranscript = ""
    private let endOfSpeechDelayNanoseconds: UInt64 = 1_500_000_000
    #endif

    func prepare() async {
        await refreshAudioInputs()

        #if canImport(Speech)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            diagnostics = "Requires iOS 26.0 or macOS 26.0."
            analyzerDiagnostics = diagnostics
            transcriberSupportedLocalesDiagnostics = diagnostics
            transcriberAvailableLocalesDiagnostics = diagnostics
            detectorDiagnostics = diagnostics
            return
        }

        await refreshSpeechFrameworkDiagnostics()

        let supportedLocales = await speechSupportedLocales()
        guard let locale = await supportedSpeechLocale(for: inputLanguage, supportedLocales: supportedLocales) else {
            diagnostics = "Speech input \(inputLanguage.label) is not supported. Available: \(Self.describe(supportedLocales))"
            diagnosticsCenter?.log(diagnostics, level: .warning, source: "SpeechAnalyzer")
            return
        }

        diagnostics = "Speech input \(inputLanguage.label): using \(locale.identifier). Available: \(Self.describe(supportedLocales))"
        diagnosticsCenter?.log(diagnostics, source: "SpeechAnalyzer")
        #else
        diagnostics = "Speech framework is unavailable in this SDK."
        #endif
    }

    func refreshAudioInputs() async {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            let inputs = session.availableInputs ?? []
            audioInputDevices = inputs.map { AudioInputDevice(id: $0.uid, name: $0.portName) }
            if selectedAudioInputID == nil || !audioInputDevices.contains(where: { $0.id == selectedAudioInputID }) {
                selectedAudioInputID = session.preferredInput?.uid ?? inputs.first?.uid
            }
        } catch {
            diagnostics = "Could not list iOS audio inputs: \(error.localizedDescription)"
            diagnosticsCenter?.log(error, source: "Audio Input")
        }
        #elseif os(macOS)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discoverySession.devices
        audioInputDevices = devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
        if selectedAudioInputID == nil || !audioInputDevices.contains(where: { $0.id == selectedAudioInputID }) {
            selectedAudioInputID = devices.first?.uniqueID
        }
        #else
        audioInputDevices = []
        selectedAudioInputID = nil
        #endif
    }

    private func persistSelectedAudioInputID(_ inputID: String?) {
        if let inputID {
            UserDefaults.standard.set(inputID, forKey: selectedAudioInputDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedAudioInputDefaultsKey)
        }
    }

    private func persistInputLanguage(_ language: ConversationLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: inputLanguageDefaultsKey)
    }

    func startRecording() async {
        guard !isRecording else { return }
        isPreparing = true
        status = "Preparing microphone..."
        defer { isPreparing = false }

        #if canImport(Speech)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            status = "Unsupported OS"
            return
        }

        do {
            status = "Requesting permissions..."
            diagnosticsCenter?.log("Requesting microphone and speech permissions.", source: "SpeechAnalyzer")
            try await requestPermissions()
            status = "Selecting microphone..."
            await refreshAudioInputs()
            try applySelectedAudioInput()
            diagnosticsCenter?.log("Selected microphone: \(selectedAudioInputName).", source: "Audio Input")

            status = "Configuring SpeechAnalyzer..."
            guard SpeechTranscriber.isAvailable else {
                throw TalkToMeError.speechTranscriberUnavailable
            }
            let supportedLocales = await speechSupportedLocales()
            guard let locale = await supportedSpeechLocale(for: inputLanguage, supportedLocales: supportedLocales) else {
                throw TalkToMeError.speechLocaleUnavailable(inputLanguage.label, Self.describe(supportedLocales))
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let detector = SpeechDetector(
                detectionOptions: .init(sensitivityLevel: .high),
                reportResults: true
            )
            self.transcriber = transcriber
            self.speechDetector = detector
            didDetectSpeech = false
            currentTurnTranscript = ""

            let modules: [any SpeechModule] = [detector, transcriber]
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                status = "Installing speech model..."
                diagnosticsCenter?.log("Installing speech assets for input language \(inputLanguage.label).", source: "SpeechAnalyzer")
                try await request.downloadAndInstall()
            }

            let analyzer = SpeechAnalyzer(modules: modules)
            self.analyzer = analyzer
            let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
            let analyzerFormat = await Self.analyzerFormat(for: modules, inputFormat: inputFormat)
            analyzerAudioFormat = analyzerFormat
            audioConverter = Self.formatsMatch(inputFormat, analyzerFormat) ? nil : AVAudioConverter(from: inputFormat, to: analyzerFormat)
            status = "Preparing speech analysis..."
            try await analyzer.prepareToAnalyze(in: analyzerFormat)

            let stream = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputContinuation = stream.continuation

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        await MainActor.run {
                            self?.currentTurnTranscript = text
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self?.didDetectSpeech = true
                                self?.status = "Speech detected..."
                                self?.diagnostics = "Transcript activity detected; waiting for end of speech."
                                self?.scheduleEndOfSpeechTimeout()
                            } else {
                                self?.status = "Listening for speech..."
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        self?.status = "Transcription failed"
                        self?.diagnostics = error.localizedDescription
                        self?.diagnosticsCenter?.log(error, source: "SpeechTranscriber")
                    }
                }
            }

            detectorTask = Task { [weak self] in
                do {
                    for try await result in detector.results {
                        await MainActor.run {
                            self?.handleSpeechDetectionResult(result)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self?.diagnostics = "SpeechDetector failed: \(error.localizedDescription)"
                        self?.diagnosticsCenter?.log(error, source: "SpeechDetector")
                    }
                }
            }

            analysisTask = Task { [weak self] in
                do {
                    let lastSampleTime = try await analyzer.analyzeSequence(stream.stream)
                    if let lastSampleTime {
                        try await analyzer.finalizeAndFinish(through: lastSampleTime)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                } catch {
                    await MainActor.run {
                        self?.status = "Analysis failed"
                        self?.diagnostics = error.localizedDescription
                        self?.diagnosticsCenter?.log(error, source: "SpeechAnalyzer")
                    }
                }
            }

            status = "Starting microphone..."
            try startAudioEngine(inputFormat: inputFormat)
            isRecording = true
            status = "Recording speech..."
            diagnostics = "SpeechAnalyzer + SpeechDetector active with \(selectedAudioInputName), input \(locale.identifier), \(Self.describe(analyzerFormat))."
            diagnosticsCenter?.log(diagnostics, source: "SpeechAnalyzer")
        } catch {
            status = "Could not start"
            diagnostics = error.localizedDescription
            diagnosticsCenter?.log(error, source: "SpeechAnalyzer")
            await cleanUpRecordingSession(cancelDetectorTask: true)
        }
        #else
        status = "Unsupported SDK"
        diagnostics = "Build with Xcode 26 or newer to enable SpeechAnalyzer."
        #endif
    }

    private var selectedAudioInputName: String {
        audioInputDevices.first(where: { $0.id == selectedAudioInputID })?.name ?? "default input"
    }

    #if canImport(Speech)
    @available(iOS 26.0, macOS 26.0, *)
    private func speechSupportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func refreshSpeechFrameworkDiagnostics() async {
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let installedLocales = await SpeechTranscriber.installedLocales
        transcriberSupportedLocalesDiagnostics = Self.describe(supportedLocales)
        transcriberAvailableLocalesDiagnostics = Self.describe(installedLocales)

        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .high),
            reportResults: true
        )
        let detectorFormats = detector.availableCompatibleAudioFormats
        let detectorStatus = await AssetInventory.status(forModules: [detector])
        detectorDiagnostics = "Assets: \(Self.describe(detectorStatus)). Formats: \(Self.describe(detectorFormats))"

        if let locale = await supportedSpeechLocale(for: inputLanguage, supportedLocales: supportedLocales) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let modules: [any SpeechModule] = [detector, transcriber]
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
            let transcriberStatus = await AssetInventory.status(forModules: [transcriber])
            analyzerDiagnostics = "Best format: \(analyzerFormat.map(Self.describe) ?? "none"). Modules: SpeechDetector, SpeechTranscriber(\(locale.identifier))."
            transcriberAvailableLocalesDiagnostics += ". Selected assets: \(Self.describe(transcriberStatus))."
        } else {
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [detector])
            analyzerDiagnostics = "Best detector-only format: \(analyzerFormat.map(Self.describe) ?? "none"). No compatible SpeechTranscriber locale for \(inputLanguage.label)."
        }
    }

    private func supportedSpeechLocale(for language: ConversationLanguage, supportedLocales: [Locale]) async -> Locale? {
        if let localeIdentifier = language.localeIdentifier {
            let requestedLocale = Locale(identifier: localeIdentifier)
            return await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
                ?? Self.bestLocaleMatch(for: requestedLocale, in: supportedLocales)
        }

        let currentLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Self.bestLocaleMatch(for: Locale.current, in: supportedLocales)
        if let currentLocale {
            return currentLocale
        }
        let englishLocale = Locale(identifier: "en-US")
        return await SpeechTranscriber.supportedLocale(equivalentTo: englishLocale)
            ?? Self.bestLocaleMatch(for: englishLocale, in: supportedLocales)
    }

    private static func bestLocaleMatch(for requestedLocale: Locale, in supportedLocales: [Locale]) -> Locale? {
        if let exactMatch = supportedLocales.first(where: { $0.identifier == requestedLocale.identifier }) {
            return exactMatch
        }

        guard let requestedLanguage = requestedLocale.language.languageCode?.identifier else {
            return nil
        }

        return supportedLocales.first {
            $0.language.languageCode?.identifier == requestedLanguage
        }
    }

    private static func describe(_ locales: [Locale]) -> String {
        let identifiers = locales.map(\.identifier).sorted()
        return identifiers.isEmpty ? "none" : identifiers.joined(separator: ", ")
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func describe(_ status: AssetInventory.Status) -> String {
        switch status {
        case .unsupported:
            return "unsupported"
        case .supported:
            return "supported"
        case .downloading:
            return "downloading"
        case .installed:
            return "installed"
        @unknown default:
            return "unknown"
        }
    }

    private static func describe(_ formats: [AVAudioFormat]) -> String {
        guard !formats.isEmpty else { return "none" }
        return formats.map(Self.describe).joined(separator: "; ")
    }
    #endif

    func stopRecording() async {
        guard isRecording || isPreparing else { return }
        status = "Finalizing..."

        await cleanUpRecordingSession(cancelDetectorTask: true)

        status = "Idle"
    }

    private func autoStopAfterSpeechEnded() async {
        guard isRecording else { return }
        status = "Speech ended. Finalizing transcript..."
        await cleanUpRecordingSession(cancelDetectorTask: false)
        let finalizedTranscript = currentTurnTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = finalizedTranscript
        status = finalizedTranscript.isEmpty ? "No transcript captured" : "Transcript ready"
        if !finalizedTranscript.isEmpty {
            diagnosticsCenter?.log("Final transcript: \(finalizedTranscript)", source: "SpeechAnalyzer")
            onTranscriptFinalized?(finalizedTranscript)
        }
    }

    private func cleanUpRecordingSession(cancelDetectorTask: Bool) async {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false

        #if canImport(Speech)
        if #available(iOS 26.0, macOS 26.0, *) {
            inputContinuation?.finish()
            inputContinuation = nil
            await analysisTask?.value
            resultsTask?.cancel()
            endOfSpeechTask?.cancel()
            if cancelDetectorTask {
                detectorTask?.cancel()
            }
            resultsTask = nil
            detectorTask = nil
            endOfSpeechTask = nil
            analysisTask = nil
            analyzer = nil
            speechDetector = nil
            transcriber = nil
            audioConverter = nil
            analyzerAudioFormat = nil
            didDetectSpeech = false
        }
        #endif
    }

    #if canImport(Speech)
    @available(iOS 26.0, macOS 26.0, *)
    private func handleSpeechDetectionResult(_ result: SpeechDetector.Result) {
        if result.speechDetected {
            didDetectSpeech = true
            status = "Speech detected..."
            diagnostics = "SpeechDetector reports active speech."
            diagnosticsCenter?.log("SpeechDetector reports active speech.", source: "SpeechDetector")
            endOfSpeechTask?.cancel()
            return
        }

        guard didDetectSpeech, isRecording else { return }
        status = "Speech pause detected..."
        diagnostics = "SpeechDetector reports a pause; finalizing if speech does not resume."
        diagnosticsCenter?.log(diagnostics, source: "SpeechDetector")
        scheduleEndOfSpeechTimeout()
    }

    private func scheduleEndOfSpeechTimeout() {
        guard isRecording, didDetectSpeech else { return }
        endOfSpeechTask?.cancel()
        endOfSpeechTask = Task { [weak self, endOfSpeechDelayNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: endOfSpeechDelayNanoseconds)
                await self?.autoStopAfterSpeechEnded()
            } catch {
                // Superseded by newer detector or transcript activity.
            }
        }
    }
    #endif

    #if canImport(Speech)
    @available(iOS 26.0, macOS 26.0, *)
    private func startAudioEngine(inputFormat: AVAudioFormat) throws {
        let inputNode = audioEngine.inputNode

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                guard let self, let inputContinuation else { return }
                do {
                    let analyzerBuffer = try makeAnalyzerBuffer(from: buffer)
                    inputContinuation.yield(AnalyzerInput(buffer: analyzerBuffer))
                } catch {
                    diagnostics = "Audio conversion failed: \(error.localizedDescription)"
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func applySelectedAudioInput() throws {
        guard let selectedAudioInputID else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == selectedAudioInputID }) else {
            throw TalkToMeError.audioInputUnavailable(selectedAudioInputName)
        }
        try session.setPreferredInput(port)
        #elseif os(macOS)
        guard let audioUnit = audioEngine.inputNode.audioUnit else {
            throw TalkToMeError.audioInputUnavailable(selectedAudioInputName)
        }
        var deviceID = try Self.coreAudioDeviceID(forUID: selectedAudioInputID)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw TalkToMeError.audioUnitDeviceSelectionFailed(status)
        }
        #endif
    }

    #if os(macOS)
    private static func coreAudioDeviceID(forUID uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var qualifier = uid as CFString

        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(qualifierPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(deviceIDPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)

                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &translationSize,
                    &translation
                )
            }
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw TalkToMeError.audioUnitDeviceSelectionFailed(status)
        }
        return deviceID
    }
    #endif

    @available(iOS 26.0, macOS 26.0, *)
    private static func analyzerFormat(for modules: [any SpeechModule], inputFormat: AVAudioFormat) async -> AVAudioFormat {
        let suggestedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: inputFormat
        ) ?? inputFormat

        if suggestedFormat.commonFormat == .pcmFormatInt16 {
            return suggestedFormat
        }

        return AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: suggestedFormat.sampleRate,
            channels: max(suggestedFormat.channelCount, 1),
            interleaved: false
        ) ?? suggestedFormat
    }

    private func makeAnalyzerBuffer(from inputBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let analyzerAudioFormat, !Self.formatsMatch(inputBuffer.format, analyzerAudioFormat) else {
            return inputBuffer
        }
        guard let audioConverter else {
            throw TalkToMeError.audioConversionUnavailable
        }

        let sampleRateRatio = analyzerAudioFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * sampleRateRatio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerAudioFormat, frameCapacity: outputCapacity) else {
            throw TalkToMeError.audioBufferAllocationFailed
        }

        let inputProvider = AudioConverterInputProvider(buffer: inputBuffer)
        let inputBlock: AVAudioConverterInputBlock = { @Sendable packetCount, outStatus in
            inputProvider.provideInput(packetCount: packetCount, outStatus: outStatus)
        }
        var conversionError: NSError?
        let status = audioConverter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw TalkToMeError.audioConversionUnavailable
        }

        return outputBuffer
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let sampleRate = Int(format.sampleRate.rounded())
        return "\(sampleRate) Hz, \(format.channelCount) channel(s), \(format.commonFormat)"
    }

    private func requestPermissions() async throws {
        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneGranted else { throw TalkToMeError.microphoneDenied }

        if #available(iOS 26.0, macOS 26.0, *) {
            let speechGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard speechGranted == .authorized else { throw TalkToMeError.speechDenied }
        }
    }
    #endif
}

enum TalkToMeError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case speechTranscriberUnavailable
    case speechLocaleUnavailable(String, String)
    case audioInputUnavailable(String)
    case audioUnitDeviceSelectionFailed(OSStatus)
    case audioBufferAllocationFailed
    case audioConversionUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access was denied."
        case .speechDenied:
            return "Speech recognition access was denied."
        case .speechTranscriberUnavailable:
            return "SpeechTranscriber is not available on this device."
        case .speechLocaleUnavailable(let identifier, let availableLocales):
            return "SpeechTranscriber has no supported locale matching \(identifier). Available: \(availableLocales)."
        case .audioInputUnavailable(let name):
            return "Could not use audio input: \(name)."
        case .audioUnitDeviceSelectionFailed(let status):
            return "Could not select the requested audio input. Core Audio status: \(status)."
        case .audioBufferAllocationFailed:
            return "Could not allocate an audio buffer for speech analysis."
        case .audioConversionUnavailable:
            return "Could not convert microphone audio into the format required by SpeechAnalyzer."
        }
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provideInput(
        packetCount: AVAudioPacketCount,
        outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideInput else {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
    }
}
