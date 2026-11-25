import Foundation
import Testing
import Subprocess
@testable import PackLib

@Test func nativeDeploymentToolsetUsesEffectiveTarget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeploymentToolsetTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let app = Plan.Product(
        type: .application, product: "Example", deploymentTarget: "18.0", bundleID: "com.example.app",
        infoPlist: [:], resources: [], modules: [], iconPath: nil, entitlementsPath: nil
    )
    let plan = Plan(app: app, extensions: [])
    let settings = try await BuildSettings(
        configuration: .debug, triple: "arm64-apple-tvos17.0-simulator", buildSystem: .swiftPM
    )
    let toolsetPath = try Packer(buildSettings: settings, plan: plan).writeDeploymentToolset(in: root)
    let path = try #require(toolsetPath)
    let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
    let toolset = try #require(decoded as? [String: Any])
    func options(for compiler: String) throws -> [String] {
        let definition = try #require(toolset[compiler] as? [String: Any])
        return try #require(definition["extraCLIOptions"] as? [String])
    }

    let swift = try await Subprocess.run(
        .path(BuildSettings.swiftcURL()),
        arguments: .init(["-target", "arm64-apple-tvos17.0-simulator"] + options(for: "swiftCompiler") + ["-print-target-info"]),
        output: .data(limit: .max)
    ).checkSuccess()
    let targetInfo = try JSONSerialization.jsonObject(with: swift.standardOutput)
    let info = try #require(targetInfo as? [String: Any])
    let target = try #require(info["target"] as? [String: Any])
    #expect(target["triple"] as? String == "arm64-apple-tvos18.0-simulator")

    for (compiler, language) in [("cCompiler", "c"), ("cxxCompiler", "c++")] {
        let result = try await Subprocess.run(
            .name("clang"),
            arguments: .init(
                ["-target", "arm64-apple-tvos17.0-simulator"] + options(for: compiler) + ["-dM", "-E", "-x", language, "/dev/null"]
            ),
            output: .string(limit: .max)
        ).checkSuccess()
        #expect(result.standardOutput.contains("#define __ENVIRONMENT_TV_OS_VERSION_MIN_REQUIRED__ 180000"))
    }

    let unversioned = try await BuildSettings(configuration: .debug, triple: "arm64-apple-tvos-simulator", buildSystem: .swiftPM)
    let unversionedToolset = try Packer(buildSettings: unversioned, plan: plan).writeDeploymentToolset(in: root)
    #expect(unversionedToolset == nil)
}

@Test(arguments: [ApplePlatform.macOS, .macCatalyst], [false, true])
func nativeDesktopPackageResourcesRequireSwiftBuild(platform: ApplePlatform, extensionOnly: Bool) throws {
    var app = Plan.Product(
        type: .application, product: "Example", deploymentTarget: "17.0", bundleID: "com.example.app",
        infoPlist: [:], resources: [.root(source: "custom.txt")], iconPath: nil, entitlementsPath: nil
    )
    var ext = app
    ext.type = .appExtension
    ext.product = "Extension"
    let resource = Plan.Resource.bundle(package: "Example", target: "Content")
    if extensionOnly {
        ext.resources.append(resource)
    } else {
        app.resources.append(resource)
    }
    let plan = Plan(app: app, extensions: [ext])
    #expect(throws: StringError.self) {
        try plan.validateResourceBundleSupport(platform: platform, buildSystem: .swiftPM)
    }
    try plan.validateResourceBundleSupport(platform: platform, buildSystem: .swiftBuild)
    try plan.validateResourceBundleSupport(platform: .iOS, buildSystem: .swiftPM)
    try plan.validateResourceBundleSupport(platform: .tvOS, buildSystem: .swiftPM)

    app.resources = [.root(source: "custom.txt")]
    ext.resources = []
    try Plan(app: app, extensions: [ext]).validateResourceBundleSupport(platform: platform, buildSystem: .swiftPM)
}

@Test func cfBundleSupportedPlatformsFollowsBuildTriple() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios-simulator") == ["iPhoneSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-macabi") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-macabi") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-tvos") == ["AppleTVOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-tvos17.0-simulator") == ["AppleTVSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "unknown-triple") == ["iPhoneOS"])
}

private func makeProduct(type: Plan.ProductType) -> Plan.Product {
    Plan.Product(
        type: type,
        product: "Demo",
        deploymentTarget: "17.0",
        bundleID: "com.example.demo",
        infoPlist: [:],
        resources: [],
        modules: []
    )
}

@Test func sysrootLinkerFlagsPassIsysrootToClang() {
    let sdk = URL(fileURLWithPath: "/sdks/iPhoneOS27.1.sdk")
    #expect(Packer.sysrootLinkerFlags(sdkRoot: sdk) == [
        "-Xclang-linker", "-isysroot", "-Xclang-linker", "/sdks/iPhoneOS27.1.sdk",
    ])
    #expect(Packer.sysrootLinkerFlags(sdkRoot: nil).isEmpty)
}

@Test(arguments: [Plan.ProductType.application, .appExtension])
func generatedLinkerSettingsIncludeSysroot(type: Plan.ProductType) {
    let flags = Packer.sysrootLinkerFlags(sdkRoot: URL(fileURLWithPath: "/sdks/with \"quote\"/iPhoneOS27.1.sdk"))
    let settings = makeProduct(type: type).linkerSettings(extraFlags: flags)
    #expect(settings.contains("\"-Xclang-linker\","))
    #expect(settings.contains("\"-isysroot\","))
    #expect(settings.contains(#""/sdks/with \"quote\"/iPhoneOS27.1.sdk","#))
    #expect(settings.contains("@executable_path/Frameworks"))

    #expect(!makeProduct(type: type).linkerSettings(extraFlags: []).contains("isysroot"))
}

@Test func sdkRootFollowsTheTripleAndPicksVersionedSDK() throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("SysrootTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    let sdks = [
        "iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk",
        "iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.1.sdk",
    ]
    for sdk in sdks {
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Developer/Platforms/\(sdk)"),
            withIntermediateDirectories: true
        )
    }
    try Data("epoch=4\n".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))
    let sdk = try #require(DarwinSDK(bundle: bundle))

    #expect(sdk.sdkRoot(forTriple: "arm64-apple-ios")?.lastPathComponent == "iPhoneOS27.1.sdk")
    #expect(sdk.sdkRoot(forTriple: "arm64-apple-ios17.0-simulator")?.lastPathComponent == "iPhoneSimulator27.1.sdk")
    #expect(sdk.sdkRoot(forTriple: "arm64-apple-macosx") == nil)
}

@Test func sdkRootFollowsSwiftSDKMetadata() throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("SysrootMetadataTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    for sdk in [
        "iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk",
        "iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk",
        "iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk",
        "iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.1.sdk",
    ] {
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Developer/Platforms/\(sdk)"),
            withIntermediateDirectories: true
        )
    }
    try Data("epoch=4\n".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))
    // SDKBuilder records the first matching SDK, which is not the newest one here
    let metadata = """
    {"schemaVersion": "4.0", "targetTriples": {
      "arm64-apple-ios": {"sdkRootPath": "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk"},
      "arm64-apple-ios-simulator": {
        "sdkRootPath": "Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk"
      }
    }}
    """
    try Data(metadata.utf8).write(to: bundle.appendingPathComponent("swift-sdk.json"))
    let sdk = try #require(DarwinSDK(bundle: bundle))

    #expect(sdk.sdkRoot(forTriple: "arm64-apple-ios")?.lastPathComponent == "iPhoneOS26.5.sdk")
    #expect(sdk.sdkRoot(forTriple: "arm64-apple-ios17.0")?.lastPathComponent == "iPhoneOS26.5.sdk")
    #expect(sdk.sdkRoot(forTriple: "arm64-apple-ios17.0-simulator")?.lastPathComponent == "iPhoneSimulator26.5.sdk")
    // a triple the metadata doesn't list falls back to the newest SDK on disk
    #expect(sdk.sdkRoot(forTriple: "x86_64-apple-ios-simulator")?.lastPathComponent == "iPhoneSimulator27.1.sdk")
}

@Test(arguments: ["arm64-apple-tvos", "arm64-apple-ios-macabi"])
func packsPlatformBundleAndExtension(triple: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PackerTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let binDir = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let settings = try await BuildSettings(configuration: .release, triple: triple, buildSystem: .swiftPM)
    let platform = settings.platform
    let app = Plan.Product(
        type: .application, product: "Example", deploymentTarget: "17.0", bundleID: "com.example.app",
        infoPlist: ["CFBundleIdentifier": "com.example.app", "DTSDKBuild": "stale-build"],
        resources: [.bundle(package: "Example", target: "Content"), .library(name: "Shared")],
        iconPath: nil, entitlementsPath: nil
    )
    var ext = app
    ext.type = .appExtension
    ext.product = "Extension"
    ext.resources = []
    let executable = Data([0, 1, 2, 3])
    for product in [app, ext] {
        try executable.write(to: binDir.appendingPathComponent(product.targetName))
    }
    let resources = binDir.appendingPathComponent("Example_Content.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
    try Data("resource".utf8).write(to: resources.appendingPathComponent("content.txt"))
    try executable.write(to: binDir.appendingPathComponent("libShared.dylib"))

    let output = root.appendingPathComponent("Example.app", isDirectory: true)
    try await Packer(buildSettings: settings, plan: Plan(app: app, extensions: [ext]))
        .packProducts(binDir: binDir, outputURL: output, buildMetadata: ["DTSDKBuild": "recorded-sdk-build"])

    let prefix = platform.usesContentsDirectory ? "Contents/" : ""
    let executablePrefix = platform.usesContentsDirectory ? "Contents/MacOS/" : ""
    let resourcePrefix = platform.usesContentsDirectory ? "Contents/Resources/" : ""
    #expect(try Data(contentsOf: output.appendingPathComponent("\(executablePrefix)Example")) == executable)
    #expect(try Data(contentsOf: output.appendingPathComponent("\(resourcePrefix)Example_Content.bundle/content.txt"))
        == Data("resource".utf8))
    #expect(try Data(contentsOf: output.appendingPathComponent("\(prefix)Frameworks/libShared.dylib")) == executable)
    #expect(try Data(contentsOf: output.appendingPathComponent("\(prefix)PlugIns/Extension.appex/\(executablePrefix)Extension"))
        == executable)

    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: output.appendingPathComponent("\(prefix)Info.plist")), format: nil
    ) as? [String: Any]
    #expect(plist?["CFBundleSupportedPlatforms"] as? [String] == [platform.supportedPlatform(triple: triple)])
    #expect(plist?["DTSDKBuild"] as? String == "recorded-sdk-build")
    let extensionInfo = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: output.appendingPathComponent("\(prefix)PlugIns/Extension.appex/\(prefix)Info.plist")), format: nil
    ) as? [String: Any]
    #expect(extensionInfo?["DTSDKBuild"] as? String == "recorded-sdk-build")
    if platform.usesContentsDirectory {
        #expect(plist?["LSRequiresIPhoneOS"] == nil)
        #expect(plist?["UIRequiredDeviceCapabilities"] == nil)
    }
}
