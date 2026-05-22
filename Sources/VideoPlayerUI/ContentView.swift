import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var state = PlayerState()
    @State private var isDropTargeted = false

    // Control visibility and hover states for premium auto-hide behavior
    @State private var areControlsVisible = true
    @State private var isHoveringControls = false
    @State private var hideControlsTask: Task<Void, Never>? = nil
    @State private var mouseEventMonitor: Any? = nil

    var body: some View {
        ZStack {
            appBackdrop

            if state.hasVideo {
                Group {
                    if state.interpolationMode == .disabled {
                        NativeVideoPlayerView(player: state.player)
                            .onAppear {
                                state.currentRenderingFPS = state.displayRenderingFPS
                                state.isArtificialInterpolationActive = false
                                state.fluxWorkingWidth = nil
                                state.fluxOpticalFlowUsage = 0
                                state.fluxBlendFallbackUsage = 0
                            }
                    } else {
                        VideoPlayerView(
                            player: state.player,
                            fpsMode: state.fpsMode,
                            interpolationMode: state.interpolationMode,
                            sourceFrameRate: state.sourceFrameRate
                        ) { stats in
                            state.currentRenderingFPS = stats.renderingFPS
                            state.isArtificialInterpolationActive = stats.isArtificialInterpolationActive
                            state.fluxWorkingWidth = stats.fluxWorkingWidth
                            state.fluxOpticalFlowUsage = stats.opticalFlowUsage
                            state.fluxBlendFallbackUsage = stats.blendFallbackUsage
                            state.rifeStatus = stats.rifeStatus
                            state.isRIFELoaded = stats.isRIFELoaded
                            state.rifeEnabled = stats.isRIFELoaded && state.interpolationMode != .disabled && state.interpolationMode != .motion2Intense
                            if !stats.isRIFELoaded && state.interpolationMode != .disabled && state.interpolationMode != .motion2Intense {
                                state.interpolationMode = .disabled
                                state.fpsMode = .native
                            }
                        }
                    }
                }
                .ignoresSafeArea()
                .overlay(videoVignette)
                .transition(.opacity.combined(with: .scale(scale: 1.01)))

                VStack {
                    HStack {
                        statsHUD
                            .padding(.leading, 22)
                            .padding(.top, 22)

                        Spacer()
                    }

                    Spacer()
                }
            }

            if !state.hasVideo {
                openVideoPrompt
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            VStack {
                Spacer()

                ZStack {
                    controlsContrastField

                    PlayerControlsView(state: state)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 34)
                .opacity(areControlsVisible ? 1.0 : 0.0)
                .offset(y: areControlsVisible ? 0 : 12)
                .onHover { hovering in
                    isHoveringControls = hovering
                    resetHideTimer()
                }
            }
        }
        .background(appBackdrop)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(.easeInOut(duration: 0.24), value: state.hasVideo)
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .onAppear {
            setupMouseMonitor()
        }
        .onDisappear {
            cleanupMouseMonitor()
            state.cleanup()
        }
        .onChange(of: state.isPlaying) {
            resetHideTimer()
        }
    }

    private func setupMouseMonitor() {
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { event in
            resetHideTimer()
            return event
        }
    }

    private func cleanupMouseMonitor() {
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        hideControlsTask?.cancel()
        hideControlsTask = nil
        NSCursor.unhide()
    }

    private func resetHideTimer() {
        if !areControlsVisible {
            withAnimation(.easeInOut(duration: 0.22)) {
                areControlsVisible = true
            }
            NSCursor.unhide()
        }

        hideControlsTask?.cancel()

        guard state.hasVideo && state.isPlaying else { return }
        guard !isHoveringControls else { return }

        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            
            withAnimation(.easeInOut(duration: 0.32)) {
                areControlsVisible = false
            }
            NSCursor.hide()
        }
    }

    private var appBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.045, blue: 0.105),
                    Color(red: 0.025, green: 0.090, blue: 0.210),
                    Color(red: 0.010, green: 0.030, blue: 0.075)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.18, green: 0.38, blue: 0.82).opacity(0.34),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 80,
                endRadius: 740
            )

            RadialGradient(
                colors: [
                    Color(red: 0.04, green: 0.18, blue: 0.46).opacity(0.50),
                    .clear
                ],
                center: .center,
                startRadius: 140,
                endRadius: 780
            )
        }
        .ignoresSafeArea()
    }

    private var openVideoPrompt: some View {
        Button {
            state.openVideo()
        } label: {
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 27, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.14), .blue.opacity(0.05)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 27, style: .continuous)
                                .stroke(.white.opacity(isDropTargeted ? 0.42 : 0.18), lineWidth: 1)
                        }

                    Image(systemName: "folder")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.42, green: 0.70, blue: 1.0),
                                    Color(red: 0.16, green: 0.48, blue: 0.95)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 142, height: 130)
                .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 18)

                VStack(spacing: 12) {
                    Text("Abrir video")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))

                    Text("Arrastra un archivo de video aqui\no haz clic para seleccionar")
                        .font(.system(size: 19, weight: .regular))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(0.66))

                    if let statusMessage = state.statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(red: 0.40, green: 0.66, blue: 1.0))
                            .padding(.top, 4)
                    }
                }
            }
            .scaleEffect(isDropTargeted ? 1.04 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 130)
    }

    private var videoVignette: some View {
        LinearGradient(
            colors: [
                .black.opacity(0.18),
                .clear,
                .black.opacity(0.55)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var controlsContrastField: some View {
        LinearGradient(
            colors: [
                .clear,
                Color(red: 0.04, green: 0.05, blue: 0.18).opacity(0.16),
                .black.opacity(0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: 880, maxHeight: 120)
        .blur(radius: 18)
        .allowsHitTesting(false)
    }

    private var statsHUD: some View {
        LiquidGlassPanel(cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("HUD")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))

                Text("Dibujo \(String(format: "%.0f", state.displayRenderingFPS)) FPS")
                    .font(.system(size: 12, weight: .medium))

                if let sourceFrameRate = state.sourceFrameRate {
                    Text("Fuente \(String(format: "%.2f", sourceFrameRate)) FPS")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Text("Frame⁺ \(framePlusHUDState)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state.interpolationMode != .disabled ? Color(red: 0.42, green: 0.70, blue: 1.0) : .white.opacity(0.68))

                if state.fpsMode == .flux {
                    Text(state.rifeStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(state.isRIFELoaded ? Color(red: 0.42, green: 0.70, blue: 1.0) : .white.opacity(0.70))

                    Text("MEMC \(String(format: "%.0f", state.fluxOpticalFlowUsage * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(state.fluxOpticalFlowUsage > 0.5 ? Color(red: 0.42, green: 0.70, blue: 1.0) : .white.opacity(0.70))

                    if let fluxWorkingWidth = state.fluxWorkingWidth {
                        Text("Interno \(fluxWorkingWidth)p")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                }

                if shouldShowRIFEWarning {
                    Text("RIFE NO INSTALADO")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.58, blue: 0.34))
                }

                if let videoResolution = state.videoResolution {
                    Text(videoResolution)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.70))
                }
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 148, alignment: .leading)
        .allowsHitTesting(false)
    }

    private var framePlusHUDState: String {
        if state.isFramePlusPreparing { return "Preparando" }
        if state.isFramePlusPreRendered { return "60fps listo" }
        return state.interpolationMode == .disabled ? "Desactivado" : "Activado"
    }

    private var shouldShowRIFEWarning: Bool {
        !state.isRIFELoaded && state.interpolationMode != .disabled && state.interpolationMode != .motion2Intense
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let droppedURL: URL?

            if let data = item as? Data {
                droppedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                droppedURL = url
            } else if let string = item as? String {
                droppedURL = URL(string: string)
            } else {
                droppedURL = nil
            }

            guard let droppedURL else { return }

            Task { @MainActor in
                state.loadVideo(droppedURL)
            }
        }

        return true
    }
}
