import Foundation
import XUtils
import Subprocess

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.plan = plan
        self.buildSettings = buildSettings
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
                                sdkVersion: sdkVersion
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
            .swiftPMInvocation(forTool: "build", arguments: arguments)
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
        metadata = try DarwinSDK.current()?.buildMetadata(for: buildSettings.sdkTriple) ?? [:]
        #endif
        try await packProducts(binDir: binDir, outputURL: outputURL, buildMetadata: metadata)

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    func packProducts(binDir: URL, outputURL: URL, buildMetadata: [String: String] = [:]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in plan.allProducts {
                try pack(
                    product: product,
                    binDir: binDir,
                    outputURL: product.directory(inApp: outputURL, platform: buildSettings.platform),
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
        buildMetadata: [String: String],
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) throws {
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

        for command in product.resources {
            group.addTask {
                switch command {
                case .bundle(let package, let target):
                    let name = "\(package)_\(target).bundle"
                    let destination = platform.usesContentsDirectory ? "Resources/\(name)" : name
                    try await packFile(srcName: name, dstName: destination)
                case .binaryTarget(let name):
                    let src = URL(fileURLWithPath: "\(name).framework/\(name)", relativeTo: binDir)
                    guard let isStatic = Self.isStaticArchive(src) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    // a static archive is already linked into the executable; don't embed it.
                    if !isStatic {
                        try await packFile(srcName: "\(name).framework", dstName: "Frameworks/\(name).framework", sign: true)
                    }
                case .library(let name):
                    try await packFile(srcName: "lib\(name).dylib", dstName: "Frameworks/lib\(name).dylib", sign: true)
                case .root(let source):
                    try await packFileToRoot(srcName: source)
                }
            }
        }
        if let iconPath = product.iconPath {
            group.addTask {
                try await packFileToRoot(srcName: iconPath)
            }
        }
        group.addTask {
            let destination = platform.usesContentsDirectory ? "MacOS/\(product.product)" : product.product
            try await packFile(srcName: product.targetName, dstName: destination)
        }
        group.addTask {
            var info = product.infoPlist.merging(buildMetadata.mapValues { $0 as any Sendable }) { _, recorded in recorded }

            if product.type == .application {
                if !platform.usesContentsDirectory {
                    // Simulator builds may target x86_64 and do not require device hardware capabilities.
                    if !buildSettings.triple.split(separator: "-").contains("simulator") {
                        info["UIRequiredDeviceCapabilities"] = ["arm64"]
                    }
                    info["LSRequiresIPhoneOS"] = true
                }
            }
            info["CFBundleSupportedPlatforms"] = Packer.cfBundleSupportedPlatforms(for: buildSettings.triple)

            if let iconPath = product.iconPath {
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

    static func cfBundleSupportedPlatforms(for triple: String) -> [String] {
        [ApplePlatform(triple: triple)?.supportedPlatform(triple: triple) ?? "iPhoneOS"]
    }

    /// Whether the binary of a framework is a static archive: a plain one, or a universal file
    /// whose slices are archives (what xcframeworks built with `lipo` ship). `nil` if unreadable.
    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
    // swiftlint:disable:previous line_length
    static func isStaticArchive(_ url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let archiveMagics = [Data("!<arch>\n".utf8), Data("!<thin>\n".utf8)]
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return nil }
        if archiveMagics.contains(head) { return true }

        func word(_ data: Data, _ offset: Int) -> UInt64 {
            data.dropFirst(offset).prefix(4).reduce(0) { $0 << 8 | UInt64($1) }
        }
        // FAT_MAGIC and FAT_MAGIC_64, big-endian on disk: the header is followed by `nfat_arch`
        // entries of 20 bytes (32-bit offsets) or 32 bytes (64-bit offsets).
        let magic = word(head, 0)
        guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF else { return false }
        let wide = magic == 0xCAFE_BABF
        let count = Int(word(head, 4))
        // a Java class file shares the magic; no real binary has that many slices.
        guard (1...32).contains(count) else { return false }
        let entrySize = wide ? 32 : 20
        guard (try? handle.seek(toOffset: 8)) != nil,
              let table = try? handle.read(upToCount: count * entrySize), table.count == count * entrySize
        else { return false }
        for index in 0..<count {
            let entry = table.dropFirst(index * entrySize)
            let offset = wide ? word(Data(entry), 8) << 32 | word(Data(entry), 12) : word(Data(entry), 8)
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let slice = try? handle.read(upToCount: 8), archiveMagics.contains(slice)
            else { return false }
        }
        return true
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
    fileprivate func linkerSettings(platform: ApplePlatform, triple: String, sdkVersion: String?) -> String {
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
            ]),
        ]
        """
        case .appExtension: """
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
            ]),
        ]
        """
        }
    }
}
