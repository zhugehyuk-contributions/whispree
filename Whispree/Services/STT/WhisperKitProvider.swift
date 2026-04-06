import AVFoundation
import Foundation
import WhisperKit

final class WhisperKitProvider: STTProvider, @unchecked Sendable {
    let name = "WhisperKit"
    var isAvailable: Bool {
        true
    }

    private var whisperKit: WhisperKit?
    private let modelId: String

    // MARK: - Streaming State (NSLock-protected)

    private let streamLock = NSLock()
    private var _streamTranscriber: AudioStreamTranscriber?
    private var _lastState: AudioStreamTranscriber.State?
    private var _isStreaming: Bool = false
    private static let waitingPlaceholder = "Waiting for speech..."

    var isStreaming: Bool {
        streamLock.withLock { _isStreaming }
    }

    init(modelId: String = "openai_whisper-large-v3_turbo") {
        self.modelId = modelId
    }

    func validate() -> ProviderValidation {
        whisperKit != nil ? .valid : .invalid("WhisperKit 모델이 로드되지 않았습니다. 모델을 다운로드해주세요.")
    }

    func setup() async throws {
        let config = WhisperKitConfig(
            model: modelId,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )
        whisperKit = try await WhisperKit(config)
    }

    func teardown() async {
        await stopStreaming()
        whisperKit = nil
    }

    /// 도메인 단어 세트 저장 (transcribe 시 promptTokens로 변환)
    var domainWordSets: [DomainWordSet] = []

    func transcribe(
        audioBuffer: [Float],
        language: SupportedLanguage?,
        promptTokens: [Int]?
    ) async throws -> TranscriptionResult {
        guard let whisperKit else { throw STTError.modelNotLoaded }

        // 세팅값 따라감: auto면 자동 감지, ko/en이면 해당 언어 고정
        let langCode: String? = (language == nil || language == .auto) ? nil : language!.rawValue

        var options = DecodingOptions(
            language: langCode,
            detectLanguage: langCode == nil,
            wordTimestamps: true,
            noSpeechThreshold: 0.5
        )

        // promptTokens 주입: 외부 전달 또는 domainWordSets에서 빌드
        if let promptTokens, !promptTokens.isEmpty {
            options.promptTokens = promptTokens
        } else {
            if let tokens = buildPromptTokens(from: domainWordSets) {
                options.promptTokens = tokens
            }
        }

        var results = try await whisperKit.transcribe(audioArray: audioBuffer, decodeOptions: options)

        // auto-detect 시 오감지 방어 (힌디어 등 → 한국어로 재시도)
        if langCode == nil {
            let detectedLang = results.first?.language
            let expectedLanguages: Set = ["ko", "en", "ja", "zh"]
            if let lang = detectedLang, !expectedLanguages.contains(lang) {
                var retryOptions = options
                retryOptions.language = "ko"
                retryOptions.detectLanguage = false
                results = try await whisperKit.transcribe(audioArray: audioBuffer, decodeOptions: retryOptions)
            }
        }

        let segments = results.map { result in
            TranscriptionSegment(
                text: result.text,
                language: result.language,
                words: result.allWords.map { w in
                    WordInfo(word: w.word, start: Double(w.start), end: Double(w.end))
                }
            )
        }

        return TranscriptionResult(
            text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            language: results.first?.language
        )
    }

    func transcribeStream(
        audioBuffer: [Float],
        language: SupportedLanguage?,
        promptTokens: [Int]?
    ) -> AsyncStream<PartialTranscription> {
        AsyncStream { continuation in
            Task {
                do {
                    let result = try await self.transcribe(
                        audioBuffer: audioBuffer,
                        language: language,
                        promptTokens: promptTokens
                    )
                    continuation.yield(PartialTranscription(text: result.text, isFinal: true))
                } catch {
                    // 오류 시 빈 결과
                }
                continuation.finish()
            }
        }
    }

    /// 도메인 단어 세트에서 promptTokens 빌드
    func buildPromptTokens(from wordSets: [DomainWordSet]) -> [Int]? {
        let enabledSets = wordSets.filter(\.isEnabled)
        guard !enabledSets.isEmpty else { return nil }

        let promptText = enabledSets.map { $0.buildPromptText() }.joined(separator: " ")
        guard let tokenizer = whisperKit?.tokenizer else { return nil }

        let tokens = tokenizer.encode(text: promptText)
        return Array(tokens.prefix(224)) // 224 토큰 제한
    }

    // MARK: - Live Streaming

    func startStreaming(
        language: SupportedLanguage?,
        onSegmentConfirmed: @escaping @MainActor @Sendable (String, String) -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) async throws {
        StreamLog.write("startStreaming called")
        guard let whisperKit else {
            StreamLog.write("whisperKit is nil")
            throw STTError.modelNotLoaded
        }
        guard let tokenizer = whisperKit.tokenizer else {
            StreamLog.write("tokenizer is nil")
            throw STTError.modelNotLoaded
        }
        StreamLog.write("model ready, proceeding")

        // 마이크 권한 preflight
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .denied || authStatus == .restricted {
            throw STTError.transcriptionFailed("마이크 권한이 거부되었습니다. 시스템 설정에서 허용해주세요.")
        }
        if authStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw STTError.transcriptionFailed("마이크 권한이 필요합니다.")
            }
        }

        let langCode: String? = (language == nil || language == .auto) ? nil : language!.rawValue
        let promptTokens = buildPromptTokens(from: domainWordSets)

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: {
                var opts = DecodingOptions(
                    language: langCode,
                    detectLanguage: langCode == nil,
                    wordTimestamps: true,
                    noSpeechThreshold: 0.5
                )
                // Live buffers are short and repeatedly re-decoded from the last
                // confirmed seek point. The batch defaults are too aggressive here:
                // low-confidence first tokens cause the whole window to be thrown
                // away before any segment can stabilize.
                opts.logProbThreshold = nil
                opts.firstTokenLogProbThreshold = nil
                opts.skipSpecialTokens = true
                opts.promptTokens = promptTokens
                return opts
            }(),
            requiredSegmentsForConfirmation: 1,
            useVAD: true
        ) { [weak self] oldState, newState in
            guard let self else { return }

            // 최신 상태 캐시 (getAccumulatedText에서 사용)
            self.streamLock.withLock { self._lastState = newState }

            let confirmed = self.confirmedText(from: newState)
            let previousConfirmed = self.confirmedText(from: oldState)
            let full = self.assembledStreamingText(from: newState)
            let previousFull = self.assembledStreamingText(from: oldState)

            // confirmedSegments 변경 시에만 LLM 트리거
            if confirmed != previousConfirmed {
                Task { @MainActor in
                    onSegmentConfirmed(confirmed, full)
                }
            } else if full != previousFull {
                // provisional update only
                Task { @MainActor in
                    onSegmentConfirmed("", full)
                }
            }
        }

        streamLock.withLock {
            _lastState = nil
            _streamTranscriber = transcriber
            _isStreaming = true
        }

        // startStreamTranscription은 blocking async call — realtimeLoop가 끝날 때까지 반환하지 않음
        do {
            try await transcriber.startStreamTranscription()
        } catch {
            Task { @MainActor in
                onError(error)
            }
        }
    }

    func stopStreaming() async {
        let transcriber: AudioStreamTranscriber? = streamLock.withLock {
            let t = _streamTranscriber
            _isStreaming = false
            return t
        }

        await transcriber?.stopStreamTranscription()

        streamLock.withLock {
            _streamTranscriber = nil
        }
    }

    func getAccumulatedText() -> String {
        let state: AudioStreamTranscriber.State? = streamLock.withLock { _lastState }
        guard let state else { return "" }
        return assembledStreamingText(from: state)
    }

    private func assembledStreamingText(from state: AudioStreamTranscriber.State) -> String {
        let confirmed = confirmedText(from: state)
        let liveText = sanitizedStreamingText(state.currentText)

        let provisional: String
        if !liveText.isEmpty {
            provisional = liveText
        } else {
            let unconfirmed = joinedText(from: state.unconfirmedSegments.map(\.text))
            if !unconfirmed.isEmpty {
                provisional = unconfirmed
            } else {
                provisional = sanitizedStreamingText(state.unconfirmedText.last ?? "")
            }
        }

        return [confirmed, provisional]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirmedText(from state: AudioStreamTranscriber.State) -> String {
        joinedText(from: state.confirmedSegments.map(\.text))
    }

    private func joinedText(from parts: [String]) -> String {
        parts
            .map(sanitizedStreamingText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedStreamingText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        let stripped = text
            .replacingOccurrences(of: #"<\|[^|]+?\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard stripped != Self.waitingPlaceholder else { return "" }
        return stripped
    }
}
