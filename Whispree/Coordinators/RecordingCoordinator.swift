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
    }

    // MARK: - Streaming Pipeline (Manual Transcribe Loop)

    /// AudioService로 녹음하면서 주기적으로 transcribe() 호출.
    /// AudioStreamTranscriber 대신 배치와 동일한 코드 경로를 사용하여 turbo 모델 호환.
    @MainActor
    private func streamingTranscribeLoop(sttProvider: any STTProvider) async {
        let minBufferSamples = Int(2.0 * 16_000)  // 최소 2초
        let pollInterval: UInt64 = 1_500_000_000   // 1.5초 간격
        var lastTranscribedSize = 0
        var previousText = ""

        while !Task.isCancelled && appState.isRecording {
            // 폴링 대기
            try? await Task.sleep(nanoseconds: pollInterval)
            guard !Task.isCancelled && appState.isRecording else { break }

            let buffer = audioService.getCurrentBuffer()

            // 최소 버퍼 크기 미달 → 대기
            guard buffer.count >= minBufferSamples else { continue }

            // 새 오디오가 0.5초 미만이면 스킵 (중복 transcribe 방지)
            let newSamples = buffer.count - lastTranscribedSize
            guard newSamples >= Int(0.5 * 16_000) else { continue }

            lastTranscribedSize = buffer.count

            do {
                let result = try await sttProvider.transcribe(
                    audioBuffer: buffer,
                    language: appState.settings.language == .auto ? nil : appState.settings.language,
                    promptTokens: nil  // WhisperKitProvider 내부에서 domainWordSets로 빌드
                )

                guard !Task.isCancelled && appState.isRecording else { break }

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                // 오버레이 업데이트
                appState.partialText = text

                // 텍스트가 변경되었으면 LLM 교정 트리거
                if text != previousText {
                    previousText = text
                    appState.finalText = text
                    triggerStreamingCorrection(confirmedText: text)
                }
            } catch {
                // transcribe 실패는 비치명적 — 다음 시도에서 재시도
                StreamLog.write("streamingTranscribeLoop error: \(error)")
            }
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

        // AudioService 녹음 중지 (스트리밍 루프가 AudioService를 사용)
        _ = audioService.stopRecording()

        let activeStreamingTask = streamingTask

        currentTask = Task { [weak self] in
            guard let self else { return }

            // 스트리밍 루프 완료 대기
            await activeStreamingTask?.value
            streamingTask = nil

            let rawText = appState.finalText
            guard !rawText.isEmpty else {
                appState.transcriptionState = .idle
                appState.partialText = ""
                return
            }

            // 최종 LLM 교정 1회 (interim 교정과 동일한 프롬프트/매핑)
            if let llmProvider = appState.llmProvider,
               appState.settings.isLLMEnabled,
               !(llmProvider is NoneProvider)
            {
                appState.transcriptionState = .correcting

                var systemPrompt: String = switch appState.settings.correctionMode {
                    case .custom:
                        appState.settings.customLLMPrompt ?? CorrectionPrompts.codeSwitchPrompt
                    case .standard, .fillerRemoval, .structured:
                        CorrectionPrompts.prompt(
                            for: appState.settings.correctionMode,
                            language: appState.settings.language
                        )
                }

                let corrections = appState.settings.domainWordSets.filter(\.isEnabled).flatMap(\.corrections)
                if !corrections.isEmpty {
                    let mappingText = corrections.map { "\($0.from) → \($0.to)" }.joined(separator: "\n")
                    systemPrompt += "\n\n교정 매핑 (왼쪽 표현이 텍스트에 있으면 오른쪽으로 교정):\n" + mappingText
                }

                let glossary = appState.settings.domainWordSets.filter(\.isEnabled).flatMap(\.words)

                if let corrected = try? await llmProvider.correct(
                    text: rawText, systemPrompt: systemPrompt,
                    glossary: glossary.isEmpty ? nil : glossary,
                    screenshots: []
                ) {
                    guard !Task.isCancelled else { return }
                    appState.correctedText = corrected
                }
            }

            // 대상 앱에 최종 텍스트 1회 삽입
            let textToInsert = appState.correctedText.isEmpty ? rawText : appState.correctedText
            if appState.settings.hasCompletedOnboarding {
                appState.transcriptionState = .inserting
                let success = await textInsertionService.insertText(textToInsert, targetApp: previousApp)
                if !success {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textToInsert, forType: .string)
                }
            }

            // 히스토리 기록
            appState.addToHistory(
                original: rawText,
                corrected: appState.correctedText.isEmpty ? nil : appState.correctedText
            )

            // 초기화
            appState.transcriptionState = .idle
            appState.partialText = ""
            appState.finalText = ""
            appState.correctedText = ""
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
                promptTokens: nil
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
