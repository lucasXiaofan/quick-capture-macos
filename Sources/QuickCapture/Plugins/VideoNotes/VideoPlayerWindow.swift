import AVKit
import AppKit

/// A small floating player: opens, waits half a second, then starts playing. Esc closes it.
@MainActor
final class VideoPlayerWindow: NSObject, NSWindowDelegate {
    private var panel: KeyPanel?
    private let playerView = AVPlayerView()
    private var boost: VideoGain?

    /// Playback volume on top of the system volume: 1 = as recorded, 2 = twice as loud. Applies to the open video too.
    var gain: Float = 1 {
        didSet { boost?.gain = gain }
    }

    func play(_ url: URL, title: String) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let boost = VideoGain(gain: gain)
        self.boost = boost
        Task { item.audioMix = await boost.audioMix(for: item.asset) }
        playerView.player = player
        let panel = panel ?? makePanel()
        panel.title = title
        if !panel.isVisible { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.panel?.isVisible == true, self.playerView.player === player else { return }
            player.play()
        }
    }

    func close() {
        playerView.player?.pause()
        playerView.player = nil
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { playerView.player?.pause() }

    private func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 428),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = playerView
        p.onKey = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            self?.close()
            return true
        }
        panel = p
        return p
    }
}
