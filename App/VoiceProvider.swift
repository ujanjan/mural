import Foundation

/// Which AI provider serves voice conversations and text assists. OpenAI is the default;
/// set the MURAL_VOICE_PROVIDER environment variable to "gemini" (Xcode scheme -> Run ->
/// Environment Variables, or `open --env`) to use a Google AI Studio key instead.
/// See docs/build-and-test.md.
enum VoiceProvider: String {
    case openai, gemini

    static var current: VoiceProvider {
        VoiceProvider(rawValue: ProcessInfo.processInfo.environment["MURAL_VOICE_PROVIDER"]?.lowercased() ?? "") ?? .openai
    }

    var displayName: String { self == .gemini ? "Google AI Studio (Gemini)" : "OpenAI" }
    var keyHelpURL: URL { self == .gemini ? URL(string: "https://aistudio.google.com/api-keys")! : URL(string: "https://platform.openai.com/api-keys")! }
}

/// The surface ConversationCoordinator drives, so OpenAI (WebRTC) and Gemini (WebSocket)
/// transports stay interchangeable.
@MainActor protocol LiveTransporting: AnyObject {
    var onEvent: (([String: Any]) -> Void)? { get set }
    var onLevels: ((Double, Double) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func connect(api: APIClient, instructions: String, history: [[String: Any]]) async throws
    @discardableResult func send(_ event: [String: Any]) -> Bool
    func mute(_ muted: Bool)
    func close(reason: String)
    func disconnect()
}

extension LiveTransport: LiveTransporting {}
