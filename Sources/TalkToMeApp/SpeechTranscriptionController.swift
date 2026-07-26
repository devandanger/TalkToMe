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
    var isRecording = false
    var isPreparing = false
    var audioInputDevices: [AudioInputDevice] = []
    var selectedAudioInputID: String?
    @ObservationIgnored var onTranscriptFinalized: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()

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
            return
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            diagnostics = "No SpeechTranscriber locale for \(Locale.current.identifier)."
            return
        }

        diagnostics = "SpeechTranscriber locale: \(locale.identifier)."
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
            try await requestPermissions()
            status = "Selecting microphone..."
            await refreshAudioInputs()
            try applySelectedAudioInput()

            status = "Configuring SpeechAnalyzer..."
            guard SpeechTranscriber.isAvailable else {
                throw TalkToMeError.speechTranscriberUnavailable
            }
            let currentLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            let fallbackLocale = currentLocale == nil
                ? await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
                : nil
            guard let locale = currentLocale ?? fallbackLocale else {
                throw TalkToMeError.speechLocaleUnavailable(Locale.current.identifier)
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
                    }
                }
            }

            status = "Starting microphone..."
            try startAudioEngine(inputFormat: inputFormat)
            isRecording = true
            status = "Recording speech..."
            diagnostics = "SpeechAnalyzer + SpeechDetector active with \(selectedAudioInputName), \(locale.identifier), \(Self.describe(analyzerFormat))."
        } catch {
            status = "Could not start"
            diagnostics = error.localizedDescription
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
            endOfSpeechTask?.cancel()
            return
        }

        guard didDetectSpeech, isRecording else { return }
        status = "Speech pause detected..."
        diagnostics = "SpeechDetector reports a pause; finalizing if speech does not resume."
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
    case speechLocaleUnavailable(String)
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
        case .speechLocaleUnavailable(let identifier):
            return "SpeechTranscriber has no supported locale matching \(identifier) or en-US."
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
