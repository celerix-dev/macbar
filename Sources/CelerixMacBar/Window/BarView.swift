import SwiftUI
import Combine

final class BarViewModel: ObservableObject {
    @Published private(set) var stats = SystemMonitor.shared.fetchStats()
    @Published private(set) var nowPlaying = NowPlayingData(
        hasTrack: false,
        title: "",
        artist: "",
        album: "",
        isPlaying: false,
        duration: nil,
        elapsedTime: nil
    )
    @Published private(set) var activeApp = AppMenuMonitor.shared.fetchActiveAppData()
    @Published private(set) var runningApps: [RunningAppItem] = []
    @Published private(set) var settings = SettingsManager.shared.getSettings()
    @Published private(set) var currentTime = Date()
    @Published private(set) var wallpaperContrast = WallpaperLuminanceMonitor.shared.fetchCurrentContrast()
    @Published private(set) var weatherSnapshot = WeatherSnapshot.loading
    @Published var isAppMenuOpen = false
    @Published var selectedMenuID: String?
    @Published var showingSettings = false

    private var statsTimer: Timer?
    private var clockTimer: Timer?
    private var nowPlayingObserver: UUID?
    private var activeAppObserver: UUID?
    private var runningAppsObserver: UUID?
    private var settingsObserver: UUID?
    private var wallpaperObserver: UUID?
    private let weatherMonitor = WeatherMonitor()
    private var weatherSubscription: AnyCancellable?

    init() {
        nowPlayingObserver = NowPlayingMonitor.shared.addObserver { [weak self] data in
            self?.nowPlaying = data
        }
        activeAppObserver = AppMenuMonitor.shared.addObserver { [weak self] data in
            self?.setActiveApp(data)
        }
        runningAppsObserver = RunningAppsMonitor.shared.addObserver { [weak self] apps in
            self?.runningApps = apps
        }
        settingsObserver = SettingsManager.shared.addObserver { [weak self] settings in
            self?.settings = settings
            self?.weatherMonitor.configure(
                isEnabled: settings.showWeather,
                temperatureUnit: settings.temperatureUnit
            )
        }
        weatherSubscription = weatherMonitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.weatherSnapshot = snapshot
            }
        wallpaperObserver = WallpaperLuminanceMonitor.shared.addObserver { [weak self] contrast in
            self?.wallpaperContrast = contrast
        }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.stats = SystemMonitor.shared.fetchStats()
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.currentTime = Date()
        }
    }

    deinit {
        statsTimer?.invalidate()
        clockTimer?.invalidate()
        if let nowPlayingObserver {
            NowPlayingMonitor.shared.removeObserver(nowPlayingObserver)
        }
        if let activeAppObserver {
            AppMenuMonitor.shared.removeObserver(activeAppObserver)
        }
        if let runningAppsObserver {
            RunningAppsMonitor.shared.removeObserver(runningAppsObserver)
        }
        if let settingsObserver {
            SettingsManager.shared.removeObserver(settingsObserver)
        }
        if let wallpaperObserver {
            WallpaperLuminanceMonitor.shared.removeObserver(wallpaperObserver)
        }
    }

    func refreshActiveApp() {
        setActiveApp(AppMenuMonitor.shared.fetchActiveAppData())
    }

    func updateSetting(_ key: String, value: Any) {
        SettingsManager.shared.updateSettings(with: [key: value])
    }

    func setActiveApp(_ data: ActiveAppData) {
        activeApp = data
        if !data.menus.contains(where: { $0.id == selectedMenuID }) {
            selectedMenuID = data.menus.first?.id
        }
    }
}

struct BarView: View {
    private let onDropdownChange: (Bool, CGFloat, CGFloat) -> Void
    private let onSettingsPopoverChange: (Bool) -> Void
    private let registerSettingsDismissHandler: (@escaping () -> Void) -> Void
    private let registerDropdownDismissHandler: (@escaping () -> Void) -> Void
    @StateObject private var model = BarViewModel()

    private let dropdownHeight: CGFloat = 440

    init(
        onDropdownChange: @escaping (Bool, CGFloat, CGFloat) -> Void,
        onSettingsPopoverChange: @escaping (Bool) -> Void,
        registerSettingsDismissHandler: @escaping (@escaping () -> Void) -> Void,
        registerDropdownDismissHandler: @escaping (@escaping () -> Void) -> Void
    ) {
        self.onDropdownChange = onDropdownChange
        self.onSettingsPopoverChange = onSettingsPopoverChange
        self.registerSettingsDismissHandler = registerSettingsDismissHandler
        self.registerDropdownDismissHandler = registerDropdownDismissHandler
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.settings.showActiveApp {
                    activeAppWidget
                }
                if model.settings.showRunningApps {
                    runningAppsWidget
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.settings.showNowPlaying {
                nowPlayingWidget
                    .frame(minWidth: 190, maxWidth: 280)
                    .layoutPriority(1)
            }

            HStack(spacing: 10) {
                settingsButton
                if model.settings.showWeather {
                    weatherWidget
                }
                if model.settings.showCpu {
                    metricWidget(symbol: "cpu", value: "\(model.stats.cpuPercent)%", label: "CPU")
                }
                if model.settings.showMemory {
                    metricWidget(symbol: "memorychip", value: model.stats.memoryFormatted, label: "MEM")
                }
                if model.settings.showBattery, model.stats.hasBattery {
                    batteryWidget
                }
                if model.settings.showVolume {
                    volumeWidget
                }
                if model.settings.showDateTime {
                    dateTimeWidget
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .foregroundStyle(model.wallpaperContrast.isDarkWallpaper ? Color.white : Color.black)

            if model.isAppMenuOpen {
                appMenuDropdown
                    .frame(height: dropdownHeight, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(model.$showingSettings.dropFirst(), perform: onSettingsPopoverChange)
        .onAppear {
            registerSettingsDismissHandler {
                model.showingSettings = false
            }
            registerDropdownDismissHandler {
                model.isAppMenuOpen = false
                onDropdownChange(false, dropdownHeight, menuPanelWidth)
            }
        }
    }

    private var activeAppWidget: some View {
        Button {
            model.refreshActiveApp()
            let shouldOpen = !model.isAppMenuOpen
            onDropdownChange(shouldOpen, dropdownHeight, menuPanelWidth)
            withAnimation(.easeOut(duration: 0.18)) {
                model.isAppMenuOpen = shouldOpen
            }
        } label: {
            HStack(spacing: 6) {
                if let icon = activeAppIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app")
                        .foregroundStyle(.secondary)
                }
                Text(model.activeApp.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(model.isAppMenuOpen ? Color.primary.opacity(0.10) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(model.activeApp.name) menu")
    }

    private var activeAppIcon: NSImage? {
        image(from: model.activeApp.iconBase64)
    }

    private var runningAppsWidget: some View {
        HStack(spacing: 5) {
            ForEach(model.runningApps, id: \.pid) { app in
                Button {
                    RunningAppsMonitor.shared.activateOrReopenApp(pid: app.pid)
                } label: {
                    Group {
                        if let icon = image(from: app.iconBase64) {
                            Image(nsImage: icon)
                                .resizable()
                        } else {
                            Image(systemName: "app")
                                .resizable()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .padding(3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(app.hasVisibleWindows ? app.name : "\(app.name) (no open window)")
                .accessibilityLabel(app.name)
            }
        }
    }

    private func image(from iconData: String?) -> NSImage? {
        guard let iconData,
              let encodedData = iconData.split(separator: ",").last,
              let data = Data(base64Encoded: String(encodedData)) else {
            return nil
        }
        return NSImage(data: data)
    }

    private var appMenuDropdown: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    if let icon = activeAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.activeApp.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(model.activeApp.isAccessibilityTrusted
                             ? "Application menu"
                             : "Accessibility access required")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            model.isAppMenuOpen = false
                        }
                        onDropdownChange(false, dropdownHeight, menuPanelWidth)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close menu")
                }
                .padding(14)

                Divider()

                if !model.activeApp.isAccessibilityTrusted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enable CelerixMacBar in System Settings > Privacy & Security > Accessibility to read and activate the frontmost app's menu items.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Open Accessibility Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .padding(16)
                } else if model.activeApp.menus.isEmpty {
                    Text("No menu items are available for this application.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    horizontalMenuBar
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            if let menu = selectedMenu {
                                ForEach(menu.items, id: \.id) { item in
                                    MenuEntryView(item: item) { itemID in
                                        _ = AppMenuMonitor.shared.triggerMenuItem(id: itemID)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                    }
                }
            }
            .frame(width: menuPanelWidth, height: dropdownHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(Color(nsColor: .labelColor))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            .padding(.leading, 8)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.bottom, 8)
    }

    private var horizontalMenuBar: some View {
        HStack(spacing: 3) {
            ForEach(model.activeApp.menus, id: \.id) { menu in
                Button {
                    model.selectedMenuID = menu.id
                } label: {
                    Text(menu.title)
                        .font(.system(size: 12, weight: model.selectedMenuID == menu.id ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 9)
                        .frame(width: menuButtonWidth(for: menu), height: 28)
                        .background {
                            if model.selectedMenuID == menu.id {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.accentColor.opacity(0.16))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!menu.isEnabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var selectedMenu: TopLevelMenuData? {
        model.activeApp.menus.first { $0.id == model.selectedMenuID }
    }

    private var menuPanelWidth: CGFloat {
        let buttonWidths = model.activeApp.menus.reduce(CGFloat.zero) { $0 + idealMenuButtonWidth(for: $1) }
        let gaps = CGFloat(max(0, model.activeApp.menus.count - 1)) * 3
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 800
        return min(max(360, buttonWidths + gaps + 20), max(280, screenWidth - 16))
    }

    private func idealMenuButtonWidth(for menu: TopLevelMenuData) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        return (menu.title as NSString).size(withAttributes: [.font: font]).width + 18
    }

    private func menuButtonWidth(for menu: TopLevelMenuData) -> CGFloat {
        let menus = model.activeApp.menus
        let gaps = CGFloat(max(0, menus.count - 1)) * 3
        let availableWidth = max(0, menuPanelWidth - 20 - gaps)
        let idealWidths = menus.map(idealMenuButtonWidth(for:))
        let totalIdealWidth = idealWidths.reduce(0, +)
        guard totalIdealWidth > 0 else { return 0 }
        return availableWidth * idealMenuButtonWidth(for: menu) / totalIdealWidth
    }

    private var dateTimeWidget: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            Text(formattedDateTime)
                .monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .help("Current date and time")
    }

    private var formattedDateTime: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = model.settings.clockFormat == "12h"
            ? (model.settings.showSeconds ? "EEE d MMM  h:mm:ss a" : "EEE d MMM  h:mm a")
            : (model.settings.showSeconds ? "EEE d MMM  HH:mm:ss" : "EEE d MMM  HH:mm")
        return formatter.string(from: model.currentTime)
    }

    private var nowPlayingWidget: some View {
        HStack(spacing: 8) {

            Image(systemName: model.nowPlaying.isPlaying ? "speaker.wave.3.fill" : "speaker.slash.fill")
                .font(.system(size: 11, weight: .medium))

            if model.nowPlaying.hasTrack && model.nowPlaying.isPlaying {
                CALayerBarsView()
                    .frame(width: 8, height: 10)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.nowPlaying.hasTrack ? model.nowPlaying.title : "Nothing Playing")
                    .lineLimit(1)
                if model.nowPlaying.hasTrack && !model.nowPlaying.artist.isEmpty {
                    Text(model.nowPlaying.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: 150, alignment: .leading)

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                mediaControl(symbol: "backward.end.fill", help: "Previous track") {
                    NowPlayingMonitor.shared.previousTrack()
                }
                mediaControl(
                    symbol: model.nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    help: model.nowPlaying.isPlaying ? "Pause" : "Play"
                ) {
                    NowPlayingMonitor.shared.togglePlayPause()
                }
                mediaControl(symbol: "forward.end.fill", help: "Next track") {
                    NowPlayingMonitor.shared.nextTrack()
                }
            }
        }
        .padding(.horizontal, 12)
        .help([model.nowPlaying.title, model.nowPlaying.artist].filter { !$0.isEmpty }.joined(separator: " — "))
    }

    private func mediaControl(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var settingsButton: some View {
        Button {
            model.showingSettings.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Settings")
        .popover(isPresented: $model.showingSettings, arrowEdge: .top) {
            settingsPopover
                .padding(14)
                .frame(width: 308, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Color(nsColor: .labelColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                .tint(.accentColor)
        }
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 8) {
                settingToggleRow("Start at login", key: "launchAtLogin", value: \.launchAtLogin)
                settingToggleRow("Hide bar in full screen", key: "hideOnFullScreen", value: \.hideOnFullScreen)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                settingsSectionTitle("Widgets")
                settingToggleRow("Active app menu", key: "showActiveApp", value: \.showActiveApp)
                settingToggleRow("Running apps", key: "showRunningApps", value: \.showRunningApps)
                settingToggleRow("Weather", key: "showWeather", value: \.showWeather)
                settingToggleRow("Date and time", key: "showDateTime", value: \.showDateTime)
                settingToggleRow("Now Playing", key: "showNowPlaying", value: \.showNowPlaying)
                settingToggleRow("CPU", key: "showCpu", value: \.showCpu)
                settingToggleRow("Memory", key: "showMemory", value: \.showMemory)
                settingToggleRow("Battery", key: "showBattery", value: \.showBattery)
                settingToggleRow("Volume", key: "showVolume", value: \.showVolume)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                settingsSectionTitle("Weather")
                temperatureUnitSelector
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                settingsSectionTitle("Clock")
                settingToggleRow("Show seconds", key: "showSeconds", value: \.showSeconds)
                clockFormatSelector
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var clockFormatSelector: some View {
        HStack(spacing: 3) {
            clockFormatButton(title: "24-hour", format: "24h")
            clockFormatButton(title: "12-hour", format: "12h")
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clock format")
    }

    private var temperatureUnitSelector: some View {
        HStack(spacing: 3) {
            temperatureUnitButton(title: "Celsius °C", unit: "celsius")
            temperatureUnitButton(title: "Fahrenheit °F", unit: "fahrenheit")
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temperature unit")
    }

    private func temperatureUnitButton(title: String, unit: String) -> some View {
        let isSelected = model.settings.temperatureUnit == unit

        return Button {
            model.updateSetting("temperatureUnit", value: unit)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(maxWidth: .infinity, minHeight: 25)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.18))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func clockFormatButton(title: String, format: String) -> some View {
        let isSelected = model.settings.clockFormat == format

        return Button {
            model.updateSetting("clockFormat", value: format)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(maxWidth: .infinity, minHeight: 25)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.18))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func settingToggleRow(
        _ title: String,
        key: String,
        value: KeyPath<AppSettings, Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: settingBinding(key, value: value))
                .labelsHidden()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
    }

    private func settingBinding<Value>(
        _ key: String,
        value: KeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: value] },
            set: { model.updateSetting(key, value: $0) }
        )
    }

    private func metricWidget(symbol: String, value: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .frame(width: metricValueWidth(for: label), alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .help(label == "MEM" ? "Memory used" : "CPU usage")
    }

    private var weatherWidget: some View {
        HStack(spacing: 5) {
            Image(systemName: weatherSymbol)
                .foregroundStyle(.secondary)
            Text(weatherTemperature)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .help(model.weatherSnapshot.error ?? "Current weather")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.weatherSnapshot.error ?? "Current weather, \(weatherTemperature)")
    }

    private var weatherTemperature: String {
        guard let temperature = model.weatherSnapshot.temperature else { return "--°" }
        let unit = model.settings.temperatureUnit == "fahrenheit" ? "F" : "C"
        return "\(Int(temperature.rounded()))°\(unit)"
    }

    private var weatherSymbol: String {
        guard let code = model.weatherSnapshot.weatherCode else {
            return model.weatherSnapshot.error == nil ? "cloud" : "location.slash"
        }
        switch code {
        case 0:
            return "sun.max.fill"
        case 1:
            return "sun.max"
        case 2:
            return "cloud.sun.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51...57:
            return "cloud.drizzle.fill"
        case 61...67:
            return "cloud.rain.fill"
        case 71...77, 85, 86:
            return "cloud.snow.fill"
        case 80...82:
            return "cloud.heavyrain.fill"
        case 95...99:
            return "cloud.bolt.rain.fill"
        default:
            return "cloud.fill"
        }
    }

    private func metricValueWidth(for label: String) -> CGFloat {
        switch label {
        case "CPU":
            return 30
        case "MEM":
            let total = model.stats.memoryTotalGB
            let widestValue = String(format: "%.1f / %.0fGb", total, total)
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            return (widestValue as NSString).size(withAttributes: [.font: font]).width + 2
        default:
            return 30
        }
    }

    private var batteryWidget: some View {
        HStack(spacing: 5) {
            Image(systemName: batterySymbol)
                .foregroundStyle(.secondary)
            Text("\(model.stats.battery)%")
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
            if model.stats.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .help(model.stats.isCharging ? "Battery charging" : "Battery level")
    }

    private var batterySymbol: String {
        switch model.stats.battery {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        case 1...: return "battery.25"
        default: return "battery.0"
        }
    }

    private var volumeWidget: some View {
        HStack(spacing: 5) {
            Image(systemName: model.stats.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Text(model.stats.isMuted ? "Muted" : "\(model.stats.volume)%")
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .help(model.stats.isMuted ? "Audio is muted" : "Output volume")
    }
}

private struct MenuEntryView: View {
    let item: MenuItemData
    let onSelect: (String) -> Void

    var body: some View {
        if item.isSeparator {
            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
        } else if let children = item.children, !children.isEmpty {
            Menu {
                ForEach(children, id: \.id) { child in
                    MenuEntryView(item: child, onSelect: onSelect)
                }
            } label: {
                rowContent(showsSubmenu: true)
            }
            .disabled(!item.isEnabled)
            .menuStyle(.borderlessButton)
        } else {
            Button {
                onSelect(item.id)
            } label: {
                rowContent(showsSubmenu: false)
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
        }
    }

    private func rowContent(showsSubmenu: Bool) -> some View {
        HStack(spacing: 8) {
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if showsSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 25)
        .contentShape(Rectangle())
    }
}

private struct CALayerBarsView: NSViewRepresentable {
    
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let barWidth: CGFloat = 1.5
        let spacing: CGFloat = 1.5
        let maxHeight: CGFloat = 10.0
        let heights: [CGFloat] = [10.0, 6.5, 8.5]
        let durations: [CFTimeInterval] = [0.45, 0.65, 0.52]

        for i in 0..<3 {
            let bar = CALayer()
            let x = CGFloat(i) * (barWidth + spacing) + (barWidth / 2)
            
            // 1. Pin the anchor point to bottom-center (y = 0.0)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.0)
            
            // 2. Set the resting position at the baseline (y = 0)
            bar.position = CGPoint(x: x, y: 0)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: heights[i])
            
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = barWidth / 2

            // 3. Animate height — since anchorPoint.y is 0, it expands solely upward
            let anim = CAKeyframeAnimation(keyPath: "bounds.size.height")
            anim.values = [heights[i] * 0.2, heights[i], heights[i] * 0.2]
            anim.keyTimes = [0.0, 0.5, 1.0]
            anim.duration = durations[i]
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            bar.add(anim, forKey: "pulse")
            container.layer?.addSublayer(bar)
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}