import AppKit

/// Floating, non-activating panel that mirrors the web UI's dictation
/// overlay: live cumulative transcript while recording, then the final and
/// polished text, fading out after delivery. Never steals focus — the
/// user's cursor stays wherever the text will land.
@MainActor
final class PreviewHUD {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 60),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10

        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 5
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        panel.contentView = container
    }

    func show(_ text: String) {
        generation += 1
        label.stringValue = text
        guard let screen = NSScreen.main else { return }
        let width: CGFloat = min(560, screen.visibleFrame.width - 80)
        let fit = label.sizeThatFits(NSSize(width: width - 28, height: 400))
        let height = fit.height + 20
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2,
                              y: screen.visibleFrame.maxY - height - 24,
                              width: width, height: height),
                       display: true)
        panel.orderFrontRegardless()
    }

    /// Hide after a delay, unless something newer has been shown since.
    func hide(after seconds: Double = 0) {
        generation += 1
        let gen = generation
        if seconds <= 0 {
            panel.orderOut(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.panel.orderOut(nil)
        }
    }
}
