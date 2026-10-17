// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "BoggartCore", targets: ["BoggartCore"])]
var targets: [Target] = [
    .target(name: "BoggartCore"),
    .testTarget(name: "BoggartCoreTests", dependencies: ["BoggartCore"])
]
#if os(macOS)
products += [.executable(name: "Boggart", targets: ["BoggartApp"]),
             .executable(name: "BoggartHelper", targets: ["BoggartHelper"])]
targets += [
    .target(name: "BoggartPlatform", dependencies: ["BoggartCore"],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("IOKit")]),
    .executableTarget(name: "BoggartApp", dependencies: ["BoggartCore", "BoggartPlatform"],
                      linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                                       .linkedFramework("ServiceManagement"), .linkedFramework("UserNotifications")]),
    .executableTarget(name: "BoggartHelper", dependencies: ["BoggartCore", "BoggartPlatform"],
                      linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")])
]
#endif
let package = Package(name: "Boggart", platforms: [.macOS(.v13)],
                      products: products, targets: targets, swiftLanguageVersions: [.v5])
