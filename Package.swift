// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApolloKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ApolloKit", targets: ["ApolloKit"]),
        .library(name: "ApolloKitCore", targets: ["ApolloKitCore"]),
    ],
    targets: [
        .target(name: "ApolloKitCore"),
        .executableTarget(name: "ApolloKit", dependencies: ["ApolloKitCore"]),
        .testTarget(name: "ApolloKitCoreTests", dependencies: ["ApolloKitCore"]),
    ]
)
