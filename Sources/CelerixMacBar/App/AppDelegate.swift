import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: BarWindow?
    private let barHeight: CGFloat = 44.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let barWindow = BarWindow(height: barHeight)
        barWindow.contentView = NSHostingView(
            rootView: BarView(
                onDropdownChange: { [weak barWindow] isOpen, height, width in
                    barWindow?.setDropdownOpen(isOpen, height: height, width: width)
                },
                onSettingsPopoverChange: { [weak barWindow] isOpen in
                    barWindow?.setSettingsPopoverOpen(isOpen)
                },
                registerSettingsDismissHandler: { [weak barWindow] handler in
                    barWindow?.onSettingsPopoverDismissRequested = handler
                },
                registerDropdownDismissHandler: { [weak barWindow] handler in
                    barWindow?.onDropdownDismissRequested = handler
                }
            )
        )
        self.window = barWindow

        updateWindowsVisibility()

        FullScreenMonitor.shared.onFullScreenChanged = { [weak self] fullScreenActive in
            guard let self = self, let barWindow = self.window else { return }
            let shouldHide = fullScreenActive && SettingsManager.shared.getSettings().hideOnFullScreen
            if shouldHide {
                barWindow.orderOut(nil)
                WallpaperLuminanceMonitor.shared.isPaused = true
            } else {
                barWindow.updatePosition(height: self.barHeight)
                barWindow.orderFrontRegardless()
                WallpaperLuminanceMonitor.shared.isPaused = false
                WallpaperLuminanceMonitor.shared.recalculateLuminance()
            }
        }

        SettingsManager.shared.onSettingsChanged = { [weak self] settings in
            guard let self = self, let barWindow = self.window else { return }
           
            if FullScreenMonitor.shared.isFullScreenActive {
                if settings.hideOnFullScreen {
                    barWindow.orderOut(nil)
                    WallpaperLuminanceMonitor.shared.isPaused = true
                } else {
                    barWindow.updatePosition(height: self.barHeight)
                    barWindow.orderFrontRegardless()
                    WallpaperLuminanceMonitor.shared.isPaused = false
                    WallpaperLuminanceMonitor.shared.recalculateLuminance()
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func updateWindowsVisibility() {
        let settings = SettingsManager.shared.getSettings()
        let isFullScreen = FullScreenMonitor.shared.isFullScreenActive

        if isFullScreen && settings.hideOnFullScreen {
            window?.orderOut(nil)
            WallpaperLuminanceMonitor.shared.isPaused = true
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc private func screenParametersChanged() {
        window?.updatePosition(height: barHeight)
    }
}
