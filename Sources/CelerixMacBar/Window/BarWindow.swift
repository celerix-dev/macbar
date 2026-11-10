import AppKit

final class BarWindow: NSWindow {
    override var canBecomeKey: Bool { isDropdownOpen || isSettingsPopoverOpen }
    override var canBecomeMain: Bool { false }

    private let barHeight: CGFloat
    private var isShiftedDown = false
    private var isDropdownOpen = false
    private var isSettingsPopoverOpen = false
    private var dropdownHeight: CGFloat = 480.0
    private var dropdownWidth: CGFloat = 360.0
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    var onSettingsPopoverDismissRequested: (() -> Void)?
    var onDropdownDismissRequested: (() -> Void)?

    init(height: CGFloat = 38.0) {
        self.barHeight = height
        let screenRect = NSScreen.main?.frame ?? .zero
        let frame = NSRect(
            x: screenRect.minX,
            y: screenRect.maxY - height,
            width: screenRect.width,
            height: height
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Sits just below the native menu bar level
        level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true

        startMouseProximityMonitor()
    }

    private func startMouseProximityMonitor() {
        // Global monitor checks mouse location even when outside your window
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.evaluateMousePosition()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(at: NSEvent.mouseLocation)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func handleOutsideClick(at point: NSPoint) {
        guard isDropdownOpen || isSettingsPopoverOpen else { return }

        let clickedAnotherWindow = NSApp.windows.contains {
            $0 !== self && $0.isVisible && $0.frame.contains(point)
        }
        guard !clickedAnotherWindow else { return }

        if isDropdownOpen && !dropdownPanelFrame.contains(point) {
            onDropdownDismissRequested?()
        }

        if isSettingsPopoverOpen && !frame.contains(point) {
            onSettingsPopoverDismissRequested?()
            setSettingsPopoverOpen(false)
        }
    }

    private var dropdownPanelFrame: NSRect {
        NSRect(
            x: frame.minX + 8,
            y: frame.maxY - 38 - 4 - dropdownHeight,
            width: dropdownWidth,
            height: dropdownHeight
        )
    }

    private func evaluateMousePosition() {
        guard isVisible else { return }
        guard let screen = NSScreen.main else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screenTop = screen.frame.maxY
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        let nativeMenuBarHeight: CGFloat = topInset > 0 ? topInset : 28.0
        let currentEffectiveHeight = isDropdownOpen ? (barHeight + dropdownHeight) : barHeight

        // If the mouse hits the very top 2 pixels, the native menu bar is triggering
        if mouseLocation.y >= screenTop - 2 {
            if !isShiftedDown {
                animateTo(yOffset: nativeMenuBarHeight)
                isShiftedDown = true
            }
        }
        // Once the mouse leaves both the native bar AND your custom bar / dropdown, slide back up
        else if mouseLocation.y < screenTop - (nativeMenuBarHeight + currentEffectiveHeight + 10) {
            if isShiftedDown {
                animateTo(yOffset: 0)
                isShiftedDown = false
            }
        }
    }

    private func animateTo(yOffset: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let effectiveHeight = isDropdownOpen ? (barHeight + dropdownHeight) : barHeight
        let targetY = screen.frame.maxY - effectiveHeight - yOffset

        let targetRect = NSRect(
            x: screen.frame.minX,
            y: targetY,
            width: screen.frame.width,
            height: effectiveHeight
        )

        NSAnimationContext.runAnimationGroup { context in
            // 0.2s with easeOut closely tracks the native menu bar slide speed
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            self.animator().setFrame(targetRect, display: true)
        }
    }

    func setDropdownOpen(_ isOpen: Bool, height: CGFloat = 480.0, width: CGFloat = 360.0) {
        self.isDropdownOpen = isOpen
        self.dropdownHeight = height
        self.dropdownWidth = width
        guard let screen = NSScreen.main else { return }
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        let nativeMenuBarHeight: CGFloat = topInset > 0 ? topInset : 28.0
        let currentYOffset = isShiftedDown ? nativeMenuBarHeight : 0
        let effectiveHeight = isOpen ? (barHeight + height) : barHeight
        let targetY = screen.frame.maxY - effectiveHeight - currentYOffset

        let targetRect = NSRect(
            x: screen.frame.minX,
            y: targetY,
            width: screen.frame.width,
            height: effectiveHeight
        )

        setFrame(targetRect, display: true)
        if isOpen || isSettingsPopoverOpen {
            makeKey()
        } else {
            resignKey()
        }
    }

    func setSettingsPopoverOpen(_ isOpen: Bool) {
        isSettingsPopoverOpen = isOpen
        if isOpen {
            makeKey()
        } else if !isDropdownOpen {
            resignKey()
        }
    }

    func updatePosition(height: CGFloat = 44.0) {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.frame
        let effectiveHeight = isDropdownOpen ? (height + dropdownHeight) : height
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        let nativeMenuBarHeight: CGFloat = topInset > 0 ? topInset : 28.0
        let currentYOffset = isShiftedDown ? nativeMenuBarHeight : 0
        let frame = NSRect(
            x: screenRect.minX,
            y: screenRect.maxY - effectiveHeight - currentYOffset,
            width: screenRect.width,
            height: effectiveHeight
        )
        setFrame(frame, display: true)
    }

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
