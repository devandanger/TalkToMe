import SwiftUI

struct TalkToMeView: View {
    @State private var speech = SpeechTranscriptionController()
    @State private var intelligence = AppleIntelligenceController()
    @State private var speaker = SpokenResponseController()
    @State private var prompt = "Use my transcript as a quick daily check-in. Be concise, practical, and warm. Identify what seems important, suggest one next action, and ask one useful follow-up question."

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
                        Task { await toggleRecording() }
                    } label: {
                        Label(speech.isRecording ? "Stop" : "Record", systemImage: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
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

            TextField("Prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
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

    private func toggleRecording() async {
        if speech.isRecording {
            await speech.stopRecording()
        } else {
            await speech.startRecording()
        }
    }

    private func askAppleIntelligence() async {
        await speech.stopRecording()
        await intelligence.respond(to: speech.transcript, instructions: prompt)
        speaker.speak(intelligence.response)
    }

    private var transcriptPlaceholder: String {
        if speech.isPreparing {
            return "Preparing the microphone..."
        }
        if speech.isRecording {
            return "Recording speech. Start talking and your transcript will appear here."
        }
        return "Tap Record and say what happened today."
    }
}
