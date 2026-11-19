// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pers",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(name: "Pers", dependencies: ["SwiftTerm"], path: "Sources/Pers"),
        .testTarget(name: "PersTests", dependencies: ["Pers"], path: "Tests/PersTests")
    ]
)
