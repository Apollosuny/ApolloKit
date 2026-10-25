import Foundation

/// Built-in cleanup rules. Specific rules take precedence over generic `childrenOf` rules:
/// a child of `~/Library/Caches` claimed by e.g. the Homebrew rule is never reported by the generic rule.
public enum RuleCatalog {
    public static let all: [CleanupRule] =
        system + apps + xcode + packageManagers + toolchains + editors + docker + projectArtifacts + largeFiles

    public static func rule(id: String) -> CleanupRule? {
        all.first { $0.id == id }
    }

    // MARK: - System

    static let system: [CleanupRule] = [
        CleanupRule(
            id: "system.userCaches", title: "Application Caches",
            detail: "Per-app caches in ~/Library/Caches. Apps rebuild them on demand. Folders holding programs are marked Caution.",
            group: .system, risk: .safe, locators: [.children("Library/Caches")],
            inspectsForPrograms: true
        ),
        CleanupRule(
            id: "system.userLogs", title: "User Logs",
            detail: "Log files and diagnostic reports in ~/Library/Logs.",
            group: .system, risk: .safe, locators: [.children("Library/Logs")]
        ),
        CleanupRule(
            id: "system.trash", title: "Trash",
            detail: "Items already in the Trash. Always deleted permanently. Requires Full Disk Access.",
            group: .system, risk: .caution, locators: [.children(".Trash")],
            alwaysDeletePermanently: true
        ),
    ]

    // MARK: - Browsers & apps

    private static let chromiumBrowsers: [(path: String, label: String)] = [
        ("Library/Application Support/Google/Chrome", "Chrome"),
        ("Library/Application Support/Arc/User Data", "Arc"),
        ("Library/Application Support/BraveSoftware/Brave-Browser", "Brave"),
        ("Library/Application Support/Microsoft Edge", "Edge"),
        ("Library/Application Support/Chromium", "Chromium"),
        ("Library/Application Support/Vivaldi", "Vivaldi"),
    ]

    /// Electron apps keep Chromium caches next to their real data in Application Support.
    private static let electronApps = [
        "Slack", "discord", "Notion/Partitions/notion", "Postman", "Figma", "Microsoft Teams",
        "Claude", "obsidian", "Linear", "Spotify", "WhatsApp",
    ]

    private static let chromiumCacheFolders = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]
    private static let serviceWorkerCacheFolders = ["Service Worker/CacheStorage", "Service Worker/ScriptCache"]

    static let apps: [CleanupRule] = [
        CleanupRule(
            id: "apps.browserCaches", title: "Browser Code & GPU Caches",
            detail: "Per-profile compiled script and GPU shader caches of Chromium browsers.",
            group: .apps, risk: .safe,
            locators: chromiumBrowsers.map {
                RuleLocator.eachChild(homeRelativePath: $0.path, subpaths: ["Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"], label: $0.label)
            } + [.dir("Library/Application Support/Google/Chrome/component_crx_cache")]
        ),
        CleanupRule(
            id: "apps.electronCaches", title: "Electron App Caches",
            detail: "HTTP, script and GPU caches of Slack, Discord, Notion, Postman, Figma, Teams and similar apps.",
            group: .apps, risk: .safe,
            locators: electronApps.flatMap { app in
                chromiumCacheFolders.map { RuleLocator.dir("Library/Application Support/\(app)/\($0)") }
            }
        ),
        CleanupRule(
            id: "apps.serviceWorkerCaches", title: "Service Worker Caches",
            detail: "Offline caches of web apps in browsers and Electron apps. Pages may need to reload content; offline copies are lost.",
            group: .apps, risk: .caution,
            locators: chromiumBrowsers.map {
                RuleLocator.eachChild(homeRelativePath: $0.path, subpaths: serviceWorkerCacheFolders, label: $0.label)
            } + electronApps.flatMap { app in
                serviceWorkerCacheFolders.map { RuleLocator.dir("Library/Application Support/\(app)/\($0)") }
            }
        ),
        CleanupRule(
            id: "apps.chromeOnDeviceModel", title: "Chrome On-Device AI Model",
            detail: "Gemini Nano model used by Chrome's built-in AI features. Re-downloaded when a feature needs it.",
            group: .apps, risk: .caution,
            locators: [.dir("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel")]
        ),
        CleanupRule(
            id: "apps.leftovers", title: "Leftovers of Removed Apps",
            detail: "Data of developer apps that are no longer installed (OrbStack, Docker Desktop, Android Studio).",
            group: .apps, risk: .caution,
            locators: [
                .leftover(homeRelativePath: "Library/Group Containers/HUAQ24HBR6.dev.orbstack", appBundleNames: ["OrbStack.app"]),
                .leftover(homeRelativePath: ".orbstack", appBundleNames: ["OrbStack.app"]),
                .leftover(homeRelativePath: "Library/Containers/com.docker.docker", appBundleNames: ["Docker.app"]),
                .leftover(homeRelativePath: "Library/Group Containers/group.com.docker", appBundleNames: ["Docker.app"]),
                .leftover(homeRelativePath: "Library/Application Support/Google/AndroidStudio", appBundleNames: ["Android Studio.app"]),
            ]
        ),
        CleanupRule(
            id: "apps.iosSoftwareUpdates", title: "iOS Software Updates",
            detail: "Firmware files downloaded by Finder when updating or restoring devices.",
            group: .apps, risk: .safe,
            locators: [.dir("Library/iTunes/iPhone Software Updates"), .dir("Library/iTunes/iPad Software Updates")]
        ),
        CleanupRule(
            id: "apps.iosBackups", title: "iPhone & iPad Backups",
            detail: "Local device backups made by Finder. They may be the only copy of a device's data. Requires Full Disk Access.",
            group: .apps, risk: .caution,
            locators: [.children("Library/Application Support/MobileSync/Backup")],
            enabledByDefault: false
        ),
    ]

    // MARK: - Xcode

    static let xcode: [CleanupRule] = [
        CleanupRule(
            id: "xcode.derivedData", title: "Xcode DerivedData",
            detail: "Build intermediates and indexes. Xcode rebuilds them on the next build.",
            group: .xcode, risk: .safe, locators: [.children("Library/Developer/Xcode/DerivedData")]
        ),
        CleanupRule(
            id: "xcode.archives", title: "Xcode Archives",
            detail: "App archives including dSYMs needed to symbolicate crash reports of shipped builds.",
            group: .xcode, risk: .caution, locators: [.children("Library/Developer/Xcode/Archives")]
        ),
        CleanupRule(
            id: "xcode.deviceSupport", title: "Device Support Files",
            detail: "Debug symbols per OS version, re-copied when a device is connected again.",
            group: .xcode, risk: .safe,
            locators: [
                .children("Library/Developer/Xcode/iOS DeviceSupport"),
                .children("Library/Developer/Xcode/watchOS DeviceSupport"),
                .children("Library/Developer/Xcode/tvOS DeviceSupport"),
                .children("Library/Developer/Xcode/visionOS DeviceSupport"),
                .children("Library/Developer/Xcode/macOS DeviceSupport"),
            ]
        ),
        CleanupRule(
            id: "xcode.previews", title: "SwiftUI Previews",
            detail: "Preview simulator data, recreated when previews run.",
            group: .xcode, risk: .safe, locators: [.dir("Library/Developer/Xcode/UserData/Previews")]
        ),
        CleanupRule(
            id: "xcode.simulatorCaches", title: "Simulator Caches",
            detail: "CoreSimulator dyld and runtime caches.",
            group: .xcode, risk: .safe, locators: [.dir("Library/Developer/CoreSimulator/Caches")]
        ),
        CleanupRule(
            id: "xcode.unavailableSimulators", title: "Unavailable Simulators",
            detail: "Simulator devices whose runtime is no longer installed. Removed with simctl delete.",
            group: .xcode, risk: .safe, locators: [.tool(.unavailableSimulators)]
        ),
        CleanupRule(
            id: "xcode.simulatorDeviceData", title: "Simulator Device Data",
            detail: "Apps and data inside shut-down simulators. Erased with simctl erase; the device stays in Xcode, reset to factory state.",
            group: .xcode, risk: .caution, locators: [.tool(.simulatorDeviceData)]
        ),
        CleanupRule(
            id: "xcode.testDevices", title: "XCTest Device Clones",
            detail: "Simulator clones created for parallel testing. Xcode recreates them on the next test run.",
            group: .xcode, risk: .safe, locators: [.children("Library/Developer/XCTestDevices")]
        ),
        CleanupRule(
            id: "xcode.deviceLogs", title: "Device Logs",
            detail: "Logs and crash reports copied from connected devices.",
            group: .xcode, risk: .safe, locators: [.dir("Library/Developer/Xcode/iOS Device Logs")]
        ),
        CleanupRule(
            id: "xcode.simulatorRuntimes", title: "Simulator Runtimes",
            detail: "Installed simulator runtimes. Re-download from Xcode › Settings › Components. Removed with simctl runtime delete.",
            group: .xcode, risk: .caution, locators: [.tool(.simulatorRuntimes)]
        ),
        CleanupRule(
            id: "xcode.documentationCache", title: "Documentation Cache",
            detail: "Downloaded developer documentation index.",
            group: .xcode, risk: .safe, locators: [.dir("Library/Developer/Xcode/DocumentationCache")]
        ),
        CleanupRule(
            id: "xcode.swiftpm", title: "Swift Package Manager Cache",
            detail: "Cached package repositories and artifacts.",
            group: .xcode, risk: .safe, locators: [.dir("Library/Caches/org.swift.swiftpm")]
        ),
        CleanupRule(
            id: "xcode.cocoapods", title: "CocoaPods Cache",
            detail: "Downloaded pod sources and specs.",
            group: .xcode, risk: .safe, locators: [.dir("Library/Caches/CocoaPods")]
        ),
        CleanupRule(
            id: "xcode.carthage", title: "Carthage Cache",
            detail: "Downloaded Carthage dependencies.",
            group: .xcode, risk: .safe, locators: [.dir("Library/Caches/org.carthage.CarthageKit")]
        ),
    ]

    // MARK: - Package managers

    static let packageManagers: [CleanupRule] = [
        CleanupRule(
            id: "pkg.npm", title: "npm Cache", detail: "Content-addressable npm download cache.",
            group: .packageManagers, risk: .safe, locators: [.dir(".npm/_cacache")]
        ),
        CleanupRule(
            id: "pkg.yarn", title: "Yarn Cache", detail: "Yarn classic and Berry global caches.",
            group: .packageManagers, risk: .safe,
            locators: [.dir("Library/Caches/Yarn"), .dir(".yarn/berry/cache")]
        ),
        CleanupRule(
            id: "pkg.pnpm", title: "pnpm Store",
            detail: "Global content store. Projects re-link packages on the next install.",
            group: .packageManagers, risk: .caution, locators: [.dir("Library/pnpm/store")]
        ),
        CleanupRule(
            id: "pkg.bun", title: "Bun Cache", detail: "Bun install cache.",
            group: .packageManagers, risk: .safe, locators: [.dir(".bun/install/cache")]
        ),
        CleanupRule(
            id: "pkg.homebrew", title: "Homebrew Cache", detail: "Downloaded bottles and source tarballs.",
            group: .packageManagers, risk: .safe, locators: [.dir("Library/Caches/Homebrew")]
        ),
        CleanupRule(
            id: "pkg.gradleCaches", title: "Gradle Caches", detail: "Dependency and build caches in ~/.gradle/caches.",
            group: .packageManagers, risk: .safe, locators: [.dir(".gradle/caches")]
        ),
        CleanupRule(
            id: "pkg.gradleWrapper", title: "Gradle Wrapper Distributions",
            detail: "Downloaded Gradle versions, re-downloaded per project when needed.",
            group: .packageManagers, risk: .caution, locators: [.children(".gradle/wrapper/dists", label: "Gradle")]
        ),
        CleanupRule(
            id: "pkg.gradleDaemon", title: "Gradle Daemon Logs", detail: "Daemon logs and registries in ~/.gradle/daemon.",
            group: .packageManagers, risk: .safe, locators: [.dir(".gradle/daemon")]
        ),
        CleanupRule(
            id: "pkg.maven", title: "Maven Repository", detail: "Local Maven repository (~/.m2/repository).",
            group: .packageManagers, risk: .caution, locators: [.dir(".m2/repository")]
        ),
        CleanupRule(
            id: "pkg.cargo", title: "Cargo Registry & Git Cache", detail: "Downloaded crates and git checkouts.",
            group: .packageManagers, risk: .safe,
            locators: [.dir(".cargo/registry/cache"), .dir(".cargo/registry/src"), .dir(".cargo/git/checkouts")]
        ),
        CleanupRule(
            id: "pkg.goBuild", title: "Go Build Cache", detail: "Compiled package cache (go-build).",
            group: .packageManagers, risk: .safe, locators: [.dir("Library/Caches/go-build")]
        ),
        CleanupRule(
            id: "pkg.goModules", title: "Go Module Cache", detail: "Downloaded modules in ~/go/pkg/mod.",
            group: .packageManagers, risk: .caution, locators: [.dir("go/pkg/mod")]
        ),
        CleanupRule(
            id: "pkg.python", title: "Python Package Caches", detail: "pip, uv and Poetry download caches.",
            group: .packageManagers, risk: .safe,
            locators: [.dir("Library/Caches/pip"), .dir(".cache/uv"), .dir("Library/Caches/pypoetry")]
        ),
        CleanupRule(
            id: "pkg.composer", title: "Composer Cache", detail: "PHP Composer download cache.",
            group: .packageManagers, risk: .safe,
            locators: [.dir("Library/Caches/composer"), .dir(".composer/cache")]
        ),
        CleanupRule(
            id: "pkg.pub", title: "Dart / Flutter Pub Cache", detail: "Hosted and git packages in ~/.pub-cache.",
            group: .packageManagers, risk: .caution, locators: [.dir(".pub-cache")]
        ),
        CleanupRule(
            id: "pkg.nodeTooling", title: "Node Tooling Caches",
            detail: "node-gyp headers, Deno, Electron and electron-builder downloads.",
            group: .packageManagers, risk: .safe,
            locators: [
                .dir("Library/Caches/node-gyp"), .dir(".node-gyp"), .dir("Library/Caches/deno"),
                .dir("Library/Caches/electron"), .dir("Library/Caches/electron-builder"),
            ]
        ),
        CleanupRule(
            id: "pkg.nuget", title: "NuGet Packages", detail: ".NET global packages folder. Restored by dotnet restore.",
            group: .packageManagers, risk: .safe, locators: [.dir(".nuget/packages")]
        ),
        CleanupRule(
            id: "pkg.cocoapodsRepos", title: "CocoaPods Spec Repos", detail: "Cloned spec repositories in ~/.cocoapods/repos.",
            group: .packageManagers, risk: .safe, locators: [.dir(".cocoapods/repos")]
        ),
        CleanupRule(
            id: "pkg.xdgCache", title: "Other CLI Caches",
            detail: "Per-tool caches in ~/.cache (Prisma, pre-commit, Solana, corepack, …). Tools rebuild them on demand. Folders holding programs are marked Caution.",
            group: .packageManagers, risk: .safe, locators: [.children(".cache")],
            inspectsForPrograms: true
        ),
        CleanupRule(
            id: "pkg.browsers", title: "Test Browser Binaries",
            detail: "Playwright, Puppeteer and Cypress browser downloads.",
            group: .packageManagers, risk: .caution,
            locators: [.dir("Library/Caches/ms-playwright"), .dir(".cache/puppeteer"), .dir("Library/Caches/Cypress")]
        ),
    ]

    // MARK: - Toolchains & models

    static let toolchains: [CleanupRule] = [
        CleanupRule(
            id: "toolchain.rust", title: "Rust Toolchains",
            detail: "Installed rustup toolchains. The default toolchain is never listed; pinned projects reinstall theirs.",
            group: .toolchains, risk: .caution, locators: [.toolchainVersions(.rustup)]
        ),
        CleanupRule(
            id: "toolchain.node", title: "Node.js Versions (nvm)",
            detail: "Node versions installed with nvm. The default version is never listed.",
            group: .toolchains, risk: .caution, locators: [.toolchainVersions(.nvm)]
        ),
        CleanupRule(
            id: "toolchain.python", title: "Python Versions (pyenv)",
            detail: "Python versions installed with pyenv. The global version is never listed; virtualenvs built on a removed version break.",
            group: .toolchains, risk: .caution, locators: [.toolchainVersions(.pyenv)]
        ),
        CleanupRule(
            id: "toolchain.ruby", title: "Ruby Versions (rbenv)",
            detail: "Ruby versions installed with rbenv. The global version is never listed.",
            group: .toolchains, risk: .caution, locators: [.toolchainVersions(.rbenv)]
        ),
        CleanupRule(
            id: "toolchain.androidSDK", title: "Android System Images & NDKs",
            detail: "Emulator system images and NDK versions. Reinstall from Android Studio's SDK Manager.",
            group: .toolchains, risk: .caution,
            locators: [
                .children("Library/Android/sdk/system-images", label: "System image"),
                .children("Library/Android/sdk/ndk", label: "NDK"),
            ]
        ),
        CleanupRule(
            id: "toolchain.aiModels", title: "Local AI Models",
            detail: "Downloaded models for Hugging Face, Ollama and LM Studio. Large to download again.",
            group: .toolchains, risk: .caution,
            locators: [.dir(".cache/huggingface"), .dir(".ollama/models"), .dir(".lmstudio/models"), .dir(".cache/lm-studio")]
        ),
    ]

    // MARK: - Editors & tooling

    static let editors: [CleanupRule] = [
        CleanupRule(
            id: "editor.vscode", title: "VS Code-based Editor Caches",
            detail: "Electron caches, cached extension packages and logs.",
            group: .editors, risk: .safe,
            locators: ["Code", "Cursor", "Windsurf", "VSCodium", "Antigravity IDE"].flatMap { app in
                ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"]
                    .map { RuleLocator.dir("Library/Application Support/\(app)/\($0)") }
            }
        ),
        CleanupRule(
            id: "editor.jetbrains", title: "JetBrains IDE Caches",
            detail: "Per-IDE index and system caches (IntelliJ IDEA, WebStorm, GoLand, …).",
            group: .editors, risk: .safe,
            locators: [.children("Library/Caches/JetBrains")]
        ),
        CleanupRule(
            id: "editor.androidCache", title: "Android Tooling Cache", detail: "~/.android/cache downloads.",
            group: .editors, risk: .safe, locators: [.dir(".android/cache")]
        ),
        CleanupRule(
            id: "editor.androidAVD", title: "Android Emulators",
            detail: "Android Virtual Devices. Removing one deletes the emulator and its data.",
            group: .editors, risk: .caution, locators: [.children(".android/avd", label: "AVD")],
            enabledByDefault: false
        ),
    ]

    // MARK: - Docker

    /// Space is freed inside Docker's VM disk; Docker Desktop returns it to macOS gradually.
    static let docker: [CleanupRule] = [
        CleanupRule(
            id: "docker.buildCache", title: "Docker Build Cache",
            detail: "BuildKit cache. Next builds are slower until it warms up again. docker builder prune --all.",
            group: .docker, risk: .safe, locators: [.tool(.docker(.buildCache))]
        ),
        CleanupRule(
            id: "docker.images", title: "Docker Unused Images",
            detail: "Images not used by any container. Pulled or rebuilt again on demand. docker image prune --all.",
            group: .docker, risk: .caution, locators: [.tool(.docker(.unusedImages))]
        ),
        CleanupRule(
            id: "docker.containers", title: "Docker Stopped Containers",
            detail: "Stopped containers; changes inside their filesystem are lost. docker container prune.",
            group: .docker, risk: .caution, locators: [.tool(.docker(.stoppedContainers))]
        ),
        CleanupRule(
            id: "docker.volumes", title: "Docker Unused Volumes",
            detail: "Every volume not attached to a container, including named volumes that may hold databases. docker volume prune --all.",
            group: .docker, risk: .caution, locators: [.tool(.docker(.unusedVolumes))],
            enabledByDefault: false
        ),
    ]

    // MARK: - Project artifacts

    private static let nodeMarkers = ["package.json"]
    private static let gradleMarkers = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    static let projectArtifacts: [CleanupRule] = [
        CleanupRule(
            id: "project.nodeModules", title: "node_modules",
            detail: "Installed JavaScript dependencies. Restore with npm/yarn/pnpm/bun install.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact("node_modules", parent: nodeMarkers)]
        ),
        CleanupRule(
            id: "project.jsBuildCaches", title: "JS Framework Caches",
            detail: "Next.js, Nuxt, Turborepo, Parcel, SvelteKit and Angular build caches.",
            group: .projectArtifacts, risk: .safe,
            locators: [".next", ".nuxt", ".output", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", ".expo", ".docusaurus", ".cache"]
                .map { RuleLocator.artifact($0, parent: nodeMarkers) }
                + [.artifact(".nx", parent: ["nx.json"])]
        ),
        CleanupRule(
            id: "project.swiftBuild", title: "SwiftPM .build",
            detail: "Swift package build directories.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact(".build", parent: ["Package.swift"])]
        ),
        CleanupRule(
            id: "project.pods", title: "CocoaPods Pods",
            detail: "Installed pods. Restore with pod install.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact("Pods", parent: ["Podfile"])]
        ),
        CleanupRule(
            id: "project.rustTarget", title: "Rust target",
            detail: "Cargo build output.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact("target", parent: ["Cargo.toml"])]
        ),
        CleanupRule(
            id: "project.mavenTarget", title: "Maven target",
            detail: "Maven build output.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact("target", parent: ["pom.xml"])]
        ),
        CleanupRule(
            id: "project.gradleBuild", title: "Gradle build",
            detail: "Gradle/Android build output and project caches.",
            group: .projectArtifacts, risk: .safe,
            locators: ["build", ".gradle", ".cxx", ".externalNativeBuild"].map { RuleLocator.artifact($0, parent: gradleMarkers) }
        ),
        CleanupRule(
            id: "project.flutter", title: "Flutter / Dart build",
            detail: ".dart_tool and build output of Dart projects.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact(".dart_tool", parent: ["pubspec.yaml"]), .artifact("build", parent: ["pubspec.yaml"])]
        ),
        CleanupRule(
            id: "project.pythonCaches", title: "Python Caches",
            detail: "__pycache__, pytest, mypy and ruff caches.",
            group: .projectArtifacts, risk: .safe,
            locators: [
                .artifact("__pycache__"),
                .artifact(".pytest_cache", content: ["CACHEDIR.TAG", "README.md"]),
                .artifact(".mypy_cache", content: ["CACHEDIR.TAG"]),
                .artifact(".ruff_cache", content: ["CACHEDIR.TAG"]),
                .artifact(".tox", parent: ["tox.ini", "pyproject.toml"]),
                .artifact(".nox", parent: ["noxfile.py"]),
            ]
        ),
        CleanupRule(
            id: "project.pythonVenv", title: "Python Virtualenvs",
            detail: "Virtual environments. Recreate and reinstall requirements afterwards.",
            group: .projectArtifacts, risk: .caution,
            locators: [".venv", "venv"].map { RuleLocator.artifact($0, content: ["pyvenv.cfg"]) }
        ),
        CleanupRule(
            id: "project.elixir", title: "Elixir _build & deps",
            detail: "Mix build output and fetched dependencies.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact("_build", parent: ["mix.exs"]), .artifact("deps", parent: ["mix.exs"])]
        ),
        CleanupRule(
            id: "project.zig", title: "Zig Cache",
            detail: "Zig compiler caches.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact(".zig-cache", parent: ["build.zig"]), .artifact("zig-cache", parent: ["build.zig"])]
        ),
        CleanupRule(
            id: "project.dotnet", title: ".NET bin & obj",
            detail: "MSBuild output of .NET projects. Rebuilt by dotnet build.",
            group: .projectArtifacts, risk: .safe,
            locators: ["bin", "obj"].map { RuleLocator.artifact($0, parent: ["*.csproj", "*.fsproj", "*.vbproj"]) }
        ),
        CleanupRule(
            id: "project.haskell", title: "Haskell Build Output",
            detail: "Stack .stack-work and Cabal dist-newstyle directories.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact(".stack-work", parent: ["stack.yaml"]), .artifact("dist-newstyle", parent: ["cabal.project", "*.cabal"])]
        ),
        CleanupRule(
            id: "project.elm", title: "Elm elm-stuff",
            detail: "Elm compiler output.",
            group: .projectArtifacts, risk: .safe,
            locators: [.artifact("elm-stuff", parent: ["elm.json"])]
        ),
        CleanupRule(
            id: "project.cloudBuild", title: "Cloud Deploy Artifacts",
            detail: "AWS CDK cdk.out, Serverless .serverless and Cloudflare .wrangler build output.",
            group: .projectArtifacts, risk: .safe,
            locators: [
                .artifact("cdk.out", parent: ["cdk.json"]),
                .artifact(".serverless", parent: ["serverless.yml", "serverless.yaml", "serverless.ts"]),
                .artifact(".wrangler", parent: ["wrangler.toml", "wrangler.json", "wrangler.jsonc"]),
            ]
        ),
        CleanupRule(
            id: "project.terraform", title: "Terraform Providers",
            detail: ".terraform provider plugins and modules. Restore with terraform init.",
            group: .projectArtifacts, risk: .caution,
            locators: [.artifact(".terraform", parent: [".terraform.lock.hcl", "main.tf"])]
        ),
    ]

    // MARK: - Large & old files

    private static let largeFileNote = "Your own files, so nothing is pre-selected. Files in iCloud-synced Desktop or Documents are removed from iCloud too."

    static let largeFiles: [CleanupRule] = [
        CleanupRule(
            id: "files.installers", title: "Installers",
            detail: "Disk images and installer packages (.dmg, .pkg), usually not needed once the app is installed. \(largeFileNote)",
            group: .largeFiles, risk: .caution, locators: [.largeFiles("dmg", "pkg", "mpkg")]
        ),
        CleanupRule(
            id: "files.archives", title: "Archives",
            detail: "Compressed archives (.zip, .tar.gz, .7z, .rar), often already extracted. \(largeFileNote)",
            group: .largeFiles, risk: .caution,
            locators: [.largeFiles("zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "7z", "rar")]
        ),
        CleanupRule(
            id: "files.videos", title: "Videos & Recordings",
            detail: "Screen recordings and video files. \(largeFileNote)",
            group: .largeFiles, risk: .caution,
            locators: [.largeFiles("mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv")]
        ),
        CleanupRule(
            id: "files.virtualMachines", title: "Disk Images & Virtual Machines",
            detail: "OS images and virtual machine bundles (.iso, .img, .utm, .vmwarevm, .pvm). \(largeFileNote)",
            group: .largeFiles, risk: .caution,
            locators: [.largeFiles(
                "iso", "img", "vmdk", "vdi", "vhd", "vhdx", "qcow2", "sparseimage", "sparsebundle", "utm", "pvm", "vmwarevm"
            )]
        ),
        CleanupRule(
            id: "files.appBuilds", title: "App Builds",
            detail: "Exported app builds and archives outside Xcode's folders (.ipa, .apk, .aab, .xcarchive). \(largeFileNote)",
            group: .largeFiles, risk: .caution, locators: [.largeFiles("ipa", "apk", "aab", "xcarchive")]
        ),
        CleanupRule(
            id: "files.other", title: "Other Large Files",
            detail: "Any other file above the size threshold. \(largeFileNote)",
            group: .largeFiles, risk: .caution, locators: [.largeFile(extensions: [])]
        ),
    ]
}
