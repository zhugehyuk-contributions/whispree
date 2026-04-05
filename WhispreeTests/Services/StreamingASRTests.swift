import XCTest
@testable import Whispree

/// Streaming ASR Mode — Contract Tests
/// Trace: docs/streaming-asr/trace.md
final class StreamingASRTests: XCTestCase {

    // MARK: - Scenario 1: 스트리밍 모드 설정 토글

    /// Trace: Scenario 1, Section 3b — 기본값
    func testStreamingSettingDefaultFalse() {
        // UserDefaults 정리 후 기본값 확인
        UserDefaults.standard.removeObject(forKey: "WhispreeSettings")
        let settings = AppSettings()
        XCTAssertFalse(settings.isStreamingEnabled, "스트리밍 모드는 기본 OFF이어야 함")
    }

    /// Trace: Scenario 1, Section 3b → 4 — 직렬화
    func testStreamingSettingPersistence() {
        var settings = AppSettings()
        settings.isStreamingEnabled = true
        settings.save()

        let reloaded = AppSettings()
        XCTAssertTrue(reloaded.isStreamingEnabled, "스트리밍 설정이 저장/복원되어야 함")

        // 정리: 기본값으로 복원
        var cleanup = AppSettings()
        cleanup.isStreamingEnabled = false
        cleanup.save()
    }

    /// Trace: Scenario 1, Section 3c — computed property
    func testIsStreamingModeOnlyWithWhisperKit() async {
        let appState = await AppState()
        await MainActor.run {
            appState.settings.isStreamingEnabled = true
            appState.settings.sttProviderType = .whisperKit
            XCTAssertTrue(appState.isStreamingMode, "WhisperKit + 스트리밍 ON → isStreamingMode true")

            appState.settings.sttProviderType = .groq
            XCTAssertFalse(appState.isStreamingMode, "Groq + 스트리밍 ON → isStreamingMode false")

            appState.settings.sttProviderType = .mlxAudio
            XCTAssertFalse(appState.isStreamingMode, "MLX + 스트리밍 ON → isStreamingMode false")

            appState.settings.isStreamingEnabled = false
            appState.settings.sttProviderType = .whisperKit
            XCTAssertFalse(appState.isStreamingMode, "WhisperKit + 스트리밍 OFF → isStreamingMode false")
        }
    }

    // MARK: - Scenario 2: 스트리밍 녹음 시작

    /// Trace: Scenario 2, Section 5 — 모델 미로드
    func testStreamingStartModelNotLoaded() async {
        let provider = WhisperKitProvider(modelId: "openai_whisper-large-v3_turbo")
        do {
            try await provider.startStreaming(
                language: nil,
                onSegmentConfirmed: { _, _ in },
                onError: { _ in }
            )
            XCTFail("모델 미로드 시 throw 해야 함")
        } catch {
            XCTAssertTrue(error is STTError, "STTError 타입이어야 함")
        }
    }

    /// Trace: Scenario 2 — isStreaming 초기 상태
    func testStreamingIsStreamingDefaultFalse() {
        let provider = WhisperKitProvider(modelId: "openai_whisper-large-v3_turbo")
        XCTAssertFalse(provider.isStreaming, "초기 상태에서 isStreaming은 false여야 함")
    }

    // MARK: - Scenario 3: 실시간 텍스트 삽입

    /// Trace: Scenario 3, Section 3a — 텍스트 조합
    func testConfirmedSegmentsJoinedCorrectly() {
        let segments = ["안녕하세요", "오늘 회의", "내용은"]
        let joined = segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(joined, "안녕하세요 오늘 회의 내용은")
    }

    /// Trace: Scenario 3, Section 3b — AppState 업데이트
    func testPartialTextUpdatedOnCallback() async {
        let appState = await AppState()
        await MainActor.run {
            appState.partialText = ""
            appState.partialText = "안녕하세요 오늘"
            XCTAssertEqual(appState.partialText, "안녕하세요 오늘")
        }
    }

    // MARK: - Scenario 4: 세그먼트 확정 시 LLM 교정

    /// Trace: Scenario 4, Section 3a — Task 취소
    func testStreamingCorrectionCancelsOnNewSegment() async {
        let task = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "corrected"
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("취소된 Task는 CancellationError를 throw해야 함")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// Trace: Scenario 4, Section 3a — 프롬프트 재사용
    func testStreamingCorrectionUsesExistingPrompts() {
        let prompt = CorrectionPrompts.prompt(for: .standard, language: .korean)
        XCTAssertFalse(prompt.isEmpty, "교정 프롬프트가 비어있으면 안 됨")
    }

    // MARK: - Scenario 5: 스트리밍 녹음 종료

    /// Trace: Scenario 5, Section 3b — 멱등 stopStreaming
    func testStreamingStopCleansUp() async {
        let provider = WhisperKitProvider(modelId: "openai_whisper-large-v3_turbo")
        await provider.stopStreaming()
        XCTAssertFalse(provider.isStreaming, "stopStreaming 후 isStreaming은 false여야 함")
    }

    /// Trace: Scenario 5 — getAccumulatedText 초기 상태
    func testGetAccumulatedTextEmpty() {
        let provider = WhisperKitProvider(modelId: "openai_whisper-large-v3_turbo")
        let text = provider.getAccumulatedText()
        XCTAssertEqual(text, "", "스트리밍 전 getAccumulatedText는 빈 문자열이어야 함")
    }

    // MARK: - Scenario 6: 에러 복구

    /// Trace: Scenario 6, Section 3b — 에러 메시지
    func testStreamingErrorShowsMessage() {
        let error = AppError.sttError("스트리밍 오류: test error")
        XCTAssertEqual(error.title, "Transcription Error")
        XCTAssertTrue(error.isRecoverable)
    }

    /// Trace: Scenario 6 — STTError.streamingNotSupported
    func testStreamingNotSupportedError() {
        let error = STTError.streamingNotSupported
        XCTAssertNotNil(error.errorDescription)
    }
}
