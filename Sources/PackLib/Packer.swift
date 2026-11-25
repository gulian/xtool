import Foundation
import XUtils
import Subprocess
import AssetKit

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan
    private let sdkBuildInfo: SDKBuildInfo?

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.init(buildSettings: buildSettings, plan: plan, sdkBuildInfo: (try? DarwinSDK.current())?.buildInfo)
    }

    package init(buildSettings: BuildSettings, plan: Plan, sdkBuildInfo: SDKBuildInfo?) {
        self.plan = plan
        self.buildSettings = buildSettings
        self.sdkBuildInfo = sdkBuildInfo
    }

    /// Environment variable that sets `BuildMachineOSBuild` (e.g. `25G83`) in the packed Info.plists.
    package static let buildMachineOSBuildVariable = "XTOOL_BUILD_MACHINE_OS_BUILD"

    /// Value stamped for `BuildMachineOSBuild`, the build number of the macOS that ran the build.
    ///
    /// Xcode always sets it, but a Linux host has no honest value, so by default the key is omitted
    /// (SwiftBuild drops it when empty). If App Store Connect turns out to require it, change
    /// the default here, or set the environment variable to try a value without rebuilding.
    package static func buildMachineOSBuild(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        environment[buildMachineOSBuildVariable].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Adds the Apple build keys (`DTXcode`, `DTSDKBuild`, ...) to `info`.
    ///
    /// Keys that are already present, e.g. from the user's own Info.plist, are never overwritten.
    package static func stampBuildInfo(
        _ buildInfo: SDKBuildInfo,
        buildMachineOSBuild: String?,
        into info: inout [String: any Sendable]
    ) {
        let keys = buildInfo.infoPlistKeys(buildMachineOSBuild: buildMachineOSBuild)
        for (key, value) in keys where info[key] == nil {
            info[key] = value
        }
    }

    /// Whether the Apple build keys apply: they describe the iPhoneOS SDK, so device builds only.
    static func stampsBuildInfo(for triple: String) -> Bool {
        cfBundleSupportedPlatforms(for: triple) == ["iPhoneOS"]
    }

    private func warnAboutBuildInfo() {
        guard Self.stampsBuildInfo(for: buildSettings.triple) else { return }
        let message: String?
        if let sdkBuildInfo {
            let missing = sdkBuildInfo.missingFields
            message = missing.isEmpty ? nil : """
            warning: the Darwin SDK is missing build information (\(missing.joined(separator: ", "))), \
            so some DT* keys are omitted from Info.plist. App Store Connect may reject the build.
            """
        } else if (try? DarwinSDK.current()) != nil {
            message = """
            warning: the installed Darwin SDK does not record its Xcode build information, so the DT* \
            keys are omitted from Info.plist. App Store Connect may reject the build. \
            Reinstall the SDK with `xtool sdk install` to add them.
            """
        } else {
            message = nil
        }
        if let message {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }

    /// Linker flags that make clang read the SDK's `SDKSettings.json`.
    ///
    /// swiftc links through clang but hands it `--sysroot <SDK>`. Clang's Darwin driver only derives the
    /// SDK version from `-isysroot`, so without this the `-platform_version` it gives the linker has
    /// the deployment target in the SDK slot, and `LC_BUILD_VERSION.sdk` ends up equal to `minos`
    /// (e.g. 17.0 instead of 27.1). App Store Connect checks that field against its minimum SDK.
    ///
    /// This lives here and not in the Swift SDK's toolset because toolset options cannot be relative
    /// to the SDK, whereas the installed SDK's location is known when we write the package, and it
    /// also fixes SDKs installed before this was added.
    package static func sysrootLinkerFlags(sdkRoot: URL?) -> [String] {
        guard let sdkRoot else { return [] }
        // -Xclang-linker is a Swift driver flag: this only works because targets are linked through swiftc.
        return ["-Xclang-linker", "-isysroot", "-Xclang-linker", sdkRoot.path]
    }

    private func sdkRootForLinking() -> URL? {
        #if os(macOS)
        // Xcode's toolchain already passes -isysroot.
        return nil
        #else
        return (try? DarwinSDK.current())?.sdkRoot(forTriple: buildSettings.triple)
        #endif
    }

    private func build() async throws {
        let sdkVersion: String?
        #if os(macOS)
        sdkVersion = nil
        #else
        sdkVersion = try DarwinSDK.current()?.sdkVersion(for: buildSettings.sdkTriple)
        #endif
        let xtoolDir = URL(fileURLWithPath: "xtool")
        let packageDir = xtoolDir.appendingPathComponent(".xtool-tmp")
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        if URL(fileURLWithPath: "Packages").dirExists {
            try FileManager.default.createSymbolicLink(
                atPath: packageDir.appendingPathComponent("Packages").path,
                withDestinationPath: "../../Packages"
            )
        }

        let sysrootFlags = Packer.sysrootLinkerFlags(sdkRoot: sdkRootForLinking())
        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.app.product)-Builder",
            platforms: [
                .\(buildSettings.platform.rawValue)("\(plan.app.deploymentTarget)"),
            ],
            dependencies: [
                .package(name: "RootPackage", path: "../.."),
            ],
            targets: [
                \(
                    plan.allProducts.map {
                        """
                        .executableTarget(
                            name: "\($0.targetName)",
                            dependencies: [
                                .product(name: "\($0.product)", package: "RootPackage"),
                            ],
                            linkerSettings: \($0.linkerSettings(
                                platform: buildSettings.platform,
                                triple: buildSettings.triple,
                                // iOS gets its SDK version from -isysroot, see sysrootLinkerFlags
                                sdkVersion: buildSettings.platform == .iOS ? nil : sdkVersion,
                                extraFlags: buildSettings.platform == .iOS ? sysrootFlags : []
                            ))
                        )
                        """
                    }
                    .joined(separator: ",\n")
                )
            ]
        )\n
        """
        try Data(contents.utf8).write(to: packageSwift)

        var constValuesOptions: [String] = []
        if buildSettings.buildSystem == .swiftPM {
            // Swift Build emits const values for App Intents by itself, SwiftPM's native build doesn't.
            // The list goes to the frontend directly since the driver's -const-gather-protocols-list
            // only exists as of Swift 6.4
            let protocolsFile = URL(fileURLWithPath: packageDir.appendingPathComponent("const-protocols.json").path)
            try JSONEncoder().encode(AppIntentsMetadata.constValueProtocols).write(to: protocolsFile)
            constValuesOptions = [
                "-emit-const-values",
                "-Xfrontend", "-const-gather-protocols-file",
                "-Xfrontend", protocolsFile.path,
            ].flatMap { ["-Xswiftc", $0] }
        }

        for product in plan.allProducts {
            let sources: URL = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
        }

        var arguments = [
            "--scratch-path", ".build",
            // Keep SwiftPM from replacing the root package's resolved dependencies with the builder's subset.
            "--disable-automatic-resolution",
        ]
        if let toolset = try writeDeploymentToolset(in: packageDir) {
            arguments += ["--toolset", toolset.path]
        }
        let buildConfig = try await buildSettings
            .withPackagePath(packageDir.path)
            .swiftPMInvocation(forTool: "build", arguments: arguments + constValuesOptions)
        try await Subprocess.run(
            buildConfig,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
    }

    func writeDeploymentToolset(in directory: URL) throws -> URL? {
        guard buildSettings.buildSystem == .swiftPM, buildSettings.tripleDeploymentTarget != nil else { return nil }
        // Keep host build tools on their native triple while targeting the app's effective deployment version.
        let triple = buildSettings.triple(deploymentTarget: plan.app.deploymentTarget)
        let options = ["extraCLIOptions": ["-target", triple]]
        let toolset: [String: Any] = [
            "schemaVersion": "1.0",
            "swiftCompiler": options,
            "cCompiler": options,
            "cxxCompiler": options,
        ]
        let path = directory.appendingPathComponent("deployment-toolset.json")
        try JSONSerialization.data(withJSONObject: toolset, options: .sortedKeys).write(to: path, options: .atomic)
        return path
    }

    public func pack() async throws -> URL {
        try plan.validateResourceBundleSupport(platform: buildSettings.platform, buildSystem: buildSettings.buildSystem)
        try await build()
        warnAboutBuildInfo()

        let output = try TemporaryDirectory(name: "\(plan.app.product).app")

        let outputURL = output.url

        let binPath: String
        switch buildSettings.buildSystem {
        case .swiftPM:
            binPath = "\(buildSettings.sdkTriple)/\(buildSettings.configuration.rawValue)"
        case .swiftBuild:
            let platformName = buildSettings.platform.buildProductsPlatform(triple: buildSettings.triple)
            let suffix = buildSettings.platform == .macOS ? "" : "-\(platformName)"
            binPath = "out/Products/\(buildSettings.configuration.swiftBuildValue)\(suffix)"
        }
        let binDir = URL(
            fileURLWithPath: ".build/\(binPath)",
            isDirectory: true
        )

        let metadata: [String: String]
        #if os(macOS)
        metadata = [:]
        #else
        // stampBuildInfo does it for iOS
        metadata = buildSettings.platform == .iOS
            ? [:] : try DarwinSDK.current()?.buildMetadata(for: buildSettings.sdkTriple) ?? [:]
        #endif
        try await packProducts(binDir: binDir, outputURL: outputURL, buildMetadata: metadata)

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    func packProducts(binDir: URL, outputURL: URL, buildMetadata: [String: String] = [:]) async throws {
        var bundleIDsByModule: [String: [String]] = [:]
        for product in plan.allProducts {
            for module in product.modules {
                bundleIDsByModule[Self.moduleName(module), default: []].append(product.bundleID)
            }
        }
        let sharedBundleIDs = bundleIDsByModule.filter { $1.count > 1 }.mapValues { $0.sorted() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in plan.allProducts {
                try await pack(
                    product: product,
                    binDir: binDir,
                    outputURL: product.directory(inApp: outputURL, platform: buildSettings.platform),
                    sharedBundleIDs: sharedBundleIDs,
                    buildMetadata: buildMetadata,
                    &group
                )
            }

            while !group.isEmpty {
                do {
                    try await group.next()
                } catch is CancellationError {
                    // continue
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }
    }

    @Sendable private func pack(
        product: Plan.Product,
        binDir: URL,
        outputURL: URL,
        sharedBundleIDs: [String: [String]],
        buildMetadata: [String: String],
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) async throws {
        let platform = buildSettings.platform
        let contentsURL = platform.contentsDirectory(in: outputURL)
        let resourcesURL = platform.resourcesDirectory(in: outputURL)

        @Sendable func packFileToRoot(srcName: String) async throws {
            let srcURL = URL(fileURLWithPath: srcName)
            let destURL = resourcesURL.appendingPathComponent(srcURL.lastPathComponent)
            try FileManager.default.copyItem(at: srcURL, to: destURL)

            try Task.checkCancellation()
        }

        @Sendable func packFile(srcName: String, dstName: String? = nil, sign: Bool = false) async throws {
            let srcURL = URL(fileURLWithPath: srcName, relativeTo: binDir)
            let dstURL = URL(fileURLWithPath: dstName ?? srcURL.lastPathComponent, relativeTo: contentsURL)
            try? FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcURL, to: dstURL)

            try Task.checkCancellation()
        }

        // Ensure output directory is available
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let assets = try await Packer.compileAssets(for: product)
        let iconPath = Packer.iconPath(for: product, assets: assets)

        for command in product.resources {
            group.addTask {
                switch command {
                case .bundle(let package, let target):
                    let name = "\(package)_\(target).bundle"
                    let destination = platform.usesContentsDirectory ? "Resources/\(name)" : name
                    try await packFile(srcName: name, dstName: destination)
                case .binaryTarget(let name):
                    let src = URL(fileURLWithPath: "\(name).framework/\(name)", relativeTo: binDir)
                    let magic = Data("!<arch>\n".utf8)
                    let thinMagic = Data("!<thin>\n".utf8)
                    guard let bytes = try? FileHandle(forReadingFrom: src).read(upToCount: magic.count) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    // if the magic matches one of these it's a static archive; don't embed it.
                    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
                    // swiftlint:disable:previous line_length
                    if bytes != magic && bytes != thinMagic {
                        try await packFile(srcName: "\(name).framework", dstName: "Frameworks/\(name).framework", sign: true)
                    }
                case .library(let name):
                    try await packFile(srcName: "lib\(name).dylib", dstName: "Frameworks/lib\(name).dylib", sign: true)
                case .root(let source):
                    try await packFileToRoot(srcName: source)
                }
            }
        }
        if let iconPath {
            group.addTask {
                try await packFileToRoot(srcName: iconPath)
            }
        }
        if let assets {
            group.addTask {
                try assets.write(into: resourcesURL)
                try Task.checkCancellation()
            }
        }
        group.addTask {
            try writeAppIntentsMetadata(product: product, sharedBundleIDs: sharedBundleIDs, outputURL: resourcesURL)
        }
        group.addTask {
            let destination = platform.usesContentsDirectory ? "MacOS/\(product.product)" : product.product
            try await packFile(srcName: product.targetName, dstName: destination)
        }
        group.addTask {
            var info = product.infoPlist.merging(buildMetadata.mapValues { $0 as any Sendable }) { _, recorded in recorded }

            // Xcode adds these to extensions as well, App Store Connect rejects extensions without them
            if !platform.usesContentsDirectory {
                info["UIRequiredDeviceCapabilities"] = ["arm64"]
            }
            if product.type == .application {
                if !platform.usesContentsDirectory {
                    info["LSRequiresIPhoneOS"] = true
                }
            }
            info["CFBundleSupportedPlatforms"] = Packer.cfBundleSupportedPlatforms(for: buildSettings.triple)

            if let sdkBuildInfo, Packer.stampsBuildInfo(for: buildSettings.triple) {
                Packer.stampBuildInfo(
                    sdkBuildInfo,
                    buildMachineOSBuild: Packer.buildMachineOSBuild(),
                    into: &info
                )
            }

            if let assets {
                info.merge(assets.infoPlistAdditions) { _, new in new }
            }

            if let iconPath {
                let iconName = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
                info["CFBundleIconFile"] = iconName
            }

            let infoPath = contentsURL.appendingPathComponent("Info.plist")
            let encodedPlist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try encodedPlist.write(to: infoPath)
        }
    }

    private var swiftBuildConfigurationDirectory: String {
        let platformName = buildSettings.platform.buildProductsPlatform(triple: buildSettings.triple)
        return "\(buildSettings.configuration.swiftBuildValue)-\(platformName)"
    }

    // SwiftPM uses a module's c99name for its directory and its type names
    private static func moduleName(_ target: String) -> String {
        String(target.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    @Sendable private func writeAppIntentsMetadata(
        product: Plan.Product,
        sharedBundleIDs: [String: [String]],
        outputURL: URL
    ) throws {
        // an index among the resources takes precedence
        let hasOwnMetadata = product.resources.contains {
            if case .root(let source) = $0 {
                URL(fileURLWithPath: source).lastPathComponent == "Metadata.appintents"
            } else {
                false
            }
        }
        if hasOwnMetadata { return }

        let decoder = JSONDecoder()
        var entries: [JSONValue] = []
        for module in product.modules {
            for file in constValuesFiles(target: module) {
                entries += try decoder.decode([JSONValue].self, from: Data(contentsOf: file))
            }
        }
        let files: [String: Data]?
        do {
            files = try AppIntentsMetadata(entries: entries, sharedBundleIDs: sharedBundleIDs).files()
        } catch let error as AppIntentsMetadata.Unsupported {
            print("warning: Skipping the App Intents metadata of \(product.product): \(error)")
            return
        }
        guard let files else { return }
        let directory = outputURL.appendingPathComponent("Metadata.appintents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: directory.appendingPathComponent(name))
        }
    }

    private func constValuesFiles(target: String) -> [URL] {
        func contents(_ url: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        switch buildSettings.buildSystem {
        case .swiftPM:
            // one file per module
            let directory = URL(fileURLWithPath: ".build", isDirectory: true)
                .appendingPathComponent("\(buildSettings.triple)/\(buildSettings.configuration.rawValue)", isDirectory: true)
                .appendingPathComponent("\(Self.moduleName(target)).build", isDirectory: true)
            return contents(directory).filter { $0.pathExtension == "swiftconstvalues" }
        case .swiftBuild:
            // one file per source file. The output file map only lists current sources,
            // unlike the directory, which keeps the files of deleted ones
            let arch = buildSettings.triple.split(separator: "-").first.map(String.init) ?? "arm64"
            let intermediates = URL(fileURLWithPath: ".build/out/Intermediates.noindex", isDirectory: true)
            var files: [URL] = []
            for package in contents(intermediates) where package.pathExtension == "build" {
                let objects = package.appendingPathComponent(
                    "\(swiftBuildConfigurationDirectory)/\(target)-t.build/Objects-normal/\(arch)",
                    isDirectory: true
                )
                for map in contents(objects) where map.lastPathComponent.hasSuffix("-OutputFileMap.json") {
                    guard let data = try? Data(contentsOf: map),
                          let outputs = try? JSONDecoder().decode([String: [String: String]].self, from: data)
                    else { continue }
                    files += outputs.values.compactMap { $0["const-values"] }
                        .filter { FileManager.default.fileExists(atPath: $0) }
                        .map { URL(fileURLWithPath: $0) }
                }
            }
            return files
        }
    }

    /// The output of compiling a product's asset catalog.
    struct CompiledAssets: Sendable {
        /// The contents of `Assets.car`.
        var carData: Data
        /// Copies of the app icon renditions to place next to `Assets.car`, which SpringBoard falls back to.
        var looseFiles: [LooseFile] = []
        /// Keys such as `CFBundleIcons` to merge into the product's Info.plist.
        var infoPlistAdditions: [String: any Sendable] = [:]

        var hasAppIcon: Bool { !infoPlistAdditions.isEmpty }

        /// Writes `Assets.car` and the loose icon files into a product's bundle directory.
        func write(into directory: URL) throws {
            try carData.write(to: directory.appendingPathComponent("Assets.car"))
            for file in looseFiles {
                try file.data.write(to: directory.appendingPathComponent(file.name))
            }
        }
    }

    /// The loose `iconPath` file to pack. The catalog's AppIcon takes precedence over it.
    static func iconPath(for product: Plan.Product, assets: CompiledAssets?) -> String? {
        guard let iconPath = product.iconPath, assets?.hasAppIcon == true else { return product.iconPath }
        FileHandle.standardError.write(Data(
            "warning: ignoring iconPath '\(iconPath)' because the asset catalog defines an AppIcon.\n".utf8
        ))
        return nil
    }

    /// Compiles the product's asset catalog, if any.
    ///
    /// `XcodePacker` does not use this: it hands the catalog to Xcode, where actool compiles it.
    static func compileAssets(for product: Plan.Product) async throws -> CompiledAssets? {
        guard let catalogPath = product.assetCatalogPath else { return nil }
        let result = try await XCAssetCompiler(deploymentTarget: product.deploymentTarget)
            .compile(catalog: URL(fileURLWithPath: catalogPath))
        return CompiledAssets(
            carData: result.carData,
            looseFiles: result.appIconBundle?.looseFiles ?? [],
            infoPlistAdditions: result.appIconBundle?.infoPlistAdditions ?? [:]
        )
    }

    static func cfBundleSupportedPlatforms(for triple: String) -> [String] {
        [ApplePlatform(triple: triple)?.supportedPlatform(triple: triple) ?? "iPhoneOS"]
    }
}

extension Plan {
    func validateResourceBundleSupport(platform: ApplePlatform, buildSystem: BuildSystem) throws {
        guard platform.usesContentsDirectory, buildSystem == .swiftPM else { return }
        let hasPackageResources = allProducts.contains { product in
            product.resources.contains { resource in
                if case .bundle = resource { return true }
                return false
            }
        }
        if hasPackageResources {
            throw StringError("""
            macOS and Mac Catalyst apps with Swift package resource bundles require SwiftBuild. \
            Use Swift 6.4 or newer, which selects SwiftBuild automatically.
            """)
        }
    }
}

extension Plan.Product {
    /// Swift source for the `linkerSettings:` argument of the generated target.
    package func linkerSettings(
        platform: ApplePlatform = .iOS,
        triple: String = "arm64-apple-ios",
        sdkVersion: String? = nil,
        extraFlags: [String] = []
    ) -> String {
        let extra = extraFlags.map { "\"\($0.swiftStringEscaped)\"," }.joined(separator: "\n")
        let frameworks = platform.usesContentsDirectory ? "../Frameworks" : "Frameworks"
        let appFrameworks = platform.usesContentsDirectory ? "../../../../Frameworks" : "../../Frameworks"
        let sdkFlags = if let sdkVersion {
            """
            "-Xlinker", "-platform_version", "-Xlinker", "\(platform.linkerPlatform(triple: triple))",
            "-Xlinker", "\(deploymentTarget)", "-Xlinker", "\(sdkVersion)",
            """
        } else { "" }
        return switch self.type {
        case .application: """
        [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/\(frameworks)",
                \(sdkFlags)
                \(extra)
            ]),
        ]
        """
        case .appExtension: return """
        [
            // Link to Foundation framework which implements the _NSExtensionMain entrypoint
            .linkedFramework("Foundation"),
            .unsafeFlags([
                // Set the entry point to Foundation`_NSExtensionMain
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                // Include frameworks that the host app may use
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/\(appFrameworks)",
                // ...as well as our own
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/\(frameworks)",
                \(sdkFlags)
                \(extra)
            ]),
        ]
        """
        }
    }
}

private extension String {
    var swiftStringEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
