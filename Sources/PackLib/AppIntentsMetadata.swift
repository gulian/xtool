import Foundation

/// Writes the App Intents index (`Metadata.appintents`) of a bundle.
///
/// iOS only lists the App Intents (Shortcuts, Control Center, interactive widgets...)
/// of a bundle that contains this index. Xcode writes it after linking with the closed
/// `appintentsmetadataprocessor`, which only runs on macOS. Its input is the compiler's
/// `.swiftconstvalues` output though, which is JSON and available everywhere, so this
/// writes the index itself, in the format of Xcode 26.6.
///
/// This covers intents whose parameters are non-optional `Int` or `String` values with
/// a literal title, the `LiveActivityIntent` and `AudioRecordingIntent` system protocols,
/// and a single `AppShortcutsProvider`. Anything else throws `Unsupported` rather than
/// producing a wrong index.
struct AppIntentsMetadata {
    struct Unsupported: Error, CustomStringConvertible {
        var description: String
    }

    static let toolsVersion = "17F113"

    /// The protocols to gather const values for, the same list Swift Build uses.
    /// Swift Build passes them to the compiler itself, SwiftPM's native build does not.
    static let constValueProtocols = [
        "AppIntent", "EntityQuery", "AppEntity", "TransientEntity", "AppEnum",
        "AppShortcutProviding", "AppShortcutsProvider", "AnyResolverProviding",
        "AppIntentsPackage", "DynamicOptionsProvider", "_IntentValueRepresentable",
        "_AssistantIntentsProvider", "_GenerativeFunctionExtractable", "IntentValueQuery",
        "Resolver", "AppExtension", "ExtensionPointDefining",
    ]

    // Conformances to identifiers, as Xcode writes them. These make the system
    // run the intent in the app's process
    private static let systemProtocols = [
        "AppIntents.AudioRecordingIntent": "com.apple.link.systemProtocol.AudioRecording",
        "AppIntents.LiveActivityIntent": "com.apple.link.systemProtocol.SessionStarting",
    ]

    // Conformances every intent has, they add nothing to the index
    private static let plainConformances: Set = [
        "AppIntents.AppIntent", "AppIntents.SystemIntent", "AppIntents.PersistentlyIdentifiable",
        "AppIntents._SupportsAppDependencies",
    ]

    // Fields of a const values entry that are understood, others (e.g. availability) are refused
    private static let entryFields: Set = [
        "allConformances", "associatedTypeAliases", "conformances", "file", "kind", "line",
        "mangledTypeName", "properties", "typeName",
    ]

    // PerformResult protocols to outputFlags bits, only the ones seen in Xcode's output
    private static let outputFlags = ["AppIntents.IntentResult": 0, "AppIntents.ProvidesDialog": 4]

    // Parameter value types to the value type and resolvable input types Xcode writes for them,
    // only the ones seen in Xcode's output
    private static let parameterTypes: [String: (valueType: JSONValue, inputTypes: [JSONValue])] = [
        "Swift.Int": (primitive(2), [primitive(0), primitive(7), primitive(2)]),
        "Swift.String": (
            primitive(0),
            [primitive(0), ["array": ["wrapper": ["capabilities": 3, "memberValueType": primitive(2)]]], primitive(2)]
        ),
    ]

    // Arguments of `@Parameter(...)` that are understood when nil or left to their default,
    // and those that may hold anything because they never reach the index
    private static let defaultedParameterArguments: Set = [
        "description", "default", "controlStyle", "inclusiveRange", "inputConnectionBehavior",
    ]
    private static let runtimeParameterArguments: Set = ["requestValueDialog"]

    /// The const values entries of all modules linked into the bundle
    var entries: [JSONValue]

    /// The bundle IDs of the bundles linking each module that is linked into several.
    /// An intent in a module shared by the app and its extensions lives in several
    /// binaries, and the index has to tell the system which one belongs to which bundle.
    var sharedBundleIDs: [String: [String]]

    /// The files of `Metadata.appintents`, or nil if the bundle has no App Intents
    func files() throws -> [String: Data]? {
        var actions: [String: JSONValue] = [:]
        var providers: [JSONValue] = []
        for entry in entries {
            let conformances = entry["conformances"]?.strings ?? []
            let appIntentsConformances = conformances.filter { $0.hasPrefix("AppIntents.") }
            guard !appIntentsConformances.isEmpty else { continue }

            let unknown = Set((entry.object ?? [:]).keys).subtracting(Self.entryFields)
            if !unknown.isEmpty {
                throw Unsupported(description: "\(entry.typeName) has \(unknown.sorted().joined(separator: ", "))")
            }
            if conformances.contains("AppIntents.AppIntent") {
                let (identifier, action) = try action(entry)
                actions[identifier] = action
            } else if conformances.contains("AppIntents.AppShortcutsProvider") {
                providers.append(entry)
            } else {
                throw Unsupported(description: "\(entry.typeName) conforms to \(appIntentsConformances)")
            }
        }
        guard !actions.isEmpty || !providers.isEmpty else { return nil }

        if providers.count > 1 {
            throw Unsupported(description: "more than one AppShortcutsProvider")
        }
        let shortcuts = try providers.first.map(shortcuts) ?? []
        for shortcut in shortcuts {
            if let action = shortcut["actionIdentifier"]?.string, actions[action] == nil {
                throw Unsupported(description: "shortcut for unknown intent \(action)")
            }
        }

        var metadata: [String: JSONValue] = [
            "actions": .object(actions),
            "assistantEntities": [],
            "assistantIntentNegativePhrases": [],
            "assistantIntents": [],
            "autoShortcuts": .array(shortcuts),
            "entities": [:],
            "enums": [],
            "generator": ["name": "xcode-tools", "version": .string(Self.toolsVersion)],
            "negativePhrases": [],
            "queries": [:],
            "shortcutTileColor": 14,
            "version": 1,
        ]
        // left out without a provider, as in Xcode's index of a widget extension
        if let provider = providers.first {
            metadata["autoShortcutProviderMangledName"] = provider["mangledTypeName"]
        }

        let encoder = JSONEncoder()
        // compact, as Xcode writes it, and version.json without a final newline
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let version = """
        {
          "version" : "3.0",
          "toolsVersion" : "\(Self.toolsVersion)"
        }
        """
        return [
            "extract.actionsdata": try encoder.encode(JSONValue.object(metadata)),
            "version.json": Data(version.utf8),
        ]
    }

    private func action(_ entry: JSONValue) throws -> (String, JSONValue) {
        let name = entry.typeName
        let identifier = String(name.split(separator: ".").last ?? Substring(name))
        let parameters = try (entry["properties"]?.array ?? []).compactMap { try Self.parameter($0, of: name) }
        if Self.property(entry, "supportedModes") != nil {
            throw Unsupported(description: "\(name) sets supportedModes")
        }
        guard let title = try Self.literal(Self.property(entry, "title"), "\(name).title") else {
            throw Unsupported(description: "\(name) has no title")
        }
        let description = try Self.literal(Self.property(entry, "description"), "\(name).description")
        let opensApp = try Self.literal(Self.property(entry, "openAppWhenRun"), "\(name).openAppWhenRun") == "true"
        let discoverable = try Self.literal(Self.property(entry, "isDiscoverable"), "\(name).isDiscoverable") != "false"

        var protocols: [String] = []
        for conformance in entry["conformances"]?.strings ?? [] {
            if let identifier = Self.systemProtocols[conformance] {
                protocols.append(identifier)
            } else if conformance.hasPrefix("AppIntents.") && !Self.plainConformances.contains(conformance) {
                throw Unsupported(description: "\(name) conforms to \(conformance)")
            }
        }
        protocols.sort()
        // encoded like a dictionary with non-string keys, alternating identifier and metadata
        let protocolMetadata = JSONValue.array(protocols.flatMap { [.string($0), ["empty": [:]]] })

        var flags = 0
        for alias in entry["associatedTypeAliases"]?.array ?? [] where alias["typeAliasName"]?.string == "PerformResult" {
            for requirement in alias["opaqueTypeProtocolRequirements"]?.strings ?? [] {
                guard let flag = Self.outputFlags[requirement] else {
                    throw Unsupported(description: "\(name) returns \(requirement)")
                }
                flags |= flag
            }
        }

        let mangledName = entry["mangledTypeName"] ?? .null
        let module = String(name.split(separator: ".").first ?? "")
        let byBundle = JSONValue.object(Dictionary(
            uniqueKeysWithValues: (sharedBundleIDs[module] ?? []).map { ($0, mangledName) }
        ))
        var action: [String: JSONValue] = [
            "assistantDefinedSchemaTraits": [],
            "assistantDefinedSchemas": [],
            "authenticationPolicy": 0,
            "availabilityAnnotations": Self.availability,
            "effectiveBundleIdentifiers": [],
            "fullyQualifiedTypeName": .string(name),
            "identifier": .string(identifier),
            "isAuthPolExplicit": false,
            "isDiscoverable": .bool(discoverable),
            "mangledTypeName": mangledName,
            "mangledTypeNameByBundleIdentifier": byBundle,
            "mangledTypeNameByBundleIdentifierV2": byBundle,
            "mangledTypeNameV2": mangledName,
            "openAppWhenRun": .bool(opensApp),
            "outputFlags": .int(flags),
            "parameters": .array(parameters),
            "presentationStyle": 0,
            "requiredCapabilities": [],
            // 1 runs in the background, 2 opens the app first
            "supportedModes": opensApp ? 2 : 1,
            "systemProtocolMetadata": protocolMetadata,
            "systemProtocolMetadataV2": protocolMetadata,
            "systemProtocols": .array(protocols.map(JSONValue.string)),
            "title": Self.localized(title),
            "typeSpecificMetadata": [],
            "visibilityMetadata": ["assistantOnly": false, "isDiscoverable": .bool(discoverable)],
        ]
        if let description {
            action["descriptionMetadata"] = ["descriptionText": Self.localized(description), "searchKeywords": []]
        }
        return (identifier, .object(action))
    }

    /// A parameter of an intent, from the backing property `@Parameter` declares (`_name`).
    /// The property itself (`name`) and its projection (`$name`) are skipped.
    private static func parameter(_ property: JSONValue, of intent: String) throws -> JSONValue? {
        guard let type = property["type"]?.string, type.hasPrefix("AppIntents.IntentParameter<") else {
            return nil
        }
        guard let label = property["label"]?.string, label.hasPrefix("_") else { return nil }
        let name = String(label.dropFirst())
        let what = "\(intent).\(name)"
        guard property["valueKind"]?.string == "InitCall" else {
            throw Unsupported(description: "\(what) is not declared with @Parameter(...)")
        }
        let valueType = String(type.dropFirst("AppIntents.IntentParameter<".count).dropLast())
        guard let types = parameterTypes[valueType] else {
            throw Unsupported(description: "\(what) is a \(valueType), only Int and String parameters can be indexed")
        }
        var title: String?
        for argument in property["value"]?["arguments"]?.array ?? [] {
            let label = argument["label"]?.string ?? ""
            let kind = argument["valueKind"]?.string
            if label == "title" {
                title = try literal(argument, "\(what).title")
            } else if runtimeParameterArguments.contains(label) {
                continue
            } else if !defaultedParameterArguments.contains(label) || !(kind == "NilLiteral" || kind == "Runtime") {
                // a default argument the caller did not pass is Runtime, as is a value only known when running
                throw Unsupported(description: "\(what) sets \(label.isEmpty ? "an unlabeled argument" : label)")
            }
        }
        guard let title else {
            throw Unsupported(description: "\(what) has no title")
        }
        return [
            "capabilities": 0,
            "dynamicOptionsSupport": 0,
            "inputConnectionBehavior": 0,
            "isInput": false,
            "isOptional": false,
            "name": .string(name),
            "resolvableInputTypes": .array(types.inputTypes.map { ["kindValue": 0, "valueType": $0] }),
            "title": localized(title),
            "typeSpecificMetadata": [],
            "valueType": types.valueType,
        ]
    }

    private static func primitive(_ typeIdentifier: Int) -> JSONValue {
        ["primitive": ["wrapper": ["typeIdentifier": .int(typeIdentifier)]]]
    }

    private func shortcuts(_ provider: JSONValue) throws -> [JSONValue] {
        guard let builder = Self.property(provider, "appShortcuts"),
              builder["valueKind"]?.string == "Builder" else {
            throw Unsupported(description: "\(provider.typeName).appShortcuts is not a result builder")
        }
        return try (builder["value"]?["members"]?.array ?? []).map { member in
            guard member["kind"]?.string == "buildExpression",
                  let element = member["element"], element["valueKind"]?.string == "InitCall" else {
                throw Unsupported(description: "appShortcuts may only list AppShortcut(...) calls")
            }
            var arguments: [String: JSONValue] = [:]
            for argument in element["value"]?["arguments"]?.array ?? [] {
                if let label = argument["label"]?.string {
                    arguments[label] = argument
                }
            }
            guard let intentType = arguments["intent"]?["type"]?.string,
                  let phrases = arguments["phrases"]?["value"]?.array else {
                throw Unsupported(description: "AppShortcut without an intent or phrases")
            }
            var shortcut: [String: JSONValue] = [
                "actionIdentifier": .string(String(intentType.split(separator: ".").last ?? "")),
                "availabilityAnnotations": Self.availability,
                "phraseTemplates": .array(try phrases.map { Self.localized(try Self.phrase($0)) }),
            ]
            if let shortTitle = try Self.literal(arguments["shortTitle"], "shortTitle") {
                shortcut["shortTitle"] = Self.localized(shortTitle)
            }
            if let image = try Self.literal(arguments["systemImageName"], "systemImageName") {
                shortcut["systemImageName"] = .string(image)
            }
            return .object(shortcut)
        }
    }

    private static func phrase(_ value: JSONValue) throws -> String {
        switch value["valueKind"]?.string {
        case "RawLiteral":
            return value["value"]?.string ?? ""
        case "InterpolatedStringLiteral":
            var text = ""
            for segment in value["value"]?["segments"]?.array ?? [] {
                if segment["valueKind"]?.string == "RawLiteral" {
                    text += segment["value"]?.string ?? ""
                } else if segment["valueKind"]?.string == "Enum",
                          segment["value"]?["name"]?.string == "applicationName" {
                    text += "${applicationName}"
                } else {
                    throw Unsupported(description: "phrases may only interpolate .applicationName")
                }
            }
            return text
        case let kind:
            throw Unsupported(description: "phrase is \(kind ?? "unknown")")
        }
    }

    private static func property(_ entry: JSONValue, _ label: String) -> JSONValue? {
        entry["properties"]?.array?.first { $0["label"]?.string == label }
    }

    private static func literal(_ value: JSONValue?, _ what: String) throws -> String? {
        guard let value else { return nil }
        guard value["valueKind"]?.string == "RawLiteral" else {
            throw Unsupported(description: "\(what) is \(value["valueKind"]?.string ?? "unknown"), only literals can be indexed")
        }
        return value["value"]?.string
    }

    private static func localized(_ key: String) -> JSONValue {
        ["alternatives": [], "key": .string(key)]
    }

    private static let availability: JSONValue = ["LNPlatformNameWildcard": ["introducedVersion": "*"]]
}

extension JSONValue {
    fileprivate var typeName: String {
        self["typeName"]?.string ?? "<unknown>"
    }
}
