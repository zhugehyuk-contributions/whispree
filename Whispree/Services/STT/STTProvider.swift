import Foundation

/// STT Provider Protocol - WhisperKit과 Groq Cloud 간 전환 가능
/// @MainActor 제거: ML 추론은 백그라운드에서 실행되어야 함 (MainActor deadlock 방지)
protocol STTProvider: AnyObject, Sendable {
    var name: String { get }
    var isAvailable: Bool { get }

    func validate() -> ProviderValidation
    func setup() async throws
    func teardown() async

    func transcribe(
        audioBuffer: [Float],
        language: SupportedLanguage?,
        promptTokens: [Int]?,
        clipStartTime: Float?
    ) async throws -> TranscriptionResult

    func transcribeStream(
        audioBuffer: [Float],
        language: SupportedLanguage?,
        promptTokens: [Int]?
    ) -> AsyncStream<PartialTranscription>

    // MARK: - Live Streaming

    var isStreaming: Bool { get }

    /// `confirmedText`는 새로 확정된 텍스트이며, provisional update에서는 빈 문자열이다.
    /// `fullText`는 현재까지 조립된 전체 스트리밍 텍스트다.
    func startStreaming(
        language: SupportedLanguage?,
        onSegmentConfirmed: @escaping @MainActor @Sendable (String, String) -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) async throws

    func stopStreaming() async

    func getAccumulatedText() -> String
}

extension STTProvider {
    var isReady: Bool {
        validate().isValid
    }

    // MARK: - Live Streaming (default: unsupported)

    /// 라이브 마이크 스트리밍 전사 (WhisperKit 전용)
    var isStreaming: Bool { false }

    func startStreaming(
        language: SupportedLanguage?,
        onSegmentConfirmed: @escaping @MainActor @Sendable (String, String) -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) async throws {
        throw STTError.streamingNotSupported
    }

    func stopStreaming() async {}

    func getAccumulatedText() -> String { "" }
}

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String?
}

struct TranscriptionSegment {
    let text: String
    let language: String?
    let words: [WordInfo]?
    let start: Float?
    let end: Float?
}

/// 스트리밍 전사에서 확정된 세그먼트 — 더 이상 재전사/재교정하지 않음
struct FinalizedSegment {
    let text: String
    var correctedText: String?
    let startTime: Float
    let endTime: Float
    var displayText: String { correctedText ?? text }
}

struct WordInfo {
    let word: String
    let start: Double
    let end: Double
}

struct PartialTranscription {
    let text: String
    let isFinal: Bool
}
