// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiriHarness",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "SiriHarness", targets: ["SiriHarness"]),
        .library(name: "SiriHarnessCore", type: .dynamic, targets: ["SiriHarnessCore"]),
    ],
    targets: [
        .target(
            name: "SiriHarnessCore"
        ),
        .executableTarget(
            name: "SiriHarness",
            dependencies: ["SiriHarnessCore"]
        ),
        .testTarget(
            name: "SiriHarnessTests",
            dependencies: ["SiriHarnessCore"]
        ),
    ]
)
