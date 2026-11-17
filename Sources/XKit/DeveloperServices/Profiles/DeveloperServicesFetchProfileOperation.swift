//
//  DeveloperServicesFetchProfileOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Superutils
import DeveloperAPI

public struct DeveloperServicesFetchProfileOperation: DeveloperServicesOperation {

    public enum Errors: Error {
        case bundleIDNotFound
        case tooManyMatchingBundleIDs
        case invalidProfileData
        case noRegisteredDevices(DeveloperServicesPlatform)
    }

    public let context: SigningContext
    public let bundleID: String
    public let signingInfo: SigningInfo
    public init(context: SigningContext, bundleID: String, signingInfo: SigningInfo) {
        self.context = context
        self.bundleID = bundleID
        self.signingInfo = signingInfo
    }

    public func perform() async throws -> Mobileprovision {
        let bundleIDs = try await context.developerAPIClient
            .bundleIdsGetCollection(query: .init(
                filter_lbrack_identifier_rbrack_: [bundleID],
                fields_lbrack_profiles_rbrack_: [.bundleId],
                include: [.profiles]
            ))
            .ok.body.json

        // filter[identifier] is a prefix filter so we need to manually upgrade to equality
        let filtered = bundleIDs.data.filter { $0.attributes?.identifier == self.bundleID }

        let bundleID: Components.Schemas.BundleId
        switch filtered.count {
        case 0:
            throw Errors.bundleIDNotFound
        case 1:
            bundleID = filtered[0]
        default:
            throw Errors.tooManyMatchingBundleIDs
        }

        let profiles = bundleID.relationships?.profiles?.data ?? []

        // XTL_REUSE_PROFILE=1: keep the existing profile when it is still valid and covers the target
        // device, without touching the devices endpoint (Apple answered it with a 500 on 2026-11-17).
        if ProcessInfo.processInfo.environment["XTL_REUSE_PROFILE"] == "1", profiles.count == 1,
           let content = try await context.developerAPIClient.profilesGetInstance(path: .init(id: profiles[0].id))
               .ok.body.json.data.attributes?.profileContent,
           let data = Data(base64Encoded: content) {
            let profile = try Mobileprovision(data: data)
            let digest = try profile.digest()
            let device = context.targetDevice?.udid
            if digest.expirationDate > Date().addingTimeInterval(86_400),
               device.map({ udid in digest.devices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame } }) ?? true {
                return profile
            }
        }

        switch profiles.count {
        case 0:
            // we're good
            break
        case 1:
            _ = try await context.developerAPIClient.profilesDeleteInstance(path: .init(id: profiles[0].id)).noContent
        default:
            // if the user has >1 profile, it's probably okay to add another one (acceptable for non-free accounts?)
            break
        }

        // Match locally rather than with filter[serialNumber]: the API lists serials with a
        // leading zero nibble ("0E41…") but its filter only matches them without it ("E41…").
        let certs = try await DeveloperAPIPages {
            try await context.developerAPIClient.certificatesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)
        .filter { $0.attributes?.serialNumber.map(signingInfo.certificate.hasSerialNumber) == true }

        let allDevices = try await context.developerAPIClient.devicesGetCollection()
            .ok.body.json.data
            .filter { $0.attributes?.deviceClass?.value1?.supportsApps(on: context.platform) == true }

        // A development profile needs at least one device; Apple otherwise answers with a bare 409.
        guard !allDevices.isEmpty else { throw Errors.noRegisteredDevices(context.platform) }

        let response = try await context.developerAPIClient.profilesCreateInstance(
            body: .json(
                .init(
                    data: .init(
                        _type: .profiles,
                        attributes: .init(
                            name: "XTL profile \(bundleID.id)",
                            profileType: .init(context.platform == .tvOS ? .tvosAppDevelopment : .iosAppDevelopment)
                        ),
                        relationships: .init(
                            bundleId: .init(
                                data: .init(_type: .bundleIds, id: bundleID.id)
                            ),
                            devices: .init(data: allDevices.map {
                                .init(_type: .devices, id: $0.id)
                            }),
                            certificates: .init(data: certs.map {
                                .init(_type: .certificates, id: $0.id)
                            })
                        )
                    )
                )
            )
        )
        .created.body.json.data

        guard let contentString = response.attributes?.profileContent,
              let contentData = Data(base64Encoded: contentString)
              else { throw Errors.invalidProfileData }

        return try Mobileprovision(data: contentData)
    }

}

extension DeveloperServicesFetchProfileOperation.Errors: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .noRegisteredDevices(let platform):
            "No \(platform) device is registered on this account. Register one with --device-udid."
        default:
            nil
        }
    }

    public var description: String {
        switch self {
        case .bundleIDNotFound: "bundleIDNotFound"
        case .tooManyMatchingBundleIDs: "tooManyMatchingBundleIDs"
        case .invalidProfileData: "invalidProfileData"
        case .noRegisteredDevices: errorDescription ?? "noRegisteredDevices"
        }
    }
}

extension Components.Schemas.Device.AttributesPayload.DeviceClassPayload.Value1Payload {
    func supportsApps(on platform: DeveloperServicesPlatform) -> Bool {
        switch platform {
        case .tvOS:
            self == .appleTv
        case .iOS:
            self == .ipad || self == .iphone || self == .ipod
        default:
            false
        }
    }
}
