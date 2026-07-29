import SwiftUI

struct TalkToMeView: View {
    @State private var speech = SpeechTranscriptionController()
    @State private var intelligence = AppleIntelligenceController()
    @State private var speaker = SpokenResponseController()
    @State private var appDiagnostics = AppDiagnosticsController()
    @State private var conversationHistory: [ConversationMessage] = []
    @State private var prompt = "You are a concise conversational assistant. Use the conversation history for continuity, answer the current user message naturally but with simple sentences, and ask at most one useful follow-up question when it helps. Reply with only the assistant message, without a name or role prefix."
    @State private var responseLanguage: ConversationLanguage = .slovenian
    @State private var conversationActive = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                transcriptPanel
                responsePanel
                appDiagnosticsPanel
            }
            .padding()
            .frame(minWidth: 560, minHeight: 620)
            .navigationTitle("TalkToMe")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        Task { await toggleConversation() }
                    } label: {
                        Label(conversationActive ? "Stop" : "Record", systemImage: conversationActive ? "stop.circle.fill" : "mic.circle.fill")
                    }
                    .disabled(speech.isPreparing)

                    Button {
                        Task { await askAppleIntelligence() }
                    } label: {
                        Label("Ask", systemImage: "sparkles")
                    }
                    .disabled(speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || intelligence.isGenerating)
                }
            }
            .task {
                speech.diagnosticsCenter = appDiagnostics
                intelligence.diagnosticsCenter = appDiagnostics
                speaker.attachDiagnosticsCenter(appDiagnostics)
                speaker.refreshPiperModels()
                intelligence.refreshDiagnostics()
                speech.onTranscriptFinalized = { transcript in
                    Task { await respondAndSpeak(to: transcript, continueListening: true) }
                }
                speaker.onFinishedSpeaking = {
                    guard conversationActive else { return }
                    Task { await speech.startRecording() }
                }
                if let voiceLanguageCode = responseLanguage.localeIdentifier {
                    speaker.preferLanguage(voiceLanguageCode)
                }
                await speech.prepare()
            }
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Voice Input", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Text(speech.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Picker("Input", selection: $speech.selectedAudioInputID) {
                    if speech.audioInputDevices.isEmpty {
                        Text("Default Input").tag(String?.none)
                    } else {
                        ForEach(speech.audioInputDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                }
                .disabled(speech.isRecording || speech.isPreparing)

                Button {
                    Task { await speech.refreshAudioInputs() }
                } label: {
                    Label("Refresh Inputs", systemImage: "arrow.clockwise")
                }
                .disabled(speech.isRecording || speech.isPreparing)
            }

            HStack {
                Picker("Input Language", selection: $speech.inputLanguage) {
                    ForEach(ConversationLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .disabled(speech.isRecording || speech.isPreparing)
                .onChange(of: speech.inputLanguage) { _, _ in
                    Task { await speech.prepare() }
                }

                Picker("Response", selection: $responseLanguage) {
                    ForEach(ConversationLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .onChange(of: responseLanguage) { _, newValue in
                    if let voiceLanguageCode = newValue.localeIdentifier {
                        speaker.preferLanguage(voiceLanguageCode)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $speech.transcript)
                    .font(.body)
                    .frame(minHeight: 170)
                    .overlay {
                        if speech.transcript.isEmpty {
                            Text(transcriptPlaceholder)
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }

                conversationHistoryPanel
            }

            TextField("Prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            speechOutputControls
        }
    }

    private var speechOutputControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Engine", selection: $speaker.outputEngine) {
                    ForEach(SpeechOutputEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }

                Picker("Voice", selection: $speaker.selectedVoiceIdentifier) {
                    if speaker.availableVoices.isEmpty {
                        Text("System Voice").tag(String?.none)
                    } else {
                        ForEach(speaker.availableVoices) { voice in
                            Text(voice.displayName).tag(Optional(voice.id))
                        }
                    }
                }
                .disabled(speaker.outputEngine == .piperLocal)

                Picker("Piper Model", selection: $speaker.selectedPiperModelID) {
                    if speaker.availablePiperModels.isEmpty {
                        Text("No Piper Models").tag(String?.none)
                    } else {
                        ForEach(speaker.availablePiperModels) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                }
                .disabled(speaker.outputEngine != .piperLocal)

                Button {
                    if speaker.outputEngine == .piperLocal {
                        speaker.refreshPiperModels()
                    } else {
                        speaker.refreshVoices()
                    }
                } label: {
                    Label("Refresh Speech Output", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var conversationHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("History", systemImage: "text.bubble")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    conversationHistory.removeAll()
                    speech.transcript = ""
                    intelligence.response = ""
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .disabled(conversationHistory.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if conversationHistory.isEmpty {
                        Text("Conversation turns will appear here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(conversationHistory) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.role.rawValue)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(color(for: message.role))
                                Text(message.text)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .frame(width: 240)
        .frame(minHeight: 170)
    }

    private var responsePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Apple Intelligence Response", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                if intelligence.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                Text(intelligence.response.isEmpty ? "The model response will appear here." : intelligence.response)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(intelligence.response.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 150)

            HStack {
                Button {
                    speaker.speak(intelligence.response)
                } label: {
                    Label("Speak", systemImage: "speaker.wave.2.fill")
                }
                .disabled(intelligence.response.isEmpty)

                Button {
                    speaker.stop()
                } label: {
                    Label("Stop Speaking", systemImage: "speaker.slash.fill")
                }
                .disabled(!speaker.isSpeaking)

                Spacer()
            }
        }
    }

    private var diagnosticsPanel: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Foundation Models")
                    .fontWeight(.semibold)
                Text(intelligence.diagnostics)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Text("SpeechAnalyzer")
                    .fontWeight(.semibold)
                Text(speech.analyzerDiagnostics)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Text("SpeechTranscriber Supported Locales")
                    .fontWeight(.semibold)
                Text(speech.transcriberSupportedLocalesDiagnostics)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Text("SpeechTranscriber Available Locales")
                    .fontWeight(.semibold)
                Text(speech.transcriberAvailableLocalesDiagnostics)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Text("SpeechDetector")
                    .fontWeight(.semibold)
                Text(speech.detectorDiagnostics)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Text("Speech Output")
                    .fontWeight(.semibold)
                Text(speaker.diagnostics)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Text("Slovenian TTS")
                    .fontWeight(.semibold)
                Text(speaker.hasVoice(for: "sl-SI") ? "Installed" : "No sl-SI voice installed")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var appDiagnosticsPanel: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Current Diagnostics", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                diagnosticsPanel
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            eventLogPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eventLogPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Event Log", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    appDiagnostics.clear()
                } label: {
                    Label("Clear Diagnostics", systemImage: "trash")
                }
                .disabled(appDiagnostics.entries.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if appDiagnostics.entries.isEmpty {
                        Text("No app diagnostics yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appDiagnostics.entries.reversed()) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.date, style: .time)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 72, alignment: .leading)
                                Text(entry.level.rawValue)
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 58, alignment: .leading)
                                Text(entry.source)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 130, alignment: .leading)
                                Text(entry.message)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140, maxHeight: 190)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func toggleConversation() async {
        if conversationActive {
            conversationActive = false
            appDiagnostics.log("Conversation stopped by user.", source: "App")
            await speech.stopRecording()
            speaker.stop()
        } else {
            conversationActive = true
            appDiagnostics.log("Conversation started by user.", source: "App")
            await speech.startRecording()
        }
    }

    private func askAppleIntelligence() async {
        conversationActive = false
        appDiagnostics.log("Manual Ask invoked.", source: "App")
        await speech.stopRecording()
        await respondAndSpeak(to: speech.transcript, continueListening: false)
    }

    private func respondAndSpeak(to transcript: String, continueListening: Bool) async {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }

        let historyForPrompt = conversationHistory
        conversationHistory.append(.init(role: .user, text: trimmedTranscript))
        appDiagnostics.log("Sending transcript to Apple Intelligence: \(trimmedTranscript)", source: "App")
        await intelligence.respond(
            to: trimmedTranscript,
            history: historyForPrompt,
            instructions: prompt,
            responseLanguage: responseLanguage
        )
        if !intelligence.lastPrompt.isEmpty {
            conversationHistory.append(.init(role: .foundationRequest, text: intelligence.lastPrompt))
        }
        if continueListening, !conversationActive {
            return
        }
        if !intelligence.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversationHistory.append(.init(role: .assistant, text: intelligence.response))
        }
        speaker.speak(intelligence.response)
    }

    private var transcriptPlaceholder: String {
        if speech.isPreparing {
            return "Preparing the microphone..."
        }
        if speech.isRecording {
            return "Listening. Your words will appear here after you finish speaking."
        }
        return "Tap Record and say what happened today."
    }

    private func color(for role: ConversationMessage.Role) -> Color {
        switch role {
        case .user:
            return .blue
        case .assistant:
            return .green
        case .foundationRequest:
            return .orange
        }
    }

    private func color(for level: AppDiagnosticEntry.Level) -> Color {
        switch level {
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
