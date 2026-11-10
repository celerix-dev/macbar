import AppKit
import CoreGraphics
import ImageIO

public struct WallpaperContrastData: Codable {
    public let luminance: Double
    public let isDarkWallpaper: Bool
}

final class WallpaperLuminanceMonitor {
    static let shared = WallpaperLuminanceMonitor()

    private var observers: [UUID: (WallpaperContrastData) -> Void] = [:]
    private let observersLock = NSLock()

    @discardableResult
    func addObserver(_ observer: @escaping (WallpaperContrastData) -> Void) -> UUID {
        let id = UUID()
        observersLock.lock()
        observers[id] = observer
        observersLock.unlock()
        observer(fetchCurrentContrast())
        return id
    }

    func removeObserver(_ id: UUID) {
        observersLock.lock()
        observers.removeValue(forKey: id)
        observersLock.unlock()
    }

    var onContrastChanged: ((WallpaperContrastData) -> Void)? {
        didSet {
            if let onContrastChanged = onContrastChanged {
                _ = addObserver(onContrastChanged)
            }
        }
    }
    var isPaused: Bool = false

    private var cachedLuminance: Double = 0.2
    private var cachedIsDark: Bool = true
    private var checkTimer: Timer?
    private var spaceObserver: Any?
    private var screenObserver: Any?

    private init() {
        setupObservers()
        recalculateLuminance()
    }

    private func setupObservers() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recalculateLuminance()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recalculateLuminance()
        }

        // Periodically check in case dynamic macOS wallpaper changes over the course of the day
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused, !FullScreenMonitor.shared.isFullScreenActive else { return }
            self.recalculateLuminance()
        }
    }

    func fetchCurrentContrast() -> WallpaperContrastData {
        return WallpaperContrastData(luminance: cachedLuminance, isDarkWallpaper: cachedIsDark)
    }

    func recalculateLuminance() {
        guard !isPaused && !FullScreenMonitor.shared.isFullScreenActive else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let (luminance, isDark) = self.calculateTopBarWallpaperLuminance()

            DispatchQueue.main.async {
                let changed = abs(self.cachedLuminance - luminance) > 0.05 || self.cachedIsDark != isDark
                self.cachedLuminance = luminance
                self.cachedIsDark = isDark

                if changed {
                    let data = WallpaperContrastData(luminance: luminance, isDarkWallpaper: isDark)
                    self.observersLock.lock()
                    let currentObservers = Array(self.observers.values)
                    self.observersLock.unlock()
                    for observer in currentObservers {
                        observer(data)
                    }
                }
            }
        }
    }

    private func calculateTopBarWallpaperLuminance() -> (luminance: Double, isDark: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            let app = NSApp ?? NSApplication.shared
            let isDarkTheme = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (isDarkTheme ? 0.2 : 0.8, isDarkTheme)
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            let app = NSApp ?? NSApplication.shared
            let isDarkTheme = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (isDarkTheme ? 0.2 : 0.8, isDarkTheme)
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 else {
            return (0.2, true)
        }

        // Sample the top 8% of the wallpaper height (where the top menu bar is rendered)
        let sampleHeight = max(16, min(height, Int(Double(height) * 0.08)))
        let cropRect = CGRect(x: 0, y: height - sampleHeight, width: width, height: sampleHeight)

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return (0.2, true)
        }

        // Downsample to a small grid (64 x 16 pixels) for ultra-fast averaging
        let gridWidth = 64
        let gridHeight = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: gridWidth * gridHeight * 4)

        guard let context = CGContext(
            data: &rawData,
            width: gridWidth,
            height: gridHeight,
            bitsPerComponent: 8,
            bytesPerRow: gridWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0.2, true)
        }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))

        var totalLuminance: Double = 0.0
        let pixelCount = Double(gridWidth * gridHeight)

        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = Double(rawData[i]) / 255.0
            let g = Double(rawData[i + 1]) / 255.0
            let b = Double(rawData[i + 2]) / 255.0
            // Perceptual relative luminance (WCAG / ITU-R BT.709)
            let lum = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
            totalLuminance += lum
        }

        let avgLuminance = totalLuminance / pixelCount
        // If luminance is below 0.50, the wallpaper segment is dark and requires light text
        let isDark = avgLuminance < 0.50
        return (avgLuminance, isDark)
    }

    deinit {
        checkTimer?.invalidate()
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
