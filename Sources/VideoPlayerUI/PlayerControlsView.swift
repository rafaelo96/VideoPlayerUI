import SwiftUI

struct PlayerControlsView: View {
    @ObservedObject var state: PlayerState

    var body: some View {
        LiquidGlassPanel(cornerRadius: 18) {
            VStack(spacing: 9) {
                HStack {
                    Spacer(minLength: 24)
                    timeline
                    Spacer(minLength: 24)
                }

                Divider()
                    .overlay(.white.opacity(0.10))
                    .padding(.horizontal, 4)

                HStack(spacing: 16) {
                    playbackInfoCluster
                        .frame(maxWidth: .infinity, alignment: .leading)

                    transportControls
                        .frame(width: 154)

                    optionsBar
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 11)
        }
        .frame(maxWidth: 980)
        .animation(.easeInOut(duration: 0.22), value: state.isPlaying)
        .animation(.easeInOut(duration: 0.22), value: state.playbackRate)
        .animation(.easeInOut(duration: 0.22), value: state.fpsMode)
        .animation(.easeInOut(duration: 0.22), value: state.interpolationMode)
        .animation(.easeInOut(duration: 0.22), value: state.qualityMode)
        .animation(.easeInOut(duration: 0.22), value: state.audioTracks.count)
    }

    private var timeline: some View {
        HStack(spacing: 10) {
            Text(state.formattedTime(state.currentTime))
                .frame(width: 62, alignment: .leading)

            Slider(
                value: Binding(
                    get: { state.currentTime },
                    set: { state.seek(to: $0) }
                ),
                in: 0...max(state.duration, 1)
            )
            .tint(accentColor)

            Text(state.formattedTime(state.duration))
                .frame(width: 62, alignment: .trailing)
        }
        .frame(maxWidth: 680)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.86))
    }

    private var playbackInfoCluster: some View {
        HStack(spacing: 12) {
            volumeControl

            optionDivider

            fpsReadout
        }
        .frame(minWidth: 210, alignment: .leading)
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 18)

            Slider(
                value: Binding(
                    get: { state.volume },
                    set: { state.setVolume($0) }
                ),
                in: 0...1
            )
            .tint(accentColor)
            .frame(width: 82)
        }
        .frame(width: 112, alignment: .leading)
    }

    private var fpsReadout: some View {
        HStack(spacing: 6) {
            Image(systemName: state.fpsMode.isActive ? "waveform.path.ecg" : "display")
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(String(format: "%.0f", state.displayRenderingFPS)) FPS")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Text(framePlusStateTitle)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(state.fpsMode.isActive ? accentColor : .white.opacity(0.78))
        .frame(width: 76, alignment: .leading)
    }

    private var transportControls: some View {
        HStack(spacing: 18) {
            iconButton("gobackward.10") {
                state.seek(by: -10)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    state.togglePlay()
                }
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background {
                        Circle()
                            .fill(.white.opacity(0.13))
                            .overlay {
                                Circle()
                                    .stroke(.white.opacity(0.22), lineWidth: 1)
                            }
                    }
                    .shadow(color: accentColor.opacity(0.22), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            iconButton("goforward.10") {
                state.seek(by: 10)
            }
        }
    }

    private var optionsBar: some View {
        HStack(spacing: 7) {
            interpolationButton
            qualityButton
            speedButton

            if state.audioTracks.count > 1 {
                audioTrackButton
            }

            subtitleButton
        }
        .padding(4)
        .background {
            Capsule()
                .fill(.white.opacity(0.045))
        }
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var interpolationButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                guard state.interpolationMode == .disabled else {
                    state.setInterpolationMode(.disabled)
                    return
                }
                state.setInterpolationMode(.motion2Intense)
            }
        } label: {
            optionPill(
                title: motionTitle,
                systemName: state.isFramePlusPreparing ? "hourglass" : (state.interpolationMode == .disabled ? "plus.circle" : "plus.circle.fill"),
                isActive: state.interpolationMode != .disabled
            )
        }
        .buttonStyle(.plain)
    }

    private var qualityButton: some View {
        Menu {
            ForEach(VideoInterpolationPipeline.QualityMode.allCases, id: \.self) { mode in
                Button {
                    state.setQualityMode(mode)
                } label: {
                    optionMenuRow(title: mode.displayName, selected: state.qualityMode == mode)
                }
            }
        } label: {
            optionPill(
                title: state.qualityMode.displayName,
                systemName: "camera.filters",
                isActive: state.placeboEnabled
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var speedButton: some View {
        Button {
            state.cyclePlaybackRate()
        } label: {
            optionPill(
                title: speedTitle,
                systemName: "speedometer",
                isActive: state.playbackRate != 1.0
            )
        }
        .buttonStyle(.plain)
    }

    private var audioTrackButton: some View {
        let activeLabel = state.audioTracks.indices.contains(state.selectedAudioTrackIndex)
            ? state.audioTracks[state.selectedAudioTrackIndex].label
            : "Audio"

        return Menu {
            ForEach(state.audioTracks) { track in
                Button {
                    state.selectAudioTrack(track.id)
                } label: {
                    optionMenuRow(title: track.label, selected: track.id == state.selectedAudioTrackIndex)
                }
            }
        } label: {
            optionPill(
                title: activeLabel,
                systemName: "person.wave.2",
                isActive: state.selectedAudioTrackIndex != 0
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var subtitleButton: some View {
        let subtitleTracks = state.availableTracks.filter { $0.kind == .subtitle }

        return Menu {
            Button {
                state.selectPipelineTrack(nil)
            } label: {
                optionMenuRow(title: "None", selected: state.selectedSubtitleTrack == nil)
            }

            ForEach(subtitleTracks) { track in
                Button {
                    state.selectPipelineTrack(track)
                } label: {
                    optionMenuRow(title: track.label, selected: state.selectedSubtitleTrack == track)
                }
            }
        } label: {
            optionPill(
                title: state.selectedSubtitleTrack?.label ?? "Subs",
                systemName: "captions.bubble",
                isActive: state.selectedSubtitleTrack != nil
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func optionPill(title: String, systemName: String, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14)

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(isActive ? .white : .white.opacity(0.76))
        .frame(width: 96, height: 28)
        .background {
            Capsule()
                .fill(isActive ? accentColor.opacity(0.22) : .white.opacity(0.04))
        }
        .overlay {
            Capsule()
                .stroke(isActive ? accentColor.opacity(0.36) : .white.opacity(0.10), lineWidth: 1)
        }
        .contentShape(Capsule())
    }

    private func optionMenuRow(title: String, selected: Bool) -> some View {
        Group {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(.white.opacity(0.045))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var optionDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 24)
    }

    private var accentColor: Color {
        Color(red: 0.36, green: 0.66, blue: 1.0)
    }

    private var volumeIcon: String {
        switch state.volume {
        case 0: "speaker.slash.fill"
        case 0..<0.45: "speaker.wave.1.fill"
        default: "speaker.wave.2.fill"
        }
    }

    private var speedTitle: String {
        let value = Double(state.playbackRate)
        return value == 1 ? "1x" : String(format: "%.2gx", value)
    }

    private var motionTitle: String {
        state.isFramePlusPreparing ? "Frame⁺..." : "Frame⁺"
    }

    private var framePlusStateTitle: String {
        if state.isFramePlusPreparing { return "Preparando" }
        if state.isFramePlusPreRendered { return "60fps listo" }
        return state.interpolationMode == .disabled ? "Desactivado" : "Activado"
    }
}
