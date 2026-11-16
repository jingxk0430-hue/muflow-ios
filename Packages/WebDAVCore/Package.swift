// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebDAVCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "WebDAVCore", targets: ["WebDAVCore"])],
    targets: [.target(name: "WebDAVCore"), .testTarget(name: "WebDAVCoreTests", dependencies: ["WebDAVCore"])]
)
