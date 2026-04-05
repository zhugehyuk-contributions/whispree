import SwiftUI

struct STTSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // STT Provider Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("STT Provider")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        // Groq Cloud
                        STTProviderRow(
                            title: "Groq Cloud API",
                            description: "클라우드 STT, API Key 필요",
                            metrics: .cloud(latencyMs: 200, qualityScore: 95),
                            isSelected: appState.settings.sttProviderType == .groq,
                            state: appState.settings.sttProviderType == .groq ? appState.whisperModelState : .ready,
                            onSelect: {
                                appState.settings.sttProviderType = .groq
                                appState.settings.save()
                                Task { await appState.switchSTTProvider(to: .groq) }
                            }
                        )

                        // MLX Audio
                        let mlxCompat = ModelCompatibility.evaluate(modelSizeBytes: 1_000_000_000)
                        STTProviderRow(
                            title: "MLX Audio",
                            description: "mlx-audio, 한중일영 (uv 필요)",
                            metrics: .local(
                                size: "~1.0 GB",
                                ramPercent: mlxCompat.ramUsagePercent,
                                tokPerSec: nil,
                                qualityScore: 65,
                                grade: mlxCompat.grade
                            ),
                            isSelected: appState.settings.sttProviderType == .mlxAudio,
                            state: appState.settings.sttProviderType == .mlxAudio ? appState.whisperModelState : (modelManager.mlxAudioDownloaded ? .ready : .notDownloaded),
                            onSelect: {
                                appState.settings.sttProviderType = .mlxAudio
                                appState.settings.save()
                                Task { await appState.switchSTTProvider(to: .mlxAudio) }
                            }
                        )

                        // WhisperKit
                        let selectedWhisper = ModelInfo.availableWhisperModels.first(where: { $0.id == appState.settings.whisperModelId }) ?? .whisperLargeV3Turbo
                        let whisperCompat = ModelCompatibility.evaluate(modelSizeBytes: selectedWhisper.sizeBytes)
                        STTProviderRow(
                            title: "WhisperKit",
                            description: "로컬 CoreML+ANE, 99개 언어",
                            metrics: .local(
                                size: selectedWhisper.sizeDescription,
                                ramPercent: whisperCompat.ramUsagePercent,
                                tokPerSec: nil,
                                qualityScore: selectedWhisper.id == "openai_whisper-large-v3" ? 95 : 75,
                                grade: whisperCompat.grade
                            ),
                            isSelected: appState.settings.sttProviderType == .whisperKit,
                            state: appState.settings.sttProviderType == .whisperKit ? appState.whisperModelState : (modelManager.whisperKitDownloaded ? .ready : .notDownloaded),
                            onSelect: {
                                appState.settings.sttProviderType = .whisperKit
                                appState.settings.save()
                                Task { await appState.switchSTTProvider(to: .whisperKit) }
                            }
                        )
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.5))
                )

                // WhisperKit Model Selection
                if appState.settings.sttProviderType == .whisperKit {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WhisperKit 모델")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        ForEach(ModelInfo.availableWhisperModels) { model in
                            Button(action: {
                                guard appState.settings.whisperModelId != model.id else { return }
                                appState.settings.whisperModelId = model.id
                                appState.settings.save()
                                Task { await appState.switchSTTProvider(to: .whisperKit) }
                            }) {
                                HStack(spacing: 10) {
                                    Image(systemName: appState.settings.whisperModelId == model.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(appState.settings.whisperModelId == model.id ? .blue : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(model.name).font(.subheadline).fontWeight(.medium)
                                            if model.id == "openai_whisper-large-v3" {
                                                Text("최고 품질")
                                                    .font(.caption2).fontWeight(.semibold)
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Capsule().fill(.blue.opacity(0.15)))
                                                    .foregroundStyle(.blue)
                                            }
                                        }
                                        Text("\(model.description) (\(model.sizeDescription))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(appState.settings.whisperModelId == model.id ? .blue.opacity(0.08) : .clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if appState.settings.whisperModelId == "openai_whisper-large-v3" {
                            Label("Large V3는 Turbo 대비 2배 크고 느리지만 정확도가 높습니다", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary.opacity(0.5))
                    )
                }

                // Streaming Mode Toggle (WhisperKit only)
                if appState.settings.sttProviderType == .whisperKit {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { appState.settings.isStreamingEnabled },
                            set: {
                                appState.settings.isStreamingEnabled = $0
                                appState.settings.save()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("실시간 스트리밍")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("녹음 중 실시간으로 텍스트를 표시하고, 종료 시 교정된 텍스트를 삽입합니다")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary.opacity(0.5))
                    )
                }

                // Groq API Key Section
                if appState.settings.sttProviderType == .groq {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Groq API Key")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        SecureField("API Key", text: Binding(
                            get: { appState.settings.groqApiKey },
                            set: {
                                appState.settings.groqApiKey = $0
                                appState.settings.save()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)

                        if appState.settings.groqApiKey.isEmpty {
                            Label("console.groq.com에서 무료 API Key를 발급받으세요", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Label("API Key 설정됨", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary.opacity(0.5))
                    )
                }

                // Cold Start Warning
                if case .loading = appState.whisperModelState,
                   appState.settings.sttProviderType == .mlxAudio
                {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("콜드 스타트 중...")
                                .font(.caption).fontWeight(.medium)
                            Text("첫 실행 시 약 1분 소요됩니다. 이후엔 즉시 사용 가능합니다.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary.opacity(0.5))
                    )
                }

                // Model Download Notice
                if case .notDownloaded = appState.whisperModelState,
                   appState.settings.sttProviderType != .groq
                {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.blue)
                        Text("다운로드 탭에서 모델을 다운로드하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary.opacity(0.5))
                    )
                }
            }
            .padding(24)
        }
    }
}

// MARK: - STTProviderRow (Downloads 탭 스타일과 통일)

struct STTProviderRow: View {
    let title: String
    let description: String
    let metrics: ModelMetrics
    let isSelected: Bool
    let state: ModelState
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    // Radio
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .blue : .secondary)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    metricsView
                }

                // State (선택된 경우만)
                if isSelected {
                    HStack(spacing: 6) {
                        switch state {
                        case .ready:
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.caption)
                        case .loading:
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Loading...").font(.caption).foregroundStyle(.secondary)
                            }
                        case .downloading:
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Downloading...").font(.caption).foregroundStyle(.secondary)
                            }
                        case .notDownloaded:
                            Label("Download required", systemImage: "arrow.down.circle")
                                .foregroundStyle(.orange).font(.caption)
                        case let .error(msg):
                            Label(msg, systemImage: "xmark.circle")
                                .foregroundStyle(.red).font(.caption)
                        }
                    }
                    .padding(.leading, 32)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var metricsView: some View {
        switch metrics {
        case let .local(size, ramPercent, tokPerSec, qualityScore, grade):
            ModelMetricsView(
                sizeText: size,
                ramPercent: ramPercent,
                tokPerSec: tokPerSec,
                latencyMs: nil,
                qualityScore: qualityScore,
                grade: grade
            )
        case let .cloud(latencyMs, qualityScore):
            ModelMetricsView(
                sizeText: "☁️",
                ramPercent: nil,
                tokPerSec: nil,
                latencyMs: latencyMs,
                qualityScore: qualityScore,
                grade: .runsGreat
            )
        }
    }
}
