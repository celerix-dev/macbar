import AppKit

public struct RunningAppItem: Codable, Equatable {
    public let pid: Int32
    public let name: String
    public let bundleIdentifier: String?
    public let iconBase64: String?
    public let isHidden: Bool
    public let hasVisibleWindows: Bool

    public init(pid: Int32, name: String, bundleIdentifier: String?, iconBase64: String?, isHidden: Bool, hasVisibleWindows: Bool) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.iconBase64 = iconBase64
        self.isHidden = isHidden
        self.hasVisibleWindows = hasVisibleWindows
    }
}

final class RunningAppsMonitor {
    static let shared = RunningAppsMonitor()

    private var iconCache: [String: String] = [:]
    private let cacheLock = NSLock()
    private var lastEmittedList: [RunningAppItem] = []

    private var observers: [UUID: ([RunningAppItem]) -> Void] = [:]
    private let observersLock = NSLock()

    @discardableResult
    func addObserver(_ observer: @escaping ([RunningAppItem]) -> Void) -> UUID {
        let id = UUID()
        observersLock.lock()
        observers[id] = observer
        observersLock.unlock()
        observer(fetchRunningApps())
        return id
    }

    func removeObserver(_ id: UUID) {
        observersLock.lock()
        observers.removeValue(forKey: id)
        observersLock.unlock()
    }

    var onRunningAppsChanged: (([RunningAppItem]) -> Void)? {
        didSet {
            if let onRunningAppsChanged = onRunningAppsChanged {
                _ = addObserver(onRunningAppsChanged)
            }
        }
    }

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let notifications = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        for notif in notifications {
            nc.addObserver(
                self,
                selector: #selector(handleWorkspaceChange(_:)),
                name: notif,
                object: nil
            )
        }
    }

    @objc private func handleWorkspaceChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshRunningApps()
        }
    }

    func refreshRunningApps() {
        let apps = fetchRunningApps()
        if apps != lastEmittedList {
            lastEmittedList = apps
            observersLock.lock()
            let currentObservers = Array(observers.values)
            observersLock.unlock()
            for observer in currentObservers {
                observer(apps)
            }
        }
    }

    func fetchRunningApps() -> [RunningAppItem] {
        let activePID = AppMenuMonitor.shared.currentPID
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let myPID = NSRunningApplication.current.processIdentifier

        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            app.processIdentifier != myPID &&
            app.processIdentifier != activePID &&
            app.processIdentifier != frontPID
        }

        let sorted = running.sorted {
            ($0.localizedName ?? $0.bundleIdentifier ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? $1.bundleIdentifier ?? "") == .orderedAscending
        }

        return sorted.map { app in
            let name = app.localizedName ?? app.bundleIdentifier ?? "Application"
            let bundleId = app.bundleIdentifier
            let key = bundleId ?? name

            let icon: String?
            cacheLock.lock()
            if let cached = iconCache[key] {
                icon = cached
                cacheLock.unlock()
            } else {
                cacheLock.unlock()
                let generated = generateIconBase64(for: app)
                if let generated = generated {
                    cacheLock.lock()
                    iconCache[key] = generated
                    cacheLock.unlock()
                }
                icon = generated
            }

            let hasWindows = hasVisibleWindows(pid: app.processIdentifier)

            return RunningAppItem(
                pid: app.processIdentifier,
                name: name,
                bundleIdentifier: bundleId,
                iconBase64: icon,
                isHidden: app.isHidden,
                hasVisibleWindows: hasWindows
            )
        }
    }

    func hasVisibleWindows(pid: pid_t) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for win in windowList {
            if let winPID = win[kCGWindowOwnerPID as String] as? pid_t, winPID == pid {
                if let layer = win[kCGWindowLayer as String] as? Int, layer == 0 {
                    if let bounds = win[kCGWindowBounds as String] as? [String: Any],
                       let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
                       width > 50 && height > 50 {
                        return true
                    }
                }
            }
        }
        return false
    }

    func activateApp(pid: Int32) {
        activateOrReopenApp(pid: pid)
    }

    func activateOrReopenApp(pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return }

        if app.isHidden {
            app.unhide()
        }

        let hasWindows = hasVisibleWindows(pid: pid_t(pid))
        if !hasWindows, let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func generateIconBase64(for app: NSRunningApplication) -> String? {
        guard let icon = app.icon else { return nil }

        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return "data:image/png;base64," + pngData.base64EncodedString()
    }
}
