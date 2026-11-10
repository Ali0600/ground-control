import AppKit
import GroundControlCore

/// The native screen shown whenever the dashboard is not: while it loads, while a start
/// or restart is under way, and when nothing answers. Without it a dead server is a blank
/// window — the one failure this app exists to make visible.
@MainActor
final class OfflineView: NSView {
    var onAction: ((ServerAction) -> Void)?
    var onRetry: (() -> Void)?
    var onShowLog: (() -> Void)?

    private let icon = NSImageView()
    private let titleLabel = OfflineView.label(size: 22, weight: .semibold, color: Palette.text)
    private let detailLabel = OfflineView.label(size: 14, weight: .regular, color: Palette.secondaryText)
    private let reasonLabel = OfflineView.label(size: 12, weight: .regular, color: Palette.muted)
    private let noteLabel = OfflineView.label(size: 12, weight: .regular, color: Palette.warn)
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let logButton = NSButton(title: "Show Server Log", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusLabel = OfflineView.label(size: 12, weight: .regular, color: Palette.muted)
    private var action: ServerAction?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.background.cgColor
        appearance = NSAppearance(named: .darkAqua)

        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])

        for button in [actionButton, logButton, retryButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.target = self
        }
        actionButton.action = #selector(actionPressed)
        logButton.action = #selector(logPressed)
        retryButton.action = #selector(retryPressed)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let buttons = NSStackView(views: [actionButton, logButton, retryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let status = NSStackView(views: [spinner, statusLabel])
        status.orientation = .horizontal
        status.spacing = 6

        let stack = NSStackView(views: [icon, titleLabel, detailLabel, reasonLabel, noteLabel, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: icon)
        stack.setCustomSpacing(20, after: noteLabel)
        stack.setCustomSpacing(16, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
        for wrapping in [detailLabel, reasonLabel, noteLabel] {
            wrapping.preferredMaxLayoutWidth = 480
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("OfflineView is built in code") }

    /// The first load, and every reload that follows an outage.
    func showConnecting(_ endpoint: ServerEndpoint) {
        render(
            title: "Connecting to Ground Control\u{2026}",
            detail: "Loading the dashboard from \(endpoint.authority).",
            busy: "")
    }

    /// After Start or Restart: the command ran, the server is on its way.
    func showStarting(_ message: String) {
        render(title: message, detail: "Waiting for the server to answer\u{2026}", busy: "")
    }

    func showUnreachable(
        endpoint: ServerEndpoint, reason: String?, advice: OfflineAdvice?, note: String?,
        logAvailable: Bool
    ) {
        var detail = "Nothing answered at \(endpoint.authority)."
        if let advice { detail += " " + advice.detail }
        render(
            title: "Ground Control isn\u{2019}t answering",
            detail: detail,
            reason: reason.map { "Last error: \($0)" },
            note: note,
            action: advice?.action,
            showLog: logAvailable,
            showRetry: true,
            busy: "Checking again every few seconds.")
    }

    private func render(
        title: String, detail: String, reason: String? = nil, note: String? = nil,
        action: ServerAction? = nil, showLog: Bool = false, showRetry: Bool = false,
        busy: String
    ) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        reasonLabel.stringValue = reason ?? ""
        reasonLabel.isHidden = reason == nil
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil

        self.action = action
        actionButton.title = action?.buttonTitle ?? ""
        actionButton.isHidden = action == nil
        logButton.isHidden = !showLog
        retryButton.isHidden = !showRetry
        // Return presses the most useful button on screen.
        actionButton.keyEquivalent = action == nil ? "" : "\r"
        retryButton.keyEquivalent = action == nil && showRetry ? "\r" : ""

        // Always spinning: a screen that says "not answering" and then sits still reads
        // as frozen, when the app is in fact checking again every few seconds.
        spinner.startAnimation(nil)
        statusLabel.stringValue = busy
        statusLabel.isHidden = busy.isEmpty
    }

    @objc private func actionPressed() {
        if let action { onAction?(action) }
    }

    @objc private func logPressed() { onShowLog?() }
    @objc private func retryPressed() { onRetry?() }

    private static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.isSelectable = true
        return label
    }
}
