import Foundation
import AppKit

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
                self.fallbackAppleScriptCheck(force: force)
            }
        }
    }

    private func fallbackAppleScriptCheck(force: Bool = false) {
        // Fallback for Spotify or Music if MediaRemote is idle
        let runningApps = NSWorkspace.shared.runningApplications
        let hasSpotify = runningApps.contains { $0.bundleIdentifier == "com.spotify.client" || $0.localizedName == "Spotify" }
        let hasMusic = runningApps.contains { $0.bundleIdentifier == "com.apple.Music" || $0.localizedName == "Music" }

        if hasSpotify {
            executeAppleScriptTrackQuery(app: "Spotify", force: force)
        } else if hasMusic {
            executeAppleScriptTrackQuery(app: "Music", force: force)
        } else {
            let emptyData = NowPlayingData(
                hasTrack: false,
                title: "",
                artist: "",
                album: "",
                isPlaying: false,
                duration: nil,
                elapsedTime: nil
            )
            updateDataIfChanged(emptyData, force: force)
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
                return
            }
        }

        let emptyData = NowPlayingData(
            hasTrack: false,
            title: "",
            artist: "",
            album: "",
            isPlaying: false,
            duration: nil,
            elapsedTime: nil
        )
        updateDataIfChanged(emptyData, force: force)
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
