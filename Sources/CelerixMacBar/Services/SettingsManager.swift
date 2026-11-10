import Foundation
import ServiceManagement

struct AppSettings: Codable {
    var launchAtLogin: Bool = false
    var hideOnFullScreen: Bool = true
    var showActiveApp: Bool = true
    var showRunningApps: Bool = true
    var showShortcuts: Bool = true
    var showNowPlaying: Bool = true
    var showWeather: Bool = true
    var showCpu: Bool = true
    var showMemory: Bool = true
    var showVolume: Bool = true
    var showBattery: Bool = true
    var showDateTime: Bool = true
    var clockFormat: String = "24h" // "12h" or "24h"
    var showSeconds: Bool = false
    var temperatureUnit: String = "celsius" // "celsius" or "fahrenheit"
    var showTerminalShortcut: Bool = true
    var showActivityShortcut: Bool = true
    var showFinderShortcut: Bool = true
    var showMuteShortcut: Bool = true
    var showAudioVisualizer: Bool = true
    var enableDevTools: Bool = false
}

final class SettingsManager {
    static let shared = SettingsManager()
    private let userDefaultsKey = "com.celerix.macbar.settings"
    private let launchAgentLabel = "com.celerix.macbar"

    private var observers: [UUID: (AppSettings) -> Void] = [:]
    private let observersLock = NSLock()

    @discardableResult
    func addObserver(_ observer: @escaping (AppSettings) -> Void) -> UUID {
        let id = UUID()
        observersLock.lock()
        observers[id] = observer
        let current = getSettings()
        observersLock.unlock()
        observer(current)
        return id
    }

    func removeObserver(_ id: UUID) {
        observersLock.lock()
        observers.removeValue(forKey: id)
        observersLock.unlock()
    }

    var onSettingsChanged: ((AppSettings) -> Void)? {
        didSet {
            if let onSettingsChanged = onSettingsChanged {
                _ = addObserver(onSettingsChanged)
            }
        }
    }
    private(set) var currentSettings: AppSettings

    private init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.currentSettings = saved
        } else {
            self.currentSettings = AppSettings()
        }

        // Sync actual login item state with system
        self.currentSettings.launchAtLogin = checkLaunchAtLoginStatus()
    }

    func getSettings() -> AppSettings {
        var settings = currentSettings
        settings.launchAtLogin = checkLaunchAtLoginStatus()
        return settings
    }

    func updateSettings(with dictionary: [String: Any]) {
        var settings = currentSettings

        if let val = dictionary["launchAtLogin"] as? Bool {
            settings.launchAtLogin = val
            setLaunchAtLogin(enabled: val)
        }
        if let val = dictionary["hideOnFullScreen"] as? Bool {
            settings.hideOnFullScreen = val
        }
        if let val = dictionary["showActiveApp"] as? Bool {
            settings.showActiveApp = val
        }
        if let val = dictionary["showRunningApps"] as? Bool {
            settings.showRunningApps = val
        }
        if let val = dictionary["showShortcuts"] as? Bool {
            settings.showShortcuts = val
        }
        if let val = dictionary["showNowPlaying"] as? Bool {
            settings.showNowPlaying = val
        }
        if let val = dictionary["showWeather"] as? Bool {
            settings.showWeather = val
        }
        if let val = dictionary["showCpu"] as? Bool {
            settings.showCpu = val
        }
        if let val = dictionary["showMemory"] as? Bool {
            settings.showMemory = val
        }
        if let val = dictionary["showVolume"] as? Bool {
            settings.showVolume = val
        }
        if let val = dictionary["showBattery"] as? Bool {
            settings.showBattery = val
        }
        if let val = dictionary["showDateTime"] as? Bool {
            settings.showDateTime = val
        }
        if let val = dictionary["clockFormat"] as? String {
            settings.clockFormat = val
        }
        if let val = dictionary["showSeconds"] as? Bool {
            settings.showSeconds = val
        }
        if let val = dictionary["temperatureUnit"] as? String {
            settings.temperatureUnit = val
        }
        if let val = dictionary["showTerminalShortcut"] as? Bool {
            settings.showTerminalShortcut = val
        }
        if let val = dictionary["showActivityShortcut"] as? Bool {
            settings.showActivityShortcut = val
        }
        if let val = dictionary["showFinderShortcut"] as? Bool {
            settings.showFinderShortcut = val
        }
        if let val = dictionary["showMuteShortcut"] as? Bool {
            settings.showMuteShortcut = val
        }
        if let val = dictionary["showAudioVisualizer"] as? Bool {
            settings.showAudioVisualizer = val
        }
        if let val = dictionary["enableDevTools"] as? Bool {
            settings.enableDevTools = val
        }

        self.currentSettings = settings
        saveSettings(settings)
        observersLock.lock()
        let currentObservers = Array(observers.values)
        observersLock.unlock()
        for observer in currentObservers {
            observer(settings)
        }
    }

    private func saveSettings(_ settings: AppSettings) {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    // MARK: - Launch at Login Management

    private var launchAgentURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private func checkLaunchAtLoginStatus() -> Bool {
        if #available(macOS 13.0, *) {
            if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
                return SMAppService.mainApp.status == .enabled
            }
        }
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    return
                } catch {
                    print("[SettingsManager] SMAppService error: \(error), falling back to LaunchAgent")
                }
            }
        }

        // LaunchAgent plist fallback for standalone binaries & dev builds
        let fileManager = FileManager.default
        let plistPath = launchAgentURL.path
        let launchAgentsDir = launchAgentURL.deletingLastPathComponent().path

        if enabled {
            do {
                if !fileManager.fileExists(atPath: launchAgentsDir) {
                    try fileManager.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
                }

                let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
                let absolutePath = URL(fileURLWithPath: executablePath).standardized.path

                let plistContent: [String: Any] = [
                    "Label": launchAgentLabel,
                    "ProgramArguments": [absolutePath],
                    "RunAtLoad": true,
                    "KeepAlive": false,
                    "ProcessType": "Interactive"
                ]

                let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
                try data.write(to: launchAgentURL, options: .atomic)
                print("[SettingsManager] Created LaunchAgent at \(plistPath)")
            } catch {
                print("[SettingsManager] Failed to create LaunchAgent: \(error)")
            }
        } else {
            if fileManager.fileExists(atPath: plistPath) {
                do {
                    try fileManager.removeItem(at: launchAgentURL)
                    print("[SettingsManager] Removed LaunchAgent at \(plistPath)")
                } catch {
                    print("[SettingsManager] Failed to remove LaunchAgent: \(error)")
                }
            }
        }
    }
}
