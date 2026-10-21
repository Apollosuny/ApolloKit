import Foundation

/// Cleanups that must go through the owning tool because the data is not plain files in the home folder:
/// simulator runtimes live in system-managed disk images and Docker data lives inside its VM disk.
public enum ToolSource: Sendable, Hashable {
    case unavailableSimulators
    /// Content of shut-down simulators; erasing keeps the device but resets it to factory state.
    case simulatorDeviceData
    case simulatorRuntimes
    case docker(DockerResource)
}

public enum DockerResource: String, Sendable, Hashable, CaseIterable {
    case buildCache
    case unusedImages
    case stoppedContainers
    case unusedVolumes

    /// `Type` column of `docker system df`.
    var systemDFType: String {
        switch self {
        case .buildCache: "Build Cache"
        case .unusedImages: "Images"
        case .stoppedContainers: "Containers"
        case .unusedVolumes: "Local Volumes"
        }
    }

    /// Prune commands chosen to match what `docker system df` reports as reclaimable.
    var pruneArguments: [String] {
        switch self {
        case .buildCache: ["builder", "prune", "--all", "--force"]
        case .unusedImages: ["image", "prune", "--all", "--force"]
        case .stoppedContainers: ["container", "prune", "--force"]
        case .unusedVolumes: ["volume", "prune", "--all", "--force"]
        }
    }

    var displayName: String {
        switch self {
        case .buildCache: "Build cache"
        case .unusedImages: "Unused images"
        case .stoppedContainers: "Stopped containers"
        case .unusedVolumes: "Unused volumes"
        }
    }
}

struct ToolBinding: Sendable {
    let source: ToolSource
    let rule: CleanupRule
}

struct ToolLocateResult: Sendable {
    var items: [CleanupItem] = []
    var issues: [ScanIssue] = []

    mutating func merge(_ other: ToolLocateResult) {
        items += other.items
        issues += other.issues
    }
}

struct ToolScanner: Sendable {
    let tools: ToolEnvironment

    func scan(_ bindings: [ToolBinding], progress: @Sendable (ScanProgress) -> Void) async -> ToolLocateResult {
        var simulatorBindings: [ToolBinding] = []
        var dockerBindings: [(DockerResource, CleanupRule)] = []
        for binding in bindings {
            switch binding.source {
            case .unavailableSimulators, .simulatorDeviceData, .simulatorRuntimes:
                simulatorBindings.append(binding)
            case .docker(let resource):
                dockerBindings.append((resource, binding.rule))
            }
        }

        var result = ToolLocateResult()
        if let xcrun = tools.xcrun, !simulatorBindings.isEmpty {
            progress(.locating(ruleTitle: "Simulators"))
            let simulators = SimulatorToolProvider(xcrun: xcrun, runner: tools.runner)
            for binding in simulatorBindings {
                switch binding.source {
                case .unavailableSimulators: result.merge(await simulators.unavailableDevices(rule: binding.rule))
                case .simulatorDeviceData: result.merge(await simulators.deviceData(rule: binding.rule))
                case .simulatorRuntimes: result.merge(await simulators.runtimes(rule: binding.rule))
                case .docker: break
                }
            }
        }
        if let docker = tools.docker, !dockerBindings.isEmpty {
            progress(.locating(ruleTitle: "Docker"))
            result.merge(await DockerToolProvider(docker: docker, runner: tools.runner).items(for: dockerBindings))
        }
        for item in result.items {
            progress(.discovered(group: item.rule.group, bytes: item.sizeInBytes))
        }
        return result
    }
}

// MARK: - Simulators

struct SimulatorToolProvider: Sendable {
    let xcrun: URL
    let runner: any ToolRunner

    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let name: String
        let dataPath: String?
        let state: String?
        let lastBootedAt: String?
    }

    /// simctl SDK names per runtime platform, used to flag the runtime the selected Xcode builds against.
    private static let simulatorSDKs = [
        "iOS": "iphonesimulator", "watchOS": "watchsimulator", "tvOS": "appletvsimulator",
        "xrOS": "xrsimulator", "visionOS": "xrsimulator",
    ]

    private struct Runtime: Decodable {
        let identifier: String
        let version: String?
        let build: String?
        let deletable: Bool?
        let sizeBytes: Int64?
        let lastUsedAt: String?
        let runtimeIdentifier: String?
    }

    func unavailableDevices(rule: CleanupRule) async -> ToolLocateResult {
        var result = ToolLocateResult()
        guard let data = await runSimctl(["list", "devices", "unavailable", "--json"], into: &result) else { return result }
        do {
            let list = try JSONDecoder().decode(DeviceList.self, from: data)
            for (runtimeIdentifier, devices) in list.devices {
                for device in devices {
                    guard let dataPath = device.dataPath else { continue }
                    // dataPath is `<Devices>/<UDID>/data`; the whole UDID folder goes away on delete.
                    let deviceDirectory = URL(fileURLWithPath: dataPath).deletingLastPathComponent()
                    let size = DirectorySizer.measure(deviceDirectory).allocatedBytes
                    guard size > 0 else { continue }
                    let modified = try? deviceDirectory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    result.items.append(CleanupItem(
                        id: "simctl.device.\(device.udid)",
                        rule: rule,
                        displayName: "\(device.name) (\(Self.runtimeName(runtimeIdentifier)))",
                        url: deviceDirectory,
                        action: .runTool(simctl(["delete", device.udid])),
                        sizeInBytes: size,
                        lastModified: modified
                    ))
                }
            }
        } catch {
            result.issues.append(ScanIssue(subject: "Simulators", message: "Unexpected simctl output: \(error.localizedDescription)"))
        }
        return result
    }

    func deviceData(rule: CleanupRule) async -> ToolLocateResult {
        var result = ToolLocateResult()
        guard let data = await runSimctl(["list", "devices", "available", "--json"], into: &result) else { return result }
        do {
            let list = try JSONDecoder().decode(DeviceList.self, from: data)
            for (runtimeIdentifier, devices) in list.devices {
                // Erasing requires a shut-down device; booted ones are in active use anyway.
                for device in devices where device.state == "Shutdown" {
                    guard let dataPath = device.dataPath else { continue }
                    let deviceDirectory = URL(fileURLWithPath: dataPath).deletingLastPathComponent()
                    let size = DirectorySizer.measure(deviceDirectory).allocatedBytes
                    guard size > 0 else { continue }
                    result.items.append(CleanupItem(
                        id: "simctl.erase.\(device.udid)",
                        rule: rule,
                        displayName: "\(device.name) (\(Self.runtimeName(runtimeIdentifier)))",
                        url: deviceDirectory,
                        action: .runTool(simctl(["erase", device.udid])),
                        sizeInBytes: size,
                        lastModified: device.lastBootedAt.flatMap { try? Date($0, strategy: .iso8601) }
                    ))
                }
            }
        } catch {
            result.issues.append(ScanIssue(subject: "Simulators", message: "Unexpected simctl output: \(error.localizedDescription)"))
        }
        return result
    }

    func runtimes(rule: CleanupRule) async -> ToolLocateResult {
        var result = ToolLocateResult()
        guard let data = await runSimctl(["runtime", "list", "--json"], into: &result) else { return result }
        do {
            let runtimes = try JSONDecoder().decode([String: Runtime].self, from: data)
            let deletable = runtimes.values.filter { $0.deletable == true && ($0.sizeBytes ?? 0) > 0 }
            let platforms = Set(deletable.compactMap { $0.runtimeIdentifier.map(Self.platformName) })
            var activeSDKVersions: [String: String] = [:]
            for platform in platforms {
                activeSDKVersions[platform] = await activeSDKVersion(for: platform)
            }

            for runtime in deletable {
                let size = runtime.sizeBytes ?? 0
                let platform = runtime.runtimeIdentifier.map(Self.platformName) ?? "Runtime"
                let isUsedByXcode = activeSDKVersions[platform].map {
                    Self.majorMinor(runtime.version ?? "") == Self.majorMinor($0)
                } ?? false
                let name = [
                    platform,
                    runtime.version,
                    runtime.build.map { "(\($0))" },
                    isUsedByXcode ? "— used by current Xcode" : nil,
                ].compactMap { $0 }.joined(separator: " ")
                result.items.append(CleanupItem(
                    id: "simctl.runtime.\(runtime.identifier)",
                    rule: rule,
                    displayName: name,
                    url: nil,
                    action: .runTool(simctl(["runtime", "delete", runtime.identifier])),
                    sizeInBytes: size,
                    lastModified: runtime.lastUsedAt.flatMap { try? Date($0, strategy: .iso8601) }
                ))
            }
        } catch {
            result.issues.append(ScanIssue(subject: "Simulator runtimes", message: "Unexpected simctl output: \(error.localizedDescription)"))
        }
        return result
    }

    private func activeSDKVersion(for platform: String) async -> String? {
        guard let sdk = Self.simulatorSDKs[platform] else { return nil }
        let invocation = ToolInvocation(executable: xcrun, arguments: ["--sdk", sdk, "--show-sdk-version"])
        guard let output = try? await runner.run(invocation, timeout: 15), output.exitCode == 0 else { return nil }
        let version = String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// `26.3.1` → `26.3`
    static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    private func simctl(_ arguments: [String]) -> ToolInvocation {
        ToolInvocation(executable: xcrun, arguments: ["simctl"] + arguments)
    }

    private func runSimctl(_ arguments: [String], into result: inout ToolLocateResult) async -> Data? {
        do {
            let output = try await runner.run(simctl(arguments), timeout: 60)
            if output.exitCode == 0 { return output.standardOutput }
            // Command Line Tools without Xcode have no simctl; that is not worth reporting.
            if !output.errorText.contains("unable to find utility") {
                result.issues.append(ScanIssue(subject: "Simulators", message: output.errorText))
            }
        } catch {
            result.issues.append(ScanIssue(subject: "Simulators", message: error.localizedDescription))
        }
        return nil
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-0` → `iOS 17.0`
    static func runtimeName(_ runtimeIdentifier: String) -> String {
        let suffix = runtimeIdentifier.components(separatedBy: "SimRuntime.").last ?? runtimeIdentifier
        let parts = suffix.split(separator: "-")
        guard let platform = parts.first else { return suffix }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    static func platformName(_ runtimeIdentifier: String) -> String {
        runtimeName(runtimeIdentifier).split(separator: " ").first.map(String.init) ?? runtimeIdentifier
    }
}

// MARK: - Docker

struct DockerToolProvider: Sendable {
    let docker: URL
    let runner: any ToolRunner

    private struct SystemDFRow: Decodable {
        let type: String
        let reclaimable: String

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case reclaimable = "Reclaimable"
        }
    }

    func items(for bindings: [(DockerResource, CleanupRule)]) async -> ToolLocateResult {
        var result = ToolLocateResult()
        let invocation = ToolInvocation(executable: docker, arguments: ["system", "df", "--format", "{{json .}}"])
        let output: ToolOutput
        do {
            output = try await runner.run(invocation, timeout: 30)
        } catch {
            result.issues.append(ScanIssue(subject: "Docker", message: error.localizedDescription))
            return result
        }
        guard output.exitCode == 0 else {
            result.issues.append(ScanIssue(subject: "Docker", message: "Docker is not reachable (is it running?): \(output.errorText)"))
            return result
        }

        let decoder = JSONDecoder()
        let rows = String(decoding: output.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { try? decoder.decode(SystemDFRow.self, from: Data($0.utf8)) }
        let reclaimableByType = Dictionary(rows.map { ($0.type, Self.parseSize($0.reclaimable) ?? 0) }, uniquingKeysWith: max)

        for (resource, rule) in bindings {
            let bytes = reclaimableByType[resource.systemDFType] ?? 0
            guard bytes > 0 else { continue }
            result.items.append(CleanupItem(
                id: "docker.\(resource.rawValue)",
                rule: rule,
                displayName: resource.displayName,
                url: nil,
                action: .runTool(ToolInvocation(executable: docker, arguments: resource.pruneArguments)),
                sizeInBytes: bytes,
                lastModified: nil
            ))
        }
        return result
    }

    /// Parses Docker's decimal human sizes such as `1.199GB (33%)`, `48.75MB`, `12kB` or `0B`.
    static func parseSize(_ text: String) -> Int64? {
        guard let token = text.split(separator: " ").first else { return nil }
        let units: [(suffix: String, multiplier: Double)] = [
            ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1),
        ]
        for unit in units where token.hasSuffix(unit.suffix) {
            guard let value = Double(token.dropLast(unit.suffix.count)) else { return nil }
            return Int64(value * unit.multiplier)
        }
        return nil
    }
}
