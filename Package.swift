// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalendarHelper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CalendarHelper", targets: ["CalendarHelper"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CalendarCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CalendarHelper", dependencies: ["CalendarCore"]),
        .testTarget(name: "CalendarHelperTests", dependencies: ["CalendarCore", "CSQLite"])
    ]
)
