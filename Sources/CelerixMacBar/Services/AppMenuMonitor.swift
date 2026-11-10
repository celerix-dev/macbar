import AppKit
import ApplicationServices

public struct MenuItemData: Codable {
    public let id: String
    public let title: String
    public let isSeparator: Bool
    public let isEnabled: Bool
    public let shortcut: String?
    public let children: [MenuItemData]?
}

public struct TopLevelMenuData: Codable {
    public let id: String
    public let title: String
    public let isEnabled: Bool
    public let items: [MenuItemData]
}

public struct ActiveAppData: Codable {
    public let name: String
    public let bundleIdentifier: String?
    public let pid: Int32
    public let iconBase64: String?
    public let menus: [TopLevelMenuData]
    public let isAccessibilityTrusted: Bool
    public let hasVisibleWindows: Bool
}

final class AppMenuMonitor {
    static let shared = AppMenuMonitor()

    private(set) var activeAppPID: pid_t = 0
    private var elementRegistry: [String: AXUIElement] = [:]
    private let registryQueue = DispatchQueue(label: "com.celerix.macbar.menu.registry")

    var currentPID: pid_t {
        if activeAppPID != 0 {
            return activeAppPID
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != NSRunningApplication.current.processIdentifier {
            return front.processIdentifier
        }
        return 0
    }

    private var observers: [UUID: (ActiveAppData) -> Void] = [:]
    private let observersLock = NSLock()

    @discardableResult
    func addObserver(_ observer: @escaping (ActiveAppData) -> Void) -> UUID {
        let id = UUID()
        observersLock.lock()
        observers[id] = observer
        observersLock.unlock()
        observer(fetchActiveAppData())
        return id
    }

    func removeObserver(_ id: UUID) {
        observersLock.lock()
        observers.removeValue(forKey: id)
        observersLock.unlock()
    }

    var onActiveAppChanged: ((ActiveAppData) -> Void)? {
        didSet {
            if let onActiveAppChanged = onActiveAppChanged {
                _ = addObserver(onActiveAppChanged)
            }
        }
    }

    private init() {
        setupWorkspaceNotifications()
        updateFrontmostApplication()
    }

    private func setupWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidDeactivate(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil
        )
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        handleAppActivation(app)
    }

    @objc private func applicationDidDeactivate(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateFrontmostApplication()
        }
    }

    func updateFrontmostApplication() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        handleAppActivation(frontApp)
    }

    private func handleAppActivation(_ app: NSRunningApplication) {
        // Ignore our own application if activated
        if app.bundleIdentifier == Bundle.main.bundleIdentifier || app.processIdentifier == NSRunningApplication.current.processIdentifier {
            return
        }

        activeAppPID = app.processIdentifier
        let data = fetchActiveAppData(for: app)
        observersLock.lock()
        let currentObservers = Array(observers.values)
        observersLock.unlock()
        for observer in currentObservers {
            observer(data)
        }
    }

    func fetchActiveAppData(for app: NSRunningApplication? = nil) -> ActiveAppData {
        let targetApp: NSRunningApplication
        if let app = app {
            targetApp = app
        } else if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != NSRunningApplication.current.processIdentifier {
            targetApp = front
        } else if let running = NSRunningApplication(processIdentifier: activeAppPID) {
            targetApp = running
        } else if let fallback = NSWorkspace.shared.frontmostApplication {
            targetApp = fallback
        } else {
            return ActiveAppData(
                name: "Finder",
                bundleIdentifier: "com.apple.finder",
                pid: 0,
                iconBase64: nil,
                menus: [],
                isAccessibilityTrusted: AXIsProcessTrusted(),
                hasVisibleWindows: false
            )
        }

        let name = targetApp.localizedName ?? targetApp.bundleIdentifier ?? "Application"
        let bundleId = targetApp.bundleIdentifier
        let pid = targetApp.processIdentifier
        let iconBase64 = getAppIconBase64(for: targetApp)
        let isTrusted = AXIsProcessTrusted()
        let hasWindows = RunningAppsMonitor.shared.hasVisibleWindows(pid: pid)

        let menus = isTrusted ? extractMenus(for: pid) : []

        return ActiveAppData(
            name: name,
            bundleIdentifier: bundleId,
            pid: pid,
            iconBase64: iconBase64,
            menus: menus,
            isAccessibilityTrusted: isTrusted,
            hasVisibleWindows: hasWindows
        )
    }

    private func getAppIconBase64(for app: NSRunningApplication) -> String? {
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

    // MARK: - Menu Extraction

    private func extractMenus(for pid: pid_t) -> [TopLevelMenuData] {
        var newRegistry: [String: AXUIElement] = [:]
        var result: [TopLevelMenuData] = []

        let axApp = AXUIElementCreateApplication(pid)
        var menuBarValue: AnyObject?
        let copyRes = AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarValue)

        guard copyRes == .success, let menuBar = menuBarValue else {
            return []
        }

        var childrenValue: AnyObject?
        let childRes = AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue)
        guard childRes == .success, let menuBarItems = childrenValue as? [AXUIElement] else {
            return []
        }

        for (index, barItem) in menuBarItems.enumerated() {
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(barItem, kAXTitleAttribute as CFString, &titleValue)
            let title = (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Filter out the Apple Menu
            // Index 0 with empty title, "Apple", or Apple glyph ( \u{F8FF}) is the Apple menu
            if index == 0 && (title.isEmpty || title == "Apple" || title == "\u{F8FF}") {
                continue
            }

            // Also skip if title is Apple symbol
            if title == "\u{F8FF}" || title == "Apple" && index == 0 {
                continue
            }

            let topId = "top_\(index)"
            var isEnabled = true
            var enabledVal: AnyObject?
            if AXUIElementCopyAttributeValue(barItem, kAXEnabledAttribute as CFString, &enabledVal) == .success,
               let num = enabledVal as? NSNumber {
                isEnabled = num.boolValue
            }

            newRegistry[topId] = barItem

            // Each AXMenuBarItem has a child AXMenu containing the actual AXMenuItems
            var subMenuChildrenVal: AnyObject?
            var menuItemsData: [MenuItemData] = []

            if AXUIElementCopyAttributeValue(barItem, kAXChildrenAttribute as CFString, &subMenuChildrenVal) == .success,
               let subMenus = subMenuChildrenVal as? [AXUIElement], let firstMenu = subMenus.first {
                var itemsVal: AnyObject?
                if AXUIElementCopyAttributeValue(firstMenu, kAXChildrenAttribute as CFString, &itemsVal) == .success,
                   let items = itemsVal as? [AXUIElement] {
                    menuItemsData = parseMenuItems(items, prefix: topId, registry: &newRegistry, depth: 0)
                }
            }

            let displayTitle = title.isEmpty ? "Menu" : title
            result.append(TopLevelMenuData(
                id: topId,
                title: displayTitle,
                isEnabled: isEnabled,
                items: menuItemsData
            ))
        }

        registryQueue.sync {
            self.elementRegistry = newRegistry
        }

        return result
    }

    private func parseMenuItems(_ items: [AXUIElement], prefix: String, registry: inout [String: AXUIElement], depth: Int) -> [MenuItemData] {
        var result: [MenuItemData] = []

        for (idx, item) in items.enumerated() {
            let itemId = "\(prefix)_\(idx)"
            registry[itemId] = item

            var roleVal: AnyObject?
            AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &roleVal)
            let role = (roleVal as? String) ?? ""

            var titleVal: AnyObject?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleVal)
            let rawTitle = (titleVal as? String) ?? ""

            // Check if separator
            let isSeparator = role == "AXSeparator" || (rawTitle.isEmpty && role != "AXMenuItem") || (rawTitle == "-" && role == "AXMenuItem")

            var isEnabled = true
            var enabledVal: AnyObject?
            if AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabledVal) == .success,
               let num = enabledVal as? NSNumber {
                isEnabled = num.boolValue
            }

            // Keyboard shortcut
            let shortcut = extractShortcut(from: item)

            // Check for submenus (depth limited to 3 to prevent cyclic/infinite deep trees)
            var childrenData: [MenuItemData]? = nil
            if depth < 3 {
                var childrenVal: AnyObject?
                if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &childrenVal) == .success,
                   let subMenus = childrenVal as? [AXUIElement], let subMenu = subMenus.first {
                    var subItemsVal: AnyObject?
                    if AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &subItemsVal) == .success,
                       let subItems = subItemsVal as? [AXUIElement], !subItems.isEmpty {
                        childrenData = parseMenuItems(subItems, prefix: itemId, registry: &registry, depth: depth + 1)
                    }
                }
            }

            result.append(MenuItemData(
                id: itemId,
                title: rawTitle,
                isSeparator: isSeparator,
                isEnabled: isEnabled,
                shortcut: shortcut,
                children: childrenData
            ))
        }

        return result
    }

    private func extractShortcut(from item: AXUIElement) -> String? {
        var charVal: AnyObject?
        var modVal: AnyObject?

        AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &charVal)
        AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modVal)

        guard let charStr = charVal as? String, !charStr.isEmpty else {
            return nil
        }

        var modifiers = ""
        if let modNum = modVal as? NSNumber {
            let mask = modNum.intValue
            // macOS AX modifier mask values:
            // 0: Cmd (default when not specified)
            // 1: Shift
            // 2: Option
            // 4: Control
            if (mask & 4) != 0 { modifiers += "⌃" }
            if (mask & 2) != 0 { modifiers += "⌥" }
            if (mask & 1) != 0 { modifiers += "⇧" }
            modifiers += "⌘"
        } else {
            modifiers = "⌘"
        }

        return modifiers + charStr.uppercased()
    }

    // MARK: - Action Triggering

    func triggerMenuItem(id: String) -> Bool {
        var targetElement: AXUIElement?
        registryQueue.sync {
            targetElement = elementRegistry[id]
        }

        guard let element = targetElement else {
            print("[AppMenuMonitor] Element with ID \(id) not found in registry")
            return false
        }

        // Activate the target application first so it receives the menu command
        if activeAppPID != 0, let app = NSRunningApplication(processIdentifier: activeAppPID) {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        let pressRes = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressRes == .success {
            return true
        }

        let pickRes = AXUIElementPerformAction(element, "AXPick" as CFString)
        if pickRes == .success {
            return true
        }

        var actionsVal: CFArray?
        if AXUIElementCopyActionNames(element, &actionsVal) == .success,
           let actions = actionsVal as? [String] {
            for action in actions {
                if action == (kAXPressAction as String) || action == "AXPick" || action == "AXPress" {
                    if AXUIElementPerformAction(element, action as CFString) == .success {
                        return true
                    }
                }
            }
        }

        print("[AppMenuMonitor] Failed to perform AXPress on element: \(pressRes.rawValue)")
        return false
    }
}
