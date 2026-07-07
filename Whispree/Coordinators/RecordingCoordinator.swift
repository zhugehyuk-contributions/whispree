import AppKit
import Combine
import Foundation

@MainActor
final class RecordingCoordinator: ObservableObject {
    private let appState: AppState
    private let audioService: AudioService
    private let textInsertionService: TextInsertionService

    private var currentTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var levelCancellable: AnyCancellable?
    private var bandsCancellable: AnyCancellable?
    private var workspaceObserver: AnyCancellable?
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private let continuousCapture = ContinuousScreenCaptureService()

    // MARK: - Streaming State

    private var streamingCorrectionTask: Task<Void, Never>?
    private var correctionGeneration: UInt64 = 0
    /// 녹음 시작 시 캡처된 모드 — 세션 중 설정 변경에 안전
    private var isCurrentSessionStreaming: Bool = false
    /// 증분 전사에서 확정된 세그먼트 목록
    private var streamingFinalizedSegments: [FinalizedSegment] = []
    private var streamingLastFinalizedEndTime: Float = 0

    init(
        appState: AppState,
        audioService: AudioService,
        textInsertionService: TextInsertionService
    ) {
        self.appState = appState
        self.audioService = audioService
        self.textInsertionService = textInsertionService

        // Pipe audio level + frequency bands to appState for UI
        levelCancellable = audioService.$currentLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak appState] level in
                appState?.currentAudioLevel = level
            }

        bandsCancellable = audioService.$frequencyBands
            .receive(on: DispatchQueue.main)
            .sink { [weak appState] bands in
                appState?.frequencyBands = bands
            }

        // Track last non-Whispree frontmost app for text insertion
        workspaceObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                Task { @MainActor [weak self] in
                    self?.lastExternalApp = app
                }
            }
    }

    func startRecording() {
        // 이전 파이프라인이 stuck 상태면 강제 리셋 (transcribing/correcting/inserting에서 멈춘 경우)
        if appState.transcriptionState != .idle, appState.transcriptionState != .recording {
            currentTask?.cancel()
            currentTask = nil
            streamingTask?.cancel()
            streamingTask = nil
            if audioService.isRecording {
                _ = audioService.stopRecording()
            }
            appState.transcriptionState = .idle
        }
        guard appState.transcriptionState == .idle else { return }
        guard let sttProvider = appState.sttProvider else {
            appState.currentError = .sttError("STT 프로바이더가 설정되지 않았습니다.")
            return
        }
        let sttValidation = sttProvider.validate()
        guard sttValidation.isValid else {
            appState.currentError = .sttError(sttValidation.message)
            return
        }

        // Remember the app the user was typing in before recording
        // If Whispree is frontmost (user clicked menu bar), use last tracked external app
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            previousApp = lastExternalApp
        } else {
            previousApp = frontmost
        }

        // 세션 모드 캡처 — 녹음 중 설정 변경에 안전
        isCurrentSessionStreaming = appState.isStreamingMode

        // 연속 스크린샷 캡처 시작 (배치 모드에서만 — 스트리밍 모드에서는 비활성)
        if !isCurrentSessionStreaming,
           appState.settings.isScreenshotContextEnabled,
           appState.llmProvider?.supportsVision == true
        {
            appState.capturedScreenshots = []
            continuousCapture.onCapture = { [weak appState] screenshot in
                appState?.capturedScreenshots.append(screenshot)
            }
            continuousCapture.startMonitoring()
        }

        // 스트리밍 모드 분기 — AudioService로 녹음 + 주기적 transcribe() 호출
        // AudioStreamTranscriber 대신 배치와 동일한 transcribe() 사용 (turbo 모델 호환)
        if isCurrentSessionStreaming {
            // 도메인 단어 세트 설정
            if let whisperProvider = sttProvider as? WhisperKitProvider {
                whisperProvider.domainWordSets = appState.settings.domainWordSets
            }

            // AudioService로 녹음 시작 (FFT 시각화 유지)
            do {
                try audioService.startRecording()
            } catch {
                appState.currentError = .sttError("마이크 시작 실패: \(error.localizedDescription)")
                return
            }

            appState.transcriptionState = .recording
            appState.isRecording = true
            appState.partialText = ""
            appState.finalText = ""
            appState.correctedText = ""
            streamingFinalizedSegments = []
            streamingLastFinalizedEndTime = 0

            streamingTask = Task { [weak self] in
                guard let self else { return }
                await self.streamingTranscribeLoop(sttProvider: sttProvider)
                await MainActor.run { self.streamingTask = nil }
            }
            return
        }

        // 배치 모드 (기존)
        do {
            try audioService.startRecording()
            appState.transcriptionState = .recording
            appState.isRecording = true
            appState.partialText = ""
            appState.finalText = ""
            appState.correctedText = ""
        } catch {
            appState.currentError = .sttError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard appState.transcriptionState == .recording else {
            return
        }

        // 세션 시작 시 캡처된 모드로 분기 — 녹음 중 설정 변경에 안전
        if isCurrentSessionStreaming {
            stopStreamingRecording()
            return
        }

        // 배치 모드 (기존)
        _ = continuousCapture.stopMonitoring()

        let audioBuffer = audioService.stopRecording()
        appState.isRecording = false

        guard !audioBuffer.isEmpty else {
            appState.transcriptionState = .idle
            return
        }

        let maxAmplitude = audioBuffer.map { abs($0) }.max() ?? 0
        guard maxAmplitude > 0.01 else {
            appState.transcriptionState = .idle
            return
        }

        currentTask = Task {
            await processPipeline(audioBuffer: audioBuffer)
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        streamingCorrectionTask?.cancel()
        streamingCorrectionTask = nil
        continuousCapture.reset()
        if audioService.isRecording {
            _ = audioService.stopRecording()
        }
        appState.transcriptionState = .idle
        appState.isRecording = false
        appState.partialText = ""
        appState.finalText = ""
        appState.correctedText = ""
        streamingFinalizedSegments = []
        streamingLastFinalizedEndTime = 0
    }

    // MARK: - Streaming Pipeline (Manual Transcribe Loop)

    /// 증분 스트리밍 전사 루프.
    /// clipTimestamps로 마지막 확정 지점 이후만 전사. 안정된 세그먼트를 finalize하여 재처리 방지.
    @MainActor
    private func streamingTranscribeLoop(sttProvider: any STTProvider) async {
        let minBufferSamples = Int(2.0 * 16_000)  // 최소 2초
        let pollInterval: UInt64 = 1_500_000_000   // 1.5초 간격
        let sampleRate: Float = 16_000
        let finalizeAge: Float = 8.0  // 8초 이상 지난 텍스트 확정 대상

        var localFinalized: [FinalizedSegment] = []
        var lastFinalizedEndTime: Float = 0
        var lastPendingText = ""
        var stableCount = 0
        var lastTranscribedSize = 0

        while !Task.isCancelled && appState.isRecording {
            try? await Task.sleep(nanoseconds: pollInterval)
            guard !Task.isCancelled && appState.isRecording else { break }

            let buffer = audioService.getCurrentBuffer()
            guard buffer.count >= minBufferSamples else { continue }

            let newSamples = buffer.count - lastTranscribedSize
            guard newSamples >= Int(0.5 * sampleRate) else { continue }

            // 무음 감지: 새 오디오의 RMS 에너지가 임계값 미만이면 스킵
            // WhisperKit turbo는 무음에서 "감사합니다" 등 YouTube 인삿말 환각 생성
            let newAudioStart = max(0, buffer.count - newSamples)
            let newAudio = Array(buffer[newAudioStart...])
            let rms = sqrtf(newAudio.map { $0 * $0 }.reduce(0, +) / Float(max(newAudio.count, 1)))
            guard rms > 0.008 else { continue }

            lastTranscribedSize = buffer.count

            let currentAudioTime = Float(buffer.count) / sampleRate

            do {
                // clipStartTime으로 확정 지점 이후만 전사
                let result = try await sttProvider.transcribe(
                    audioBuffer: buffer,
                    language: appState.settings.language == .auto ? nil : appState.settings.language,
                    promptTokens: nil,
                    clipStartTime: lastFinalizedEndTime > 0 ? lastFinalizedEndTime : nil
                )

                guard !Task.isCancelled && appState.isRecording else { break }

                var pendingText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pendingText.isEmpty else { continue }

                // WhisperKit 환각 필터: 무음에서 생성되는 YouTube 인삿말 패턴
                let hallucinationPatterns = [
                    "감사합니다", "구독", "좋아요", "시청해", "다음 영상",
                    "채널", "알림", "구독과", "Thank you", "subscribe",
                    "MBC 뉴스", "KBS 뉴스", "SBS"
                ]
                let isLikelyHallucination = hallucinationPatterns.contains { pendingText.contains($0) }
                    && rms < 0.015  // 에너지가 낮을 때만 필터 (실제 말했으면 통과)
                if isLikelyHallucination { continue }

                // 안정성 체크: 텍스트가 2회 연속 동일하면 확정 가능
                if pendingText == lastPendingText {
                    stableCount += 1
                } else {
                    stableCount = 0
                    lastPendingText = pendingText
                }

                // 확정 판단: 오래된 텍스트 + 안정(2회 연속 동일)
                let cutoffTime = currentAudioTime - finalizeAge
                if stableCount >= 1, cutoffTime > lastFinalizedEndTime, !result.segments.isEmpty {
                    // 확정 대상 세그먼트 찾기: endTime <= cutoffTime
                    var segmentsToFinalize: [TranscriptionSegment] = []
                    var newEndTime = lastFinalizedEndTime
                    for seg in result.segments {
                        if let end = seg.end, end <= cutoffTime {
                            segmentsToFinalize.append(seg)
                            newEndTime = max(newEndTime, end)
                        }
                    }

                    if !segmentsToFinalize.isEmpty {
                        let finalizedText = segmentsToFinalize
                            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .joined(separator: " ")
                        let segment = FinalizedSegment(
                            text: finalizedText,
                            correctedText: nil,
                            startTime: lastFinalizedEndTime,
                            endTime: newEndTime
                        )
                        localFinalized.append(segment)
                        lastFinalizedEndTime = newEndTime
                        stableCount = 0

                        // 확정 세그먼트 LLM 교정 (비동기)
                        let segIdx = localFinalized.count - 1
                        triggerSegmentCorrection(
                            segmentIndex: segIdx,
                            text: finalizedText,
                            localFinalized: &localFinalized
                        )
                    }
                }

                // 화면 표시: 확정 텍스트 + 미확정 텍스트
                let finalizedDisplay = localFinalized.map(\.displayText).joined(separator: " ")
                let displayText = [finalizedDisplay, pendingText]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                appState.partialText = displayText
                appState.finalText = displayText

            } catch {
                StreamLog.write("streamingTranscribeLoop error: \(error)")
            }
        }

        // 루프 종료 시 로컬 상태를 appState에 반영
        streamingFinalizedSegments = localFinalized
        streamingLastFinalizedEndTime = lastFinalizedEndTime
    }

    /// 개별 확정 세그먼트의 LLM 교정 (비동기)
    @MainActor
    private func triggerSegmentCorrection(
        segmentIndex: Int,
        text: String,
        localFinalized: inout [FinalizedSegment]
    ) {
        guard let llmProvider = appState.llmProvider,
              appState.settings.isLLMEnabled,
              !(llmProvider is NoneProvider)
        else { return }

        let settings = appState.settings
        // 교정은 fire-and-forget — 완료 시 세그먼트 업데이트
        Task { @MainActor [weak self] in
            guard let self else { return }
            var systemPrompt: String = switch settings.correctionMode {
                case .custom:
                    settings.customLLMPrompt ?? CorrectionPrompts.codeSwitchPrompt
                case .standard, .fillerRemoval, .structured:
                    CorrectionPrompts.prompt(for: settings.correctionMode, language: settings.language)
            }

            let corrections = settings.domainWordSets.filter(\.isEnabled).flatMap(\.corrections)
            if !corrections.isEmpty {
                let mappingText = corrections.map { "\($0.from) → \($0.to)" }.joined(separator: "\n")
                systemPrompt += "\n\n교정 매핑 (왼쪽 표현이 텍스트에 있으면 오른쪽으로 교정):\n" + mappingText
            }

            let glossary = settings.domainWordSets.filter(\.isEnabled).flatMap(\.words)

            if let corrected = try? await llmProvider.correct(
                text: text,
                systemPrompt: systemPrompt,
                glossary: glossary.isEmpty ? nil : glossary,
                screenshots: []
            ) {
                // 교정 결과 반영 — partialText 재조립
                if segmentIndex < self.streamingFinalizedSegments.count {
                    self.streamingFinalizedSegments[segmentIndex].correctedText = corrected
                    self.rebuildStreamingDisplayText()
                }
            }
        }
    }

    /// 확정 세그먼트 + 현재 미확정 텍스트로 화면 재조립
    @MainActor
    private func rebuildStreamingDisplayText() {
        let finalizedDisplay = streamingFinalizedSegments.map(\.displayText).joined(separator: " ")
        let pending = appState.partialText  // 현재 표시 중인 텍스트에서 마지막 부분 유지
        // finalText에만 반영 (partialText는 루프에서 관리)
        if !finalizedDisplay.isEmpty {
            appState.finalText = finalizedDisplay
        }
    }

    @MainActor
    private func handleStreamingUpdate(confirmedText: String, fullText: String) {
        appState.partialText = fullText

        // confirmedText가 비어있으면 provisional update만 (LLM 미실행)
        guard !confirmedText.isEmpty else { return }
        appState.finalText = confirmedText

        // 세그먼트 확정 시 LLM 교정 시작
        triggerStreamingCorrection(confirmedText: confirmedText)
    }

    @MainActor
    private func triggerStreamingCorrection(confirmedText: String) {
        guard let llmProvider = appState.llmProvider,
              appState.settings.isLLMEnabled,
              !(llmProvider is NoneProvider)
        else { return }

        streamingCorrectionTask?.cancel()
        correctionGeneration &+= 1
        let currentGen = correctionGeneration
        let settings = appState.settings

        streamingCorrectionTask = Task { @MainActor in
            var systemPrompt: String = switch settings.correctionMode {
                case .custom:
                    settings.customLLMPrompt ?? CorrectionPrompts.codeSwitchPrompt
                case .standard, .fillerRemoval, .structured:
                    CorrectionPrompts.prompt(for: settings.correctionMode, language: settings.language)
            }

            let corrections = settings.domainWordSets.filter(\.isEnabled).flatMap(\.corrections)
            if !corrections.isEmpty {
                let mappingText = corrections.map { "\($0.from) → \($0.to)" }.joined(separator: "\n")
                systemPrompt += "\n\n교정 매핑 (왼쪽 표현이 텍스트에 있으면 오른쪽으로 교정):\n" + mappingText
            }

            let glossary = settings.domainWordSets.filter(\.isEnabled).flatMap(\.words)

            do {
                let corrected = try await llmProvider.correct(
                    text: confirmedText,
                    systemPrompt: systemPrompt,
                    glossary: glossary.isEmpty ? nil : glossary,
                    screenshots: []
                )
                guard !Task.isCancelled, correctionGeneration == currentGen else { return }
                appState.correctedText = corrected
            } catch {
                // 교정 실패 → 원문 유지
            }
        }
    }

    private func stopStreamingRecording() {
        streamingCorrectionTask?.cancel()
        streamingCorrectionTask = nil
        appState.isRecording = false  // streamingTranscribeLoop의 while 조건 탈출

        // AudioService 녹음 중지
        _ = audioService.stopRecording()

        // 스트리밍 루프를 cancel로 즉시 중단 (1.5초 sleep 대기 방지)
        streamingTask?.cancel()
        let activeStreamingTask = streamingTask

        currentTask = Task { [weak self] in
            guard let self else { return }

            await activeStreamingTask?.value
            streamingTask = nil

            // 최종 텍스트: 이미 화면에 표시 중인 텍스트를 그대로 사용 (재전사/재교정 없음)
            let textToInsert = appState.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawText = textToInsert
            if appState.settings.hasCompletedOnboarding {
                appState.transcriptionState = .inserting
                let success = await textInsertionService.insertText(textToInsert, targetApp: previousApp)
                if !success {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textToInsert, forType: .string)
                }
            }

            // 히스토리 기록
            let correctedFull = textToInsert != rawText ? textToInsert : nil
            appState.addToHistory(original: rawText, corrected: correctedFull)

            // 초기화
            appState.transcriptionState = .idle
            appState.partialText = ""
            appState.finalText = ""
            appState.correctedText = ""
            streamingFinalizedSegments = []
            streamingLastFinalizedEndTime = 0
        }
    }

    @MainActor
    private func handleStreamingError(_ error: Error) {
        streamingCorrectionTask?.cancel()
        streamingCorrectionTask = nil
        streamingTask?.cancel()
        streamingTask = nil

        if audioService.isRecording {
            _ = audioService.stopRecording()
        }

        let preservedText = appState.finalText

        appState.currentError = AppError.sttError("스트리밍 오류: \(error.localizedDescription)")

        if !preservedText.isEmpty {
            currentTask = Task { [weak self] in
                guard let self else { return }
                await textInsertionService.insertText(preservedText, targetApp: previousApp)
                appState.addToHistory(original: preservedText, corrected: nil)
            }
        }

        appState.transcriptionState = .idle
        appState.isRecording = false
        appState.partialText = ""
    }

    // MARK: - Pipeline

    private func processPipeline(audioBuffer: [Float]) async {
        // Step 1: Transcribe via STT Provider
        appState.transcriptionState = .transcribing

        defer {
            appState.transcriptionState = .idle
        }

        do {
            guard let sttProvider = appState.sttProvider else {
                appState.currentError = .sttError("No STT provider configured")
                return
            }

            // 도메인 단어 세트를 Provider에 설정 (transcribe 시 내부에서 tokenize)
            if let whisperProvider = sttProvider as? WhisperKitProvider {
                whisperProvider.domainWordSets = appState.settings.domainWordSets
            }

            let result = try await sttProvider.transcribe(
                audioBuffer: audioBuffer,
                language: appState.settings.language == .auto ? nil : appState.settings.language,
                promptTokens: nil,
                clipStartTime: nil
            )

            guard !Task.isCancelled else { return }

            let transcribedText = result.text
            appState.finalText = transcribedText

            // Step 2: LLM Correction via LLM Provider
            var textToInsert = transcribedText

            if let llmProvider = appState.llmProvider, llmProvider.isReady,
               !(llmProvider is NoneProvider)
            {
                appState.transcriptionState = .correcting

                do {
                    var systemPrompt: String = switch appState.settings.correctionMode {
                        case .custom:
                            appState.settings.customLLMPrompt ?? CorrectionPrompts.codeSwitchPrompt
                        case .standard, .fillerRemoval, .structured:
                            CorrectionPrompts.prompt(
                                for: appState.settings.correctionMode,
                                language: appState.settings.language
                            )
                    }

                    // 교정 매핑 주입 (항상, correction mode와 무관)
                    let corrections = appState.settings.domainWordSets
                        .filter(\.isEnabled)
                        .flatMap(\.corrections)
                    if !corrections.isEmpty {
                        let mappingText = corrections.map { "\($0.from) → \($0.to)" }.joined(separator: "\n")
                        systemPrompt += "\n\n교정 매핑 (왼쪽 표현이 텍스트에 있으면 오른쪽으로 교정):\n" + mappingText
                    }

                    // 스크린샷 맥락 프롬프트 주입
                    let screenshotData = appState.capturedScreenshots.map(\.imageData)
                    if !screenshotData.isEmpty {
                        systemPrompt += CorrectionPrompts.screenshotContextPrompt
                    }

                    // 활성화된 도메인 단어 세트에서 glossary 생성
                    let glossary = appState.settings.domainWordSets
                        .filter(\.isEnabled)
                        .flatMap(\.words)

                    let corrected = try await llmProvider.correct(
                        text: transcribedText,
                        systemPrompt: systemPrompt,
                        glossary: glossary.isEmpty ? nil : glossary,
                        screenshots: screenshotData
                    )
                    guard !Task.isCancelled else { return }
                    appState.correctedText = corrected
                    textToInsert = corrected
                } catch {
                    // LLM failure is non-fatal - use raw transcription
                    appState.correctedText = ""
                    textToInsert = transcribedText
                }
            }

            // Step 3: 스크린샷 선택 (텍스트 삽입 전에 — 포커스 이동 문제 방지)
            guard !Task.isCancelled else { return }
            var selectedImages: [Data] = []
            if appState.settings.hasCompletedOnboarding,
               appState.settings.isScreenshotPasteEnabled,
               !appState.capturedScreenshots.isEmpty
            {
                appState.transcriptionState = .selectingScreenshots

                selectedImages = await withCheckedContinuation { continuation in
                    appState.screenshotSelectionCallback = { selected in
                        continuation.resume(returning: selected)
                    }
                }
                appState.screenshotSelectionCallback = nil
            }

            // Step 4: 텍스트 삽입 → 대상 앱으로 포커스 이동 (선택 결과와 무관하게 항상 실행)
            guard !Task.isCancelled else { return }
            if appState.settings.hasCompletedOnboarding {
                appState.transcriptionState = .inserting

                let success = await textInsertionService.insertText(textToInsert, targetApp: previousApp)
                if !success {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textToInsert, forType: .string)
                }

                // Step 5: 선택된 이미지 붙여넣기
                if !selectedImages.isEmpty, !Task.isCancelled {
                    await textInsertionService.insertImages(selectedImages, targetApp: previousApp)
                }
            }

            // Record in history
            appState.addToHistory(
                original: transcribedText,
                corrected: appState.correctedText.isEmpty ? nil : appState.correctedText
            )

        } catch {
            appState.currentError = .sttError(error.localizedDescription)
        }
    }
}
