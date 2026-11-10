import Foundation
import AppKit
import CoreAudio
import Darwin

struct NowPlayingData: Codable {
    let hasTrack: Bool
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let duration: Double?
    let elapsedTime: Double?
}

final class NowPlayingMonitor {
    static let shared = NowPlayingMonitor()

    private typealias MRRegisterFunc = @convention(c) (DispatchQueue) -> Void
    private typealias MRGetInfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias MRPIDFunc = @convention(c) (DispatchQueue, @escaping (pid_t) -> Void) -> Void
    private typealias MRSetCanBeNowPlayingAppFunc = @convention(c) (Bool) -> Void
    private typealias MRSendCmdFunc = @convention(c) (UInt32, AnyObject?) -> Bool

    private var mrRegister: MRRegisterFunc?
    private var mrGetInfo: MRGetInfoFunc?
    private var mrIsPlaying: MRIsPlayingFunc?
    private var mrGetPID: MRPIDFunc?
    private var mrSetCanBeNowPlaying: MRSetCanBeNowPlayingAppFunc?
    private var mrSendCmd: MRSendCmdFunc?

    private var observers: [UUID: (NowPlayingData) -> Void] = [:]
    private let observersLock = NSLock()
    private var isObserving = false
    private var pollTimer: Timer?
    private var currentData: NowPlayingData = NowPlayingData(
        hasTrack: false,
        title: "",
        artist: "",
        album: "",
        isPlaying: false,
        duration: nil,
        elapsedTime: nil
    )

    @discardableResult
    func addObserver(_ observer: @escaping (NowPlayingData) -> Void) -> UUID {
        let id = UUID()
        observersLock.lock()
        observers[id] = observer
        let initialData = currentData
        observersLock.unlock()
        observer(initialData)
        return id
    }

    func removeObserver(_ id: UUID) {
        observersLock.lock()
        observers.removeValue(forKey: id)
        observersLock.unlock()
    }

    var onNowPlayingChanged: ((NowPlayingData) -> Void)? {
        didSet {
            if let onNowPlayingChanged = onNowPlayingChanged {
                _ = addObserver(onNowPlayingChanged)
            }
        }
    }

    init() {
        loadMediaRemoteSymbols()
        startObserving()
    }

    private func loadMediaRemoteSymbols() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            print("[NowPlayingMonitor] Failed to dlopen MediaRemote.framework")
            return
        }

        if let regPtr = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            mrRegister = unsafeBitCast(regPtr, to: MRRegisterFunc.self)
        }
        if let infoPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            mrGetInfo = unsafeBitCast(infoPtr, to: MRGetInfoFunc.self)
        }
        if let playingPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            mrIsPlaying = unsafeBitCast(playingPtr, to: MRIsPlayingFunc.self)
        }
        if let pidPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
            mrGetPID = unsafeBitCast(pidPtr, to: MRPIDFunc.self)
        }
        if let setCanPtr = dlsym(handle, "MRMediaRemoteSetCanBeNowPlayingApplication") {
            mrSetCanBeNowPlaying = unsafeBitCast(setCanPtr, to: MRSetCanBeNowPlayingAppFunc.self)
        }
        if let cmdPtr = dlsym(handle, "MRMediaRemoteSendCommand") {
            mrSendCmd = unsafeBitCast(cmdPtr, to: MRSendCmdFunc.self)
        }

    }

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        mrSetCanBeNowPlaying?(false)
        mrRegister?(DispatchQueue.main)

        // Observe MediaRemote notifications
        let notificationNames = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "_MRMediaRemoteNowPlayingInfoDidChangeNotification"
        ]

        for name in notificationNames {
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.fetchNowPlaying()
            }

            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.fetchNowPlaying()
            }
        }

        // Add Darwin notification center observer for low-level media remote changes
        let darwinCallback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer else { return }
            let monitor = Unmanaged<NowPlayingMonitor>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.fetchNowPlaying()
            }
        }

        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        for name in notificationNames {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                unmanagedSelf,
                darwinCallback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        // Periodic check to catch state changes across all apps and run loop modes
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.fetchNowPlaying()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.pollTimer = timer

        fetchNowPlaying(force: true)
    }

    func fetchNowPlaying(force: Bool = false) {
        guard let mrGetInfo = mrGetInfo else {
            fallbackAppleScriptCheck(force: force)
            return
        }

        mrGetInfo(DispatchQueue.main) { [weak self] info in
            guard let self = self else { return }

            let title = (info["kMRMediaRemoteNowPlayingInfoTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let artist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let album = (info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            let playbackRate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
                ?? (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double)
                ?? 0.0
            let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue
                ?? (info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double)
            let elapsedTime = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue
                ?? (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double)

            let hasTrack = !title.isEmpty || !artist.isEmpty

            if hasTrack {
                let isPlaying = playbackRate > 0.0
                let newData = NowPlayingData(
                    hasTrack: true,
                    title: title.isEmpty ? "Unknown Track" : title,
                    artist: artist,
                    album: album,
                    isPlaying: isPlaying,
                    duration: duration,
                    elapsedTime: elapsedTime
                )
                self.updateDataIfChanged(newData, force: force)

                // Asynchronously verify playback state if helper symbol is present
                if let mrIsPlaying = self.mrIsPlaying {
                    mrIsPlaying(DispatchQueue.main) { [weak self] isAppPlaying in
                        guard let self = self else { return }
                        let refinedIsPlaying = isAppPlaying || playbackRate > 0.0
                        if refinedIsPlaying != self.currentData.isPlaying && self.currentData.hasTrack {
                            let updated = NowPlayingData(
                                hasTrack: true,
                                title: self.currentData.title,
                                artist: self.currentData.artist,
                                album: self.currentData.album,
                                isPlaying: refinedIsPlaying,
                                duration: self.currentData.duration,
                                elapsedTime: self.currentData.elapsedTime
                            )
                            self.updateDataIfChanged(updated, force: force)
                        }
                    }

                }
            } else {
                self.fallbackAppleScriptCheck(force: force, isPlayingHint: playbackRate > 0)
            }
        }
    }

    private func fallbackAppleScriptCheck(force: Bool = false, isPlayingHint: Bool = false) {
        if isPlayingHint {
            fetchPlayingApplication(force: force)
            return
        }

        if let mrIsPlaying {
            mrIsPlaying(DispatchQueue.main) { [weak self] isPlaying in
                guard let self else { return }
                if isPlaying {
                    if self.currentData.hasTrack {
                        self.updateDataIfChanged(
                            NowPlayingData(
                                hasTrack: true,
                                title: self.currentData.title,
                                artist: self.currentData.artist,
                                album: self.currentData.album,
                                isPlaying: true,
                                duration: self.currentData.duration,
                                elapsedTime: self.currentData.elapsedTime
                            ),
                            force: force
                        )
                    } else {
                        self.fetchPlayingApplication(force: force)
                    }
                } else {
                    self.fallbackKnownMusicApps(force: force)
                }
            }
        } else {
            fallbackKnownMusicApps(force: force)
        }
    }

    private func fetchPlayingApplication(force: Bool, isPlaying: Bool = true) {
        guard let mrGetPID else {
            if isPlaying, let app = NSWorkspace.shared.frontmostApplication {
                publishPlayingApplication(app, force: force, isPlaying: true)
            } else {
                publishEmptyData(force: force)
            }
            return
        }

        mrGetPID(DispatchQueue.main) { [weak self] pid in
            guard let self else { return }
            let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
            if let app {
                self.publishPlayingApplication(app, force: force, isPlaying: isPlaying)
            } else if isPlaying, let frontmostApp = NSWorkspace.shared.frontmostApplication {
                self.publishPlayingApplication(frontmostApp, force: force, isPlaying: true)
            } else {
                self.publishEmptyData(force: force)
            }
        }
    }

    private func publishPlayingApplication(
        _ app: NSRunningApplication,
        force: Bool,
        isPlaying: Bool = true
    ) {
        let appName = app.localizedName ?? app.bundleIdentifier ?? "Media player"
        let windowTitle = focusedWindowTitle(for: app.processIdentifier)
        let track = windowTitle.map(parseTrackTitle) ?? (title: appName, artist: "")
        let resolvedIsPlaying = playbackState(for: app.processIdentifier) ?? isPlaying
        updateDataIfChanged(
            NowPlayingData(
                hasTrack: true,
                title: track.title,
                artist: track.artist,
                album: "",
                isPlaying: resolvedIsPlaying,
                duration: nil,
                elapsedTime: nil
            ),
            force: force
        )
    }

    private func parseTrackTitle(_ rawTitle: String) -> (title: String, artist: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = title.range(of: " - ") else {
            return (title, "")
        }
        let trackTitle = String(title[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = String(title[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (trackTitle.isEmpty ? title : trackTitle, artist)
    }

    private func playbackState(for pid: pid_t) -> Bool? {
        let appElement = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success,
        let menuBarValue else {
            return nil
        }

        let menuBar = menuBarValue as! AXUIElement
        guard let playbackMenu = findAccessibilityElement(
            menuBar,
            role: kAXMenuBarItemRole as String,
            title: "Playback"
        ) else {
            return nil
        }

        if findAccessibilityElement(playbackMenu, role: kAXMenuItemRole as String, title: "Pause") != nil {
            return true
        }
        if findAccessibilityElement(playbackMenu, role: kAXMenuItemRole as String, title: "Play") != nil {
            return false
        }
        return nil
    }

    private func findAccessibilityElement(
        _ element: AXUIElement,
        role: String,
        title: String,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth < 8 else { return nil }
        if accessibilityString(element, attribute: kAXRoleAttribute as String) == role,
           accessibilityString(element, attribute: kAXTitleAttribute as String) == title {
            return element
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let match = findAccessibilityElement(child, role: role, title: title, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    private func accessibilityString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func focusedWindowTitle(for pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement],
        let window = windows.first {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleValue
            ) == .success,
            let title = titleValue as? String {
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedTitle.isEmpty {
                    return trimmedTitle
                }
            }
        }

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue else {
            return nil
        }
        let window = windowValue as! AXUIElement

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else {
            return nil
        }
        return (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fallbackKnownMusicApps(force: Bool) {
        // Fallback for Spotify or Music if MediaRemote is idle
        let runningApps = NSWorkspace.shared.runningApplications
        let hasSpotify = runningApps.contains { $0.bundleIdentifier == "com.spotify.client" || $0.localizedName == "Spotify" }
        let hasMusic = runningApps.contains { $0.bundleIdentifier == "com.apple.Music" || $0.localizedName == "Music" }

        if hasSpotify {
            executeAppleScriptTrackQuery(app: "Spotify", force: force)
        } else if hasMusic {
            executeAppleScriptTrackQuery(app: "Music", force: force)
        } else {
            fallbackActiveAudioOutput(force: force)
        }
    }

    private func executeAppleScriptTrackQuery(app: String, force: Bool) {
        let script = """
        if application "\(app)" is running then
            tell application "\(app)"
                set playerState to (player state as string)
                set trackName to (name of current track as string)
                set artistName to (artist of current track as string)
                return playerState & "|||" & trackName & "|||" & artistName
            end tell
        else
            return ""
        end if
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error).stringValue ?? ""
            let parts = result.components(separatedBy: "|||")
            if parts.count >= 3 && !parts[1].isEmpty {
                let state = parts[0].lowercased()
                let isPlaying = state.contains("playing")
                let newData = NowPlayingData(
                    hasTrack: true,
                    title: parts[1],
                    artist: parts[2],
                    album: "",
                    isPlaying: isPlaying,
                    duration: nil,
                    elapsedTime: nil
                )
                updateDataIfChanged(newData, force: force)
                if !isPlaying, let activeApp = activeAudioOutputApplication() {
                    publishPlayingApplication(activeApp, force: force)
                }
                return
            }
        }

        fallbackActiveAudioOutput(force: force)
    }

    private func fallbackActiveAudioOutput(force: Bool) {
        guard let app = activeAudioOutputApplication() else {
            if let tidalApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.tidal.desktop"
            }) {
                publishPlayingApplication(tidalApp, force: force, isPlaying: currentData.isPlaying)
                return
            }
            fetchPlayingApplication(force: force, isPlaying: false)
            return
        }

        publishPlayingApplication(app, force: force)
    }

    private func publishEmptyData(force: Bool) {
        updateDataIfChanged(
            NowPlayingData(
                hasTrack: false,
                title: "",
                artist: "",
                album: "",
                isPlaying: false,
                duration: nil,
                elapsedTime: nil
            ),
            force: force
        )
    }

    private func activeAudioOutputApplication() -> NSRunningApplication? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr else {
            return nil
        }

        let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard processCount > 0 else { return nil }
        var processObjects = [AudioObjectID](repeating: kAudioObjectUnknown, count: processCount)
        let listStatus = processObjects.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        guard listStatus == noErr else {
            return nil
        }

        var fallbackApplication: NSRunningApplication?
        for processObject in processObjects where processObject != kAudioObjectUnknown {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                processObject,
                &pidAddress,
                0,
                nil,
                &pidSize,
                &pid
            ) == noErr, pid > 0, pid != getpid() else {
                continue
            }

            var isRunningOutput: UInt32 = 0
            var outputSize = UInt32(MemoryLayout<UInt32>.size)
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                processObject,
                &outputAddress,
                0,
                nil,
                &outputSize,
                &isRunningOutput
            ) == noErr, isRunningOutput != 0 else {
                continue
            }

            if let app = applicationOwningAudioProcess(pid) {
                if playbackState(for: app.processIdentifier) == true {
                    return app
                }
                if playbackState(for: app.processIdentifier) == nil {
                    fallbackApplication = fallbackApplication ?? app
                }
            }
        }

        return fallbackApplication
    }

    private func applicationOwningAudioProcess(_ pid: pid_t) -> NSRunningApplication? {
        var currentPID = pid
        var visitedPIDs = Set<pid_t>()

        for _ in 0..<8 where currentPID > 1 {
            guard visitedPIDs.insert(currentPID).inserted else { return nil }
            if let app = NSRunningApplication(processIdentifier: currentPID) {
                return app
            }

            var processInfo = proc_bsdinfo()
            let bytesRead = proc_pidinfo(
                currentPID,
                PROC_PIDTBSDINFO,
                0,
                &processInfo,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard bytesRead == MemoryLayout<proc_bsdinfo>.size else { return nil }
            currentPID = pid_t(processInfo.pbi_ppid)
        }

        return nil
    }

    private func updateDataIfChanged(_ newData: NowPlayingData, force: Bool = false) {
        currentData = newData
        observersLock.lock()
        let currentObservers = Array(observers.values)
        observersLock.unlock()
        for observer in currentObservers {
            observer(newData)
        }
    }

    func fetchCurrentData() -> NowPlayingData {
        return currentData
    }

    // Media Control Actions
    func togglePlayPause() {
        if let sendCmd = mrSendCmd {
            _ = sendCmd(2, nil) // 2: TogglePlayPause
        } else {
            // Fallback to system media key
            sendSystemMediaKey(key: 16) // NX_KEYTYPE_PLAY
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.fetchNowPlaying()
        }
    }

    func nextTrack() {
        if let sendCmd = mrSendCmd {
            _ = sendCmd(4, nil) // 4: NextTrack
        } else {
            sendSystemMediaKey(key: 19) // NX_KEYTYPE_NEXT
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.fetchNowPlaying()
        }
    }

    func previousTrack() {
        if let sendCmd = mrSendCmd {
            _ = sendCmd(5, nil) // 5: PreviousTrack
        } else {
            sendSystemMediaKey(key: 20) // NX_KEYTYPE_PREVIOUS
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.fetchNowPlaying()
        }
    }

    private func sendSystemMediaKey(key: Int32) {
        func postKeyEvent(key: Int32, down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | (down ? 0xa00 : 0xb00))
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        postKeyEvent(key: key, down: true)
        postKeyEvent(key: key, down: false)
    }

    deinit {
        pollTimer?.invalidate()
    }
}
