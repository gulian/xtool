import ArgumentParser
import XCLIUtils
import Foundation
import XKit

/// Signs an app that was built earlier, for one device, without building it again.
///
/// `xtool dev build --sign` only signs what it has just built. A tool that keeps built apps and
/// installs them later (on an Apple TV, which xtool cannot reach over usbmuxd) needs to sign
/// them on their own.
struct DevSignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Provision and sign a built iOS, tvOS or watchOS .app for a device"
    )

    @Argument(help: "The .app bundle to sign in place")
    var path: String

    @Option(help: "UDID of the device to register and sign for")
    var deviceUdid: String

    @Option(help: "Name to register the device under")
    var deviceName: String

    func run() async throws {
        let app = URL(fileURLWithPath: path)
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil
        ) as? [String: Any]
        let platform: DeveloperServicesPlatform
        switch (info?["CFBundleSupportedPlatforms"] as? [String])?.first {
        case "iPhoneOS": platform = .iOS
        case "AppleTVOS": platform = .tvOS
        // A standalone watch app; it is signed with an iOS development profile that names the watch.
        case "WatchOS": platform = .watchOS
        case let other:
            throw Console.Error("sign supports iOS, tvOS and watchOS apps, not \(other ?? "an app without CFBundleSupportedPlatforms").")
        }
        let auth = try AuthToken.saved()
        // Never revoke: this runs unattended, and revoking the certificate breaks apps installed with it.
        let installDelegate = XToolInstallerDelegate(allowsRevocation: false)
        let installer = IntegratedInstaller(auth: auth.authData(), delegate: installDelegate)
        do {
            defer { print() }
            try await installer.signInPlace(
                app: app,
                targetDevice: .init(udid: deviceUdid, name: deviceName),
                platform: platform
            )
        } catch let error as CancellationError {
            guard await installDelegate.refusedRevocation else { throw error }
            throw Console.Error("""
            Signing needs a development certificate this machine does not hold, and sign does not revoke \
            the existing one. Run `xtool dev build --sign` in an iOS project to replace it interactively, then retry.
            """)
        }
        print("Signed \(app.lastPathComponent).")
    }
}
