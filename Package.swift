// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ledge",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Ledge",
            path: "Sources/Ledge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Carbon"),
                .linkedFramework("EventKit"),
            ]
        )
    ]
)
