// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "KeyNav",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KeyNav",
            path: "Sources/KeyNav",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "KeyNavTests", dependencies: ["KeyNav"], path: "Tests/KeyNavTests"),
    ]
)
