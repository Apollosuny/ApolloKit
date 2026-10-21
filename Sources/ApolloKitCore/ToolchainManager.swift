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
            let alias = readFile(".nvm/alias/default", in: homeDirectory)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let digits = alias.hasPrefix("v") ? String(alias.dropFirst()) : alias
            if let first = digits.first, first.isNumber {
                let prefix = "v" + digits
                let matching = installed.filter { $0 == prefix || $0.hasPrefix(prefix + ".") }
                if let newestMatching = Self.newest(matching) { return [newestMatching] }
            }
            // `node`, `lts/*`, `stable` or no alias: nvm resolves to the newest installed version.
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
