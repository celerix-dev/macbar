// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CelerixMacBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CelerixMacBar", targets: ["CelerixMacBar"])
    ],
    targets: [
        .executableTarget(
            name: "CelerixMacBar",
            exclude: [
                "App/Info.plist"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreLocation"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CelerixMacBar/App/Info.plist"
                ])
            ]
        )
    ]
)