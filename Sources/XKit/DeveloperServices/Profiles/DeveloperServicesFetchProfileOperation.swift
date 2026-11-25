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

        // match locally rather than with filter[serialNumber]: server-side matching bugs out
        // when the serial has leading zeroes (#305)
        let certs = try await DeveloperAPIPages(\.links.next) {
            try await context.developerAPIClient.certificatesGetCollection().ok.body.json
        }
        .map(\.data)
        .reduce(into: [], +=)
        .filter { $0.attributes?.serialNumber.map(signingInfo.certificate.hasSerialNumber) == true }

        let allDevices = try await DeveloperAPIPages(\.links.next) {
            try await context.developerAPIClient.devicesGetCollection().ok.body.json
        }
        .map(\.data)
        .reduce(into: [], +=)
        .filter {
            $0.attributes?.status?.value1 != .disabled
            && $0.attributes?.deviceClass?.value1?.supportsApps(on: context.platform) == true
        }

        // A development profile needs at least one device; Apple otherwise answers with a bare 409.
        guard !allDevices.isEmpty else { throw Errors.noRegisteredDevices(context.platform) }

        try Task.checkCancellation()

        // An app can share its identifier between iOS and tvOS: a name each, or one's profile replaces the other's.
        let profileName = "XTL \(context.platform == .tvOS ? "tvOS " : "")profile \(bundleID.id)"

        let profiles = bundleID.relationships?.profiles?.data ?? []
        if !profiles.isEmpty {
            // we can't create multiple profiles with the same name, so
            // if there's already one delete it first
            let matchingProfiles = try await context.developerAPIClient.profilesGetCollection(query: .init(
                filter_lbrack_name_rbrack_: [profileName],
                filter_lbrack_id_rbrack_: profiles.map(\.id),
                fields_lbrack_profiles_rbrack_: [.name],
            ))
            .ok.body.json.data
            .filter { $0.attributes?.name == profileName }

            _ = try await matchingProfiles.concurrentMap {
                try await context.developerAPIClient.profilesDeleteInstance(path: .init(id: $0.id)).noContent
            }
        }

        let response = try await context.developerAPIClient.profilesCreateInstance(
            body: .json(
                .init(
                    data: .init(
                        _type: .profiles,
                        attributes: .init(
                            name: profileName,
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
        case .watchOS:
            self == .appleWatch
        case .iOS:
            self == .ipad || self == .iphone || self == .ipod
        default:
            false
        }
    }
}
