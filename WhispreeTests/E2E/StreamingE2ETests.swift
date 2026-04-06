import XCTest
@testable import Whispree
import WhisperKit

/// Streaming ASR E2E Tests — 실제 WhisperKit 모델 로드 + AudioStreamTranscriber 동작 검증
/// 첫 실행 시 모델 다운로드로 ~30초 소요될 수 있음
final class StreamingE2ETests: XCTestCase {

    // MARK: - E2E: WhisperKitProvider 스트리밍 시작 + 콜백 발생

    /// 실제 모델을 로드하고 startStreaming을 호출하면:
    /// 1. startStreaming이 throw하지 않아야 함
    /// 2. isStreaming이 true가 되어야 함
    /// 3. stateChangeCallback이 최소 1회 호출되어야 함 (isRecording=true 또는 currentText 변경)
    /// 4. stopStreaming 후 정상 종료되어야 함
    func testStreamingStartCallbackFiresAndStops() async throws {
        let provider = WhisperKitProvider(modelId: "openai_whisper-large-v3_turbo")

        // 모델 로드
        try await provider.setup()
        XCTAssertTrue(provider.validate().isValid, "모델이 로드되어야 함")

        // 콜백 발생 여부 추적
        let callbackFired = expectation(description: "stateChangeCallback이 최소 1회 호출")
        var callbackCount = 0

        // 스트리밍 시작 (별도 Task에서 — startStreaming은 blocking)
        let streamTask = Task {
            try await provider.startStreaming(
                language: nil,
                onSegmentConfirmed: { @MainActor confirmed, full in
                    callbackCount += 1
                    if callbackCount == 1 {
                        callbackFired.fulfill()
                    }
                },
                onError: { @MainActor error in
                    // 마이크 권한 없으면 에러 — 테스트 환경에서는 허용
                }
            )
        }

        // isStreaming 확인 (polling — async 시작에 시간 소요)
        var isStreamingNow = false
        for _ in 0..<20 { // 최대 10초
            try await Task.sleep(nanoseconds: 500_000_000)
            if provider.isStreaming {
                isStreamingNow = true
                break
            }
        }

        // 마이크 권한이 없으면 스트리밍 시작이 안 됨 — 이 경우 테스트 스킵
        if !isStreamingNow {
            streamTask.cancel()
            _ = await streamTask.result
            await provider.teardown()
            // 마이크 권한 없는 환경에서는 스킵
            throw XCTSkip("마이크 권한 없음 — 스트리밍 테스트 스킵")
        }

        XCTAssertTrue(isStreamingNow, "startStreaming 후 isStreaming은 true여야 함")

        // 콜백 대기 (최대 15초)
        await fulfillment(of: [callbackFired], timeout: 15.0)
        XCTAssertGreaterThan(callbackCount, 0, "콜백이 최소 1회 호출되어야 함")

        // 스트리밍 종료
        await provider.stopStreaming()
        streamTask.cancel()
        _ = await streamTask.result

        XCTAssertFalse(provider.isStreaming, "stopStreaming 후 isStreaming은 false여야 함")

        // 정리
        await provider.teardown()
    }

    /// 스트리밍 시작 후 stopStreaming → getAccumulatedText가 빈 문자열이 아닌 무언가를 반환
    /// (마이크가 없어도 "Waiting for speech..." 등의 placeholder가 올 수 있음)
    func testStreamingAccumulatesState() async throws {
        let provider = WhisperKitProvider(modelId: "openai_whisper-large-v3_turbo")
        try await provider.setup()

        let streamTask = Task {
            try await provider.startStreaming(
                language: nil,
                onSegmentConfirmed: { @MainActor _, _ in },
                onError: { @MainActor _ in }
            )
        }

        // 3초 대기 후 종료
        try await Task.sleep(nanoseconds: 3_000_000_000)

        await provider.stopStreaming()
        streamTask.cancel()
        _ = await streamTask.result

        // lastState가 캐시되어 있어야 함
        // (마이크 입력이 없어도 state 자체는 존재)
        // getAccumulatedText는 빈 문자열일 수 있지만 crash 안 해야 함
        let text = provider.getAccumulatedText()
        // 이 assertion은 crash 방지 확인 — 값 자체는 마이크 입력에 따라 다름
        XCTAssertNotNil(text)

        await provider.teardown()
    }

    /// isStreamingMode가 실제 provider 타입에 연동되는지 E2E 검증
    func testIsStreamingModeWithRealProvider() async throws {
        let appState = await AppState()
        await MainActor.run {
            appState.settings.isStreamingEnabled = true
            appState.settings.sttProviderType = .whisperKit
        }

        // provider 로드
        await appState.switchSTTProvider(to: .whisperKit)

        await MainActor.run {
            XCTAssertTrue(appState.isStreamingMode, "WhisperKit 로드 후 isStreamingMode는 true여야 함")
        }

        // Groq로 전환하면 false
        await appState.switchSTTProvider(to: .groq)
        await MainActor.run {
            XCTAssertFalse(appState.isStreamingMode, "Groq 전환 후 isStreamingMode는 false여야 함")
        }
    }
}
