import SwiftUI
import AppKit

/// What the controls drawn over the video show, and what they do. Owned by `PlayerView`; the
/// views render inside AVKit's content overlay (see `PlayerOverlayHost`).
@MainActor
final class PlayerOverlayModel: ObservableObject {
    struct SkipPrompt: Equatable {
        enum Kind { case intro, credits }
        let kind: Kind
        /// Seconds until the automatic skip, or nil for a manual button (auto-skip off).
        let remaining: Int?
    }

    @Published var isSeries = false
    @Published var title = ""
    @Published var episodeLabel: String?
    @Published var canPrevious = false
    @Published var canNext = false
    @Published var sections: [EpisodeMenuSection] = []
    @Published var autoSkip = true
    @Published var skip: SkipPrompt?
    @Published private(set) var toast: String?
    @Published private(set) var controlsVisible = false

    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onSelect: (EpisodeRef) -> Void = { _ in }
    var onSkipNow: () -> Void = {}
    var onCancelSkip: () -> Void = {}
    var onToggleAutoSkip: (Bool) -> Void = { _ in }

    private var hideControls: Task<Void, Never>?
    private var hideToast: Task<Void, Never>?

    /// Pointer activity over the video: show the controls, and hide them again after a few idle
    /// seconds, in step with AVKit's own.
    func pointerMoved() {
        if !controlsVisible { controlsVisible = true }
        hideControls?.cancel()
        hideControls = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    func pointerExited() {
        hideControls?.cancel()
        controlsVisible = false
    }

    func showToast(_ text: String) {
        toast = text
        hideToast?.cancel()
        hideToast = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Drop the action closures — they capture the player view, which owns this model.
    func detach() {
        onPrevious = {}; onNext = {}; onSelect = { _ in }
        onSkipNow = {}; onCancelSkip = {}; onToggleAutoSkip = { _ in }
        hideControls?.cancel(); hideToast?.cancel()
    }
}

struct EpisodeMenuSection: Identifiable {
    let season: Int
    let items: [EpisodeMenuItem]
    var id: Int { season }
}

struct EpisodeMenuItem: Identifiable {
    let ref: EpisodeRef
    let current: Bool
    let watched: Bool
    var id: EpisodeRef { ref }
}

// MARK: - Hosting

/// Installs the overlay into AVKit's `contentOverlayView` — between the video and AVKit's own
/// controls. That view travels with the player into AVKit's full-screen window, so these controls
/// keep working there (a SwiftUI overlay on top of the player would stay behind in the normal
/// window). Each piece gets its own content-sized hosting view so the rest of the video stays
/// AVKit's to click.
@MainActor
enum PlayerOverlayHost {
    static func install(in container: NSView, model: PlayerOverlayModel) {
        let root = PointerTrackingView(frame: container.bounds)
        root.autoresizingMask = [.width, .height]
        root.onMove = { @MainActor [weak model] in model?.pointerMoved() }
        root.onExit = { @MainActor [weak model] in model?.pointerExited() }
        container.addSubview(root)

        func host<V: View>(_ view: V) -> NSView {
            let h = NSHostingView(rootView: view)
            h.sizingOptions = [.intrinsicContentSize]
            h.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(h)
            return h
        }
        let bar = host(PlayerEpisodeBar(model: model))
        let skip = host(PlayerSkipPrompt(model: model))
        let toast = host(PlayerToast(model: model))
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -24),
            // Bottom-right, clear of AVKit's control bar.
            skip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            skip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -84),
            toast.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -84),
        ])
    }
}

/// Full-size, click-transparent layer that reports pointer movement (to reveal the controls)
/// while letting every click fall through to AVKit — only the hosted controls take clicks.
final class PointerTrackingView: NSView {
    var onMove: (@MainActor () -> Void)?
    var onExit: (@MainActor () -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onMove?(); super.mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { onMove?(); super.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { onExit?(); super.mouseExited(with: event) }
}

// MARK: - Views

/// Top-centre bar for series: previous · episode list · next, plus the auto-skip switch.
/// Fades in with pointer activity like AVKit's own controls; the ⇧⌘←/→ shortcuts work even
/// while it's hidden.
struct PlayerEpisodeBar: View {
    @ObservedObject var model: PlayerOverlayModel

    var body: some View {
        if model.isSeries {
            HStack(spacing: 2) {
                barButton("backward.end.fill", enabled: model.canPrevious) { model.onPrevious() }
                    .help("Previous episode (⇧⌘←)")
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])

                Menu {
                    episodeMenu
                } label: {
                    Text(verbatim: label)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(maxWidth: 360)
                .padding(.horizontal, 6)
                .help("All episodes")

                barButton("forward.end.fill", enabled: model.canNext) { model.onNext() }
                    .help("Next episode (⇧⌘→)")
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])

                Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 18)
                    .padding(.horizontal, 6)

                Button { model.onToggleAutoSkip(!model.autoSkip) } label: {
                    Label("Auto-skip", systemImage: model.autoSkip ? "forward.frame.fill" : "forward.frame")
                        .font(.caption.weight(.semibold))
                        .opacity(model.autoSkip ? 1 : 0.5)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.autoSkip ? "Skipping intros and credits automatically — click to turn off"
                                     : "Auto-skip is off — click to skip intros and credits automatically")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(.black.opacity(0.62), in: Capsule())
            .environment(\.colorScheme, .dark)
            .opacity(model.controlsVisible ? 1 : 0)
            .allowsHitTesting(model.controlsVisible)
            .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        }
    }

    private var label: String {
        guard let tag = model.episodeLabel else { return model.title }
        return model.title.isEmpty ? tag : "\(model.title) · \(tag)"
    }

    @ViewBuilder private var episodeMenu: some View {
        if model.sections.count > 1 {
            ForEach(model.sections) { s in
                Menu("Season \(s.season)") { items(s.items) }
            }
        } else if let only = model.sections.first {
            items(only.items)
        }
    }

    @ViewBuilder private func items(_ list: [EpisodeMenuItem]) -> some View {
        ForEach(list) { it in
            Button { model.onSelect(it.ref) } label: {
                if it.current {
                    Label("Episode \(it.ref.episode)", systemImage: "play.fill")
                } else if it.watched {
                    Label("Episode \(it.ref.episode)", systemImage: "checkmark")
                } else {
                    Text("Episode \(it.ref.episode)")
                }
            }
        }
    }

    private func barButton(_ icon: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// "Skipping intro in 3…" countdown (or a plain Skip button when auto-skip is off).
struct PlayerSkipPrompt: View {
    @ObservedObject var model: PlayerOverlayModel

    var body: some View {
        Group {
            if let p = model.skip {
                HStack(spacing: 10) {
                    if let r = p.remaining {
                        Group {
                            if p.kind == .intro { Text("Skipping intro in \(r)…") }
                            else { Text("Next episode in \(r)…") }
                        }
                        .font(.callout.weight(.semibold)).monospacedDigit()

                        Button(p.kind == .intro ? "Skip Now" : "Play Now") { model.onSkipNow() }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { model.onCancelSkip() }
                            .buttonStyle(.bordered)
                    } else {
                        Button { model.onSkipNow() } label: {
                            Label(p.kind == .intro ? "Skip Intro" : "Next Episode",
                                  systemImage: "forward.fill")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(.black.opacity(0.72), in: Capsule())
                .environment(\.colorScheme, .dark)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.skip)
    }
}

/// Short-lived notice ("Playing S1E3…", "Skipped intro", AirPlay state).
struct PlayerToast: View {
    @ObservedObject var model: PlayerOverlayModel

    var body: some View {
        Group {
            if let text = model.toast {
                Text(verbatim: text)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.7), in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.toast)
    }
}
