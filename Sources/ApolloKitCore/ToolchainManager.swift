import Foundation

/// Version managers whose installed versions live in one folder per version.
public enum ToolchainManager: String, Sendable, Hashable, CaseIterable {
    case rustup
    case nvm
    case pyenv
    case rbenv

    var versionsHomeRelativePath: String {
        switch self {
        case .rustup: ".rustup/toolchains"
        case .nvm: ".nvm/versions/node"
        case .pyenv: ".pyenv/versions"
        case .rbenv: ".rbenv/versions"
        }
    }

    /// Installed version folders that must be kept because they are the configured default.
    /// When the default cannot be determined, the newest version is kept so the tool keeps working.
    func protectedVersions(installed: [String], homeDirectory: URL) -> Set<String> {
        switch self {
        case .rustup:
            guard let settings = readFile(".rustup/settings.toml", in: homeDirectory),
                  let toolchain = Self.tomlString(named: "default_toolchain", in: settings) else {
                return Set(Self.newest(installed).map { [$0] } ?? [])
            }
            // `stable` matches `stable-aarch64-apple-darwin`.
            return Set(installed.filter { $0 == toolchain || $0.hasPrefix(toolchain + "-") })

        case .nvm:
            if let digits = resolveNVMAlias("default", homeDirectory: homeDirectory) {
                let prefix = "v" + digits
                let matching = installed.filter { $0 == prefix || $0.hasPrefix(prefix + ".") }
                if let newestMatching = Self.newest(matching) { return [newestMatching] }
            }
            // `node`, `stable`, no alias or an alias to a version that is not installed: keep the newest.
            return Set(Self.newest(installed).map { [$0] } ?? [])

        case .pyenv, .rbenv:
            let file = self == .pyenv ? ".pyenv/version" : ".rbenv/version"
            let versions = (readFile(file, in: homeDirectory) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "system" }
            return Set(versions).intersection(installed)
        }
    }

    /// Packages installed globally into one version (`npm install -g`). They live inside the version
    /// folder, so removing the version removes the commands too. Bundled package managers are left out.
    func globalTools(in versionDirectory: URL) -> [String] {
        guard self == .nvm else { return [] }
        let modules = versionDirectory.appendingPathComponent("lib/node_modules")
        let bundled: Set<String> = ["npm", "corepack"]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: modules.path)) ?? []
        return entries.flatMap { entry -> [String] in
            if entry.hasPrefix(".") || bundled.contains(entry) { return [] }
            guard entry.hasPrefix("@") else { return [entry] }
            let scoped = (try? FileManager.default.contentsOfDirectory(atPath: modules.appendingPathComponent(entry).path)) ?? []
            return scoped.filter { !$0.hasPrefix(".") }.map { "\(entry)/\($0)" }
        }
        .sorted()
    }

    /// Follows nvm's alias files (`default` → `lts/*` → `lts/krypton` → `v24.11.1`) to a version prefix
    /// without the `v`. `nil` for `node`, `stable` and anything that does not end in a version.
    private func resolveNVMAlias(_ name: String, homeDirectory: URL) -> String? {
        var alias = name
        for _ in 0..<8 {
            guard !alias.contains(".."),
                  let value = readFile(".nvm/alias/\(alias)", in: homeDirectory)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }
            let digits = value.hasPrefix("v") ? String(value.dropFirst()) : value
            if let first = digits.first, first.isNumber { return digits }
            alias = value
        }
        return nil
    }

    private func readFile(_ homeRelativePath: String, in homeDirectory: URL) -> String? {
        try? String(contentsOf: homeDirectory.appendingPathComponent(homeRelativePath), encoding: .utf8)
    }

    static func tomlString(named key: String, in toml: String) -> String? {
        for line in toml.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func newest(_ versions: [String]) -> String? {
        versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }
}
