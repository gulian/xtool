import Foundation
import DeveloperAPI

public struct DeveloperServicesAddDeviceOperation: DeveloperServicesOperation {
    public let context: SigningContext
    public init(context: SigningContext) {
        self.context = context
    }

    public func perform() async throws {
        guard let targetDevice = context.targetDevice else { return }
        // Profiles reused as they are (see DeveloperServicesFetchProfileOperation): no device to add.
        if ProcessInfo.processInfo.environment["XTL_REUSE_PROFILE"] == "1" { return }

        // Already registered: nothing to create. Since November 2026 Apple answers a second
        // registration of the same UDID with a bare 500 (UNEXPECTED_ERROR) instead of a 409.
        let registered = try await context.developerAPIClient.devicesGetCollection()
            .ok.body.json.data
            .contains { $0.attributes?.udid?.caseInsensitiveCompare(targetDevice.udid) == .orderedSame }
        if registered { return }

        // try to register the device
        let response = try await context.developerAPIClient.devicesCreateInstance(
            body: .json(.init(data: .init(
                _type: .devices,
                attributes: .init(
                    name: targetDevice.name,
                    platform: .init(.ios),
                    udid: targetDevice.udid
                )
            )))
        )

        // we get a 409 CONFLICT if the device was already registered.
        // handle this by returning gracefully.
        if (try? response.conflict) != nil {
            return
        }

        // otherwise, we should get a 201 CREATED to indicate that the device
        // was added. any other case is unexpected, and this will throw.
        _ = try response.created
    }

}
