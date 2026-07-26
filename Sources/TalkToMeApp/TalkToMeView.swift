import SwiftUI

struct TalkToMeView: View {
    @State private var speech = SpeechTranscriptionController()
    @State private var intelligence = AppleIntelligenceController()
    @State private var speaker = SpokenResponseController()
    @State private var conversationHistory: [ConversationMessage] = []
    @State private var prompt = "You are a concise conversational assistant. Use the conversation history for continuity, answer the current user message naturally, and ask at most one useful follow-up question when it helps. Reply with only the assistant message, without a name or role prefix."
    @State private var conversationActive = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                transcriptPanel
                responsePanel
                diagnosticsPanel
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
                intelligence.refreshDiagnostics()
                speech.onTranscriptFinalized = { transcript in
                    Task { await respondAndSpeak(to: transcript, continueListening: true) }
                }
                speaker.onFinishedSpeaking = {
                    guard conversationActive else { return }
                    Task { await speech.startRecording() }
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
                                    .foregroundStyle(message.role == .user ? .blue : .green)
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
                Text(speech.diagnostics)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Text("Speech Output")
                    .fontWeight(.semibold)
                Text(speaker.diagnostics)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func toggleConversation() async {
        if conversationActive {
            conversationActive = false
            await speech.stopRecording()
            speaker.stop()
        } else {
            conversationActive = true
            await speech.startRecording()
        }
    }

    private func askAppleIntelligence() async {
        conversationActive = false
        await speech.stopRecording()
        await respondAndSpeak(to: speech.transcript, continueListening: false)
    }

    private func respondAndSpeak(to transcript: String, continueListening: Bool) async {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }

        let historyForPrompt = conversationHistory
        conversationHistory.append(.init(role: .user, text: trimmedTranscript))
        await intelligence.respond(to: trimmedTranscript, history: historyForPrompt, instructions: prompt)
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
}
