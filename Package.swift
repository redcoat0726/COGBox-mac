// swift-tools-version:5.9
// The app half of cogbox-mac. Built with SwiftPM so the SwiftUI macro plugins are resolved the normal way.
import PackageDescription

let package = Package(
    name: "COGBox",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "COGBox", path: "app", sources: ["COGBoxMac.swift"])
    ]
)
