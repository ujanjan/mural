import Foundation
import AVFoundation

/// Gemini Live API transport: a stateful WebSocket to BidiGenerateContent with raw PCM audio,
/// translated into the same event vocabulary the OpenAI/WebRTC transport produces so
/// ConversationCoordinator needs no changes.
///
/// Audio in: 16 kHz 16-bit PCM mono (base64 `realtimeInput.audio`, mime "audio/pcm;rate=16000").
/// Audio out: 24 kHz 16-bit PCM mono (`serverContent.modelTurn` inline data).
/// Transcriptions arrive as untimed text chunks; this transport stamps them with a
/// session-relative clock so fragments keep start/end milliseconds.
@MainActor final class GeminiLiveTransport: NSObject {
    var onEvent: (([String: Any]) -> Void)?
    var onLevels: ((Double, Double) -> Void)?
    var onFailure: ((String) -> Void)?

    private static let liveModel = "models/gemini-3.1-flash-live-preview"
    private static let voiceName = "Kore"
    private static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendChain: Task<Void, Never>?
    private var pipe: AudioPipe?
    private var meterTask: Task<Void, Never>?
    private var attempt = UUID()
    private(set) var started = false
    private var closing = false
    private var startedAt = Date()
    private var sessionID = UUID().uuidString
    private var fragmentClockMS = 0

    func connect(api: APIClient, instructions: String, history: [[String: Any]]) async throws {
        disconnect()
        closing = false
        let token = UUID(); attempt = token
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw TransportError.microphone }
        guard let key = CredentialStore.geminiRead() else { throw TransportError.missingKey }
        try Task.checkCancellation()
        guard attempt == token else { throw CancellationError() }

        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        let socket = URLSession(configuration: .ephemeral).webSocketTask(with: URLRequest(url: components.url!, timeoutInterval: 20))
        self.socket = socket
        socket.resume()

        let setup: [String: Any] = ["setup": [
            "model": Self.liveModel,
            "generationConfig": ["responseModalities": ["AUDIO"], "temperature": 1.0],
            "systemInstruction": ["parts": [["text": instructions]]],
            "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": Self.voiceName]]],
            "inputAudioTranscription": [:] as [String: Any],
            "outputAudioTranscription": [:] as [String: Any],
            "sessionResumption": [:] as [String: Any]
        ]]
        try await sendRaw(setup)

        // Wait for setupComplete before declaring the session live, with a real timeout:
        // a silent server must not leave receive() blocked forever.
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { [socket] in
                while true {
                    let message = try await socket.receive()
                    if let event = Self.parse(message), event["setupComplete"] != nil { return true }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw TransportError.timeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
        guard attempt == token else { throw CancellationError() }
        started = true; startedAt = .now; fragmentClockMS = 0
        onEvent?(["type": "mural.session.created", "session": ["id": sessionID]])
        onEvent?(["type": "session.started", "session": ["id": sessionID]])
        startAudio()
        startMetering()
        receiveLoop(socket, token: token)
    }

    @discardableResult func send(_ event: [String: Any]) -> Bool {
        guard let type = event["type"] as? String, socket != nil else { return false }
        switch type {
        case "session.instructions.append", "session.thinking.append", "session.commentary.append":
            guard let content = event["content"] as? String, !content.isEmpty else { return true }
            let payload: [String: Any] = ["clientContent": ["turns": [["role": "user", "parts": [["text": content]]]], "turnComplete": true]]
            if let id = event["event_id"] as? String {
                // The OpenAI protocol acks accepted commands; keep the coordinator's bookkeeping
                // happy - but only after the write actually lands on the socket.
                let ack: [String: Any] = ["type": type.replacingOccurrences(of: ".append", with: ".appended"), "client_event_id": id]
                enqueue(payload) { [weak self] ok in
                    guard let self else { return }
                    if ok {
                        self.onEvent?(ack)
                    } else {
                        // Surface the failure through the coordinator's existing error path:
                        // drops the pending command and shows the "voice update was rejected" notice
                        // instead of letting the command time out silently.
                        self.onEvent?(["type": "error", "error": ["client_event_id": id]])
                    }
                }
            } else {
                enqueue(payload)
            }
            return true
        case "session.input_audio.mute": pipe?.setMuted(true); return true
        case "session.input_audio.unmute": pipe?.setMuted(false); return true
        case "session.close": close(); return true
        default: return true
        }
    }

    func mute(_ muted: Bool) { pipe?.setMuted(muted) }

    func close(reason: String) {
        closing = true
        let seconds = started ? Date().timeIntervalSince(startedAt) : 0
        let socket = self.socket
        self.socket = nil
        stopAudio()
        sendChain = Task {
            try? await socket?.send(.string(#"{"clientContent":{"turns":[{"role":"user","parts":[{"text":"The learner ended the conversation."}]}],"turnComplete":true}}"#))
            socket?.cancel(with: .normalClosure, reason: nil)
        }
        onEvent?(["type": "session.closed", "reason": reason, "usage": ["seconds": seconds]])
    }

    func disconnect() {
        attempt = UUID(); closing = true; started = false
        receiveTask?.cancel(); receiveTask = nil
        sendChain?.cancel(); sendChain = nil
        stopAudio()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        onLevels?(0, 0)
    }

    // MARK: WebSocket

    private func sendRaw(_ object: [String: Any]) async throws {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { throw TransportError.connection }
        try await socket.send(.string(text))
    }

    /// Serializes WebSocket writes; concurrent sends on one task can fail.
    /// onSent reports whether this write actually reached the socket.
    private func enqueue(_ object: [String: Any], onSent: (@escaping (Bool) -> Void)? = nil) {
        guard let socket else { onSent?(false); return }
        let previous = sendChain
        sendChain = Task {
            _ = await previous?.result
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else { onSent?(false); return }
            do {
                try await socket.send(.string(text))
                onSent?(true)
            } catch {
                onSent?(false)
            }
        }
    }

    private static func parse(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        guard case .string(let text) = message, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask, token: UUID) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    await self.handle(message)
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.attempt == token, !self.closing else { return }
                        self.onFailure?("The voice connection ended unexpectedly. Your conversation has been saved.")
                    }
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard let event = Self.parse(message) else { return }
        if let content = event["serverContent"] as? [String: Any] {
            if content["interrupted"] as? Bool == true { pipe?.interruptPlayback() }
            if let turn = content["modelTurn"] as? [String: Any] {
                for part in turn["parts"] as? [[String: Any]] ?? [] {
                    if let inline = part["inlineData"] as? [String: Any],
                       let mime = inline["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                       let b64 = inline["data"] as? String, let pcm = Data(base64Encoded: b64) {
                        pipe?.play(pcm)
                    }
                }
            }
            if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String { emitTranscript(text, speaker: "input") }
            if let text = (content["outputTranscription"] as? [String: Any])?["text"] as? String { emitTranscript(text, speaker: "output") }
            if content["turnComplete"] as? Bool == true { emitUsage() }
        }
        if event["usageMetadata"] != nil || event["goAway"] != nil { emitUsage() }
    }

    private func emitTranscript(_ text: String, speaker: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, started else { return }
        let start = fragmentClockMS
        let end = max(Int(Date().timeIntervalSince(startedAt) * 1000), start)
        fragmentClockMS = end
        onEvent?(["type": "session.\(speaker)_transcript.delta", "delta": clean,
                  "start_ms": start, "end_ms": end, "event_id": UUID().uuidString])
    }

    private func emitUsage() {
        guard started else { return }
        onEvent?(["type": "session.usage.updated", "usage": ["seconds": Date().timeIntervalSince(startedAt)]])
    }

    // MARK: Audio

    private func startAudio() {
        let pipe = AudioPipe { [weak self] data in
            Task { @MainActor [weak self] in self?.enqueue(["realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]) }
        }
        self.pipe = pipe
        do { try pipe.start() }
        catch { onFailure?("The microphone couldn’t be started. Check System Settings → Privacy & Security → Microphone.") }
    }

    private func stopAudio() { pipe?.stop(); pipe = nil }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.started, let pipe = self.pipe else { return }
                self.onLevels?(pipe.inputLevel, pipe.outputLevel)
                pipe.decayLevels()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    enum TransportError: LocalizedError {
        case microphone, missingKey, connection, timeout
        var errorDescription: String? {
            switch self {
            case .microphone:
                #if os(iOS)
                return "Allow microphone access in iPhone Settings → Mural to start a conversation."
                #else
                return "Allow microphone access in System Settings → Privacy & Security → Microphone → Mural to start a conversation."
                #endif
            case .missingKey: return "Add your Google AI Studio key in Settings to begin."
            case .connection: return "The voice connection couldn’t be established. Check your connection and try again."
            case .timeout: return "The voice connection took too long. Please try again."
            }
        }
    }
}

extension GeminiLiveTransport: LiveTransporting {}

/// Owns the audio engine, converters, and playback off the main actor so the real-time
/// tap callback never touches MainActor state. Levels and mute are lock-protected.
private final class AudioPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var inputConverter: AVAudioConverter?
    private var outputConverter: AVAudioConverter?
    private var muted = false
    private var inputRMS = 0.0
    private var outputRMS = 0.0
    private let sendAudio: @Sendable (Data) -> Void

    init(sendAudio: @escaping @Sendable (Data) -> Void) { self.sendAudio = sendAudio }

    var inputLevel: Double { lock.lock(); defer { lock.unlock() }; return min(1, inputRMS * 3) }
    var outputLevel: Double { lock.lock(); defer { lock.unlock() }; return min(1, outputRMS * 3) }
    func decayLevels() { lock.lock(); inputRMS *= 0.5; outputRMS *= 0.5; lock.unlock() }
    func setMuted(_ value: Bool) { lock.lock(); muted = value; lock.unlock() }

    func start() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        engine.attach(player)
        let hardwareOut = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: hardwareOut)
        let geminiOut = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
        outputConverter = AVAudioConverter(from: geminiOut, to: hardwareOut)

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true) // echo cancellation on speakers
        let hardwareIn = input.outputFormat(forBus: 0)
        let geminiIn = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        inputConverter = AVAudioConverter(from: hardwareIn, to: geminiIn)
        input.installTap(onBus: 0, bufferSize: 4_800, format: hardwareIn) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        try engine.start()
        player.play()
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        player?.stop(); engine?.stop()
        engine = nil; player = nil; inputConverter = nil; outputConverter = nil
        lock.lock(); inputRMS = 0; outputRMS = 0; muted = false; lock.unlock()
    }

    /// Real-time render thread: convert to 16 kHz PCM16 and stream upstream.
    private func capture(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum = 0.0
            let strideBy = 4
            for i in stride(from: 0, to: Int(buffer.frameLength), by: strideBy) { sum += Double(channel[i]) * Double(channel[i]) }
            let rms = (sum / Double(Int(buffer.frameLength) / strideBy + 1)).squareRoot()
            lock.lock(); inputRMS = max(inputRMS, rms); lock.unlock()
        }
        lock.lock(); let isMuted = muted; lock.unlock()
        guard !isMuted, let converter = inputConverter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, converted.frameLength > 0, let int16 = converted.int16ChannelData?[0] else { return }
        sendAudio(Data(bytes: int16, count: Int(converted.frameLength) * 2))
    }

    func play(_ pcm: Data) {
        guard let converter = outputConverter, let player, player.engine != nil else { return }
        let inFormat = converter.inputFormat
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        source.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(source.int16ChannelData![0], base, pcm.count) }
        }
        var sum = 0.0
        let samples = source.int16ChannelData![0]
        let step = 2
        for i in stride(from: 0, to: Int(frames), by: step) { let v = Double(samples[i]) / 32768.0; sum += v * v }
        let rms = (sum / Double(Int(frames) / step + 1)).squareRoot()
        lock.lock(); outputRMS = max(outputRMS, rms); lock.unlock()
        let capacity = AVAudioFrameCount(Double(frames) * converter.outputFormat.sampleRate / inFormat.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return source
        }
        if error == nil, converted.frameLength > 0 { player.scheduleBuffer(converted) }
    }

    func interruptPlayback() { player?.stop(); player?.play() }
}
