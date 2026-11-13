// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BoringNotchCustomChecks",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CustomCore", path: "boringNotch/components/LiveActivities/Custom",
                exclude: ["CustomBluetooth.swift", "CustomEventSchedule.swift", "CustomFeatureViews.swift", "CustomFeatures.swift", "CustomNetwork.swift"],
                sources: ["CustomCore.swift"]),
        .testTarget(name: "CustomCoreTests", dependencies: ["CustomCore"])
    ]
)
