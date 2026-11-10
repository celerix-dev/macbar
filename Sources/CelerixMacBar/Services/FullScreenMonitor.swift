import AppKit
import ApplicationServices

final class FullScreenMonitor {
    static let shared = FullScreenMonitor()

    var onFullScreenChanged: ((Bool) -> Void)?
    private(set) var isFullScreenActive: Bool = false

    private var checkTimer: Timer?
    private var workspaceObservers: [Any] = []

    private init() {
        setupObservers()
        checkFullScreenState()
    }

    private func setupObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        let obs1 = wsCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFullScreenState()
        }

        let obs2 = wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFullScreenState()
        }

        let obs3 = wsCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFullScreenState()
        }

        let obs4 = wsCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFullScreenState()
        }

        let obs5 = wsCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFullScreenState()
        }

        let obs6 = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFullScreenState()
        }

        workspaceObservers = [obs1, obs2, obs3, obs4, obs5, obs6]

        // Regular check timer to catch non-notifying transitions (e.g., game transitions, borderless windows)
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFullScreenState()
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    func checkFullScreenState() {
        let active = detectFullScreen()
        if active != isFullScreenActive {
            isFullScreenActive = active
            onFullScreenChanged?(active)
        }
    }

    private func detectFullScreen() -> Bool {
        // 1. Check system presentation options (native macOS fullscreen and kiosk/game modes)
        let app = NSApp ?? NSApplication.shared
        let options = app.currentSystemPresentationOptions
        if options.contains(.fullScreen) {
            return true
        }
        if options.contains(.hideMenuBar) && !options.contains(.autoHideMenuBar) {
            return true
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let myPid = ProcessInfo.processInfo.processIdentifier
        if frontApp.processIdentifier == myPid {
            return false
        }

        // 2. Check frontmost application Accessibility AXFullScreen attributes
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
           let focusedWindow = focusedWindowRef {
            if checkWindowIsFullScreen(window: focusedWindow as! AXUIElement) {
                return true
            }
        }

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for win in windows {
                if checkWindowIsFullScreen(window: win) {
                    return true
                }
            }
        }

        // 3. Check CGWindowList for frontmost application (or topmost on-screen app) window covering the screen
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return false
        }
        let screenWidth = screen.frame.width
        let screenHeight = screen.frame.height

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for win in windowList {
            guard let pid = win[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPid,
                  let layer = win[kCGWindowLayer as String] as? Int,
                  layer >= 0 && layer <= 24, // Normal window levels up to modal/floating
                  let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat,
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat else {
                continue
            }

            // If frontmost app has a window covering the screen, or the topmost non-bar app window covers the screen
            if pid == frontApp.processIdentifier || layer == 0 {
                if w >= (screenWidth - 4) && h >= (screenHeight - 4) && x <= 4 && y <= 4 {
                    return true
                }
            }
        }

        return false
    }

    private func checkWindowIsFullScreen(window: AXUIElement) -> Bool {
        var fullScreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreenRef) == .success {
            if let isFS = fullScreenRef as? Bool, isFS {
                return true
            }
            if let num = fullScreenRef as? NSNumber, num.boolValue {
                return true
            }
        }
        return false
    }

    deinit {
        checkTimer?.invalidate()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
