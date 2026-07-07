import AppKit
import SwiftUI

class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class TerminalPanel: NSPanel {
    private let sessionStore: SessionStore
    private static let collapsedHeight: CGFloat = 44
    private static let defaultExpandedHeight: CGFloat = 400
    private static let defaultWidth: CGFloat = 720
    private static let minWidth: CGFloat = 480
    private static let minExpandedHeight: CGFloat = 300
    private static let savedFrameKey = "panelSavedFrame"
    private var expandedHeight: CGFloat = defaultExpandedHeight
    private var hasRestoredFrame = false

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore

        let savedFrame = Self.loadSavedFrame()
        let initialRect = savedFrame ?? NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultExpandedHeight)

        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        if savedFrame != nil {
            hasRestoredFrame = true
            expandedHeight = initialRect.height
        }

        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        minSize = NSSize(width: Self.minWidth, height: Self.minExpandedHeight)

        let contentView = PanelContentView(
            sessionStore: sessionStore,
            onClose: { [weak self] in self?.hidePanel() },
            onToggleExpand: { [weak self] in self?.handleToggleExpand() }
        )
        let hosting = ClickThroughHostingView(rootView: contentView)
        self.contentView = hosting

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHidePanel),
            name: .NotchyHidePanel,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExpandPanel),
            name: .NotchyExpandPanel,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelFrameChanged),
            name: NSWindow.didMoveNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelFrameChanged),
            name: NSWindow.didEndLiveResizeNotification,
            object: self
        )
    }

    @objc private func panelFrameChanged() {
        // Only persist while expanded — the collapsed frame has a fixed height
        // and a shifted Y origin that we don't want to restore on next launch.
        guard sessionStore.isTerminalExpanded else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.savedFrameKey)
        hasRestoredFrame = true
        expandedHeight = frame.height
    }

    private static func loadSavedFrame() -> NSRect? {
        guard let str = UserDefaults.standard.string(forKey: savedFrameKey), !str.isEmpty else { return nil }
        let rect = NSRectFromString(str)
        guard rect.width >= minWidth, rect.height >= minExpandedHeight else { return nil }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return rect
    }

    func showPanel(below rect: NSRect) {
        let targetScreen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        if let screen = targetScreen, !hasRestoredFrame || !currentFrameIsOn(screen) {
            let panelWidth = frame.width
            let panelHeight = frame.height
            let x = rect.midX - panelWidth / 2
            let y = screen.visibleFrame.maxY - panelHeight
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
    }

    func showPanelCentered(on screen: NSScreen) {
        if !hasRestoredFrame || !currentFrameIsOn(screen) {
            let screenFrame = screen.frame
            let panelWidth = frame.width
            let panelHeight = frame.height
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.maxY - panelHeight
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
    }

    /// True when the majority of the panel's current frame lies on `screen`.
    /// Used to decide whether a saved frame is still valid for the screen the
    /// user is triggering from — after display config changes or when hovering
    /// a different display's notch, the saved frame can be on the wrong screen.
    private func currentFrameIsOn(_ screen: NSScreen) -> Bool {
        let intersection = frame.intersection(screen.frame)
        let panelArea = frame.width * frame.height
        guard panelArea > 0 else { return false }
        return (intersection.width * intersection.height) / panelArea >= 0.5
    }

    func hidePanel() {
        orderOut(nil)
    }

    private func handleToggleExpand() {
        updateOpacity()
        if sessionStore.isTerminalExpanded {
            // Expanding: restore saved height, anchor top edge
            let newHeight = expandedHeight
            var newFrame = frame
            newFrame.origin.y -= (newHeight - frame.height)
            newFrame.size.height = newHeight
            minSize = NSSize(width: 480, height: 300)
            setFrame(newFrame, display: true, animate: false)
        } else {
            // Collapsing: save current height, shrink to tab bar only
            expandedHeight = frame.height
            let newHeight = Self.collapsedHeight
            var newFrame = frame
            newFrame.origin.y += (frame.height - newHeight)
            newFrame.size.height = newHeight
            minSize = NSSize(width: 480, height: Self.collapsedHeight)
            setFrame(newFrame, display: true, animate: false)
        }
    }

    @objc private func handleHidePanel() {
        hidePanel()
    }

    @objc private func handleExpandPanel() {
        handleToggleExpand()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        sessionStore.panelDidBecomeKey()
        updateOpacity()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        if !sessionStore.isPinned && !sessionStore.isShowingDialog && attachedSheet == nil && childWindows?.isEmpty ?? true {
            hidePanel()
        }
        updateOpacity()
    }

    private func updateOpacity() {
        let collapsed = !sessionStore.isTerminalExpanded
        let unfocused = !isKeyWindow
        // Collapsed + unfocused: dim the whole window
        alphaValue = (collapsed && unfocused) ? 0.8 : 1.0
        // Expanded + unfocused: clear window background so SwiftUI chrome
        // transparency shows through (terminal stays opaque via its own view)
        backgroundColor = .clear
    }

    override func sendEvent(_ event: NSEvent) {
        let wasKey = isKeyWindow
        super.sendEvent(event)
        // When the panel wasn't key, the first click just activates the window.
        // Re-send it so SwiftUI controls (tabs, buttons) process the click too.
        if !wasKey && event.type == .leftMouseDown {
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            sessionStore.createCheckpointForActiveSession()
            return true
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "t" {
            sessionStore.createQuickSession()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
