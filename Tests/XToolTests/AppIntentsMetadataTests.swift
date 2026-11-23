import Foundation
import Testing
@testable import PackLib

private func literal(_ label: String, _ value: String) -> JSONValue {
    ["label": .string(label), "type": "Swift.String", "valueKind": "RawLiteral", "value": .string(value)]
}

private func intent(
    _ name: String,
    conformances: [String] = [],
    properties: [JSONValue],
    result: [String] = ["AppIntents.IntentResult"]
) -> JSONValue {
    [
        "typeName": .string(name),
        "mangledTypeName": .string("mangled\(name)"),
        "kind": "struct",
        "file": "Intents.swift",
        "line": 1,
        "conformances": .array((["AppIntents.AppIntent", "Swift.Sendable"] + conformances).map(JSONValue.string)),
        "allConformances": [],
        "associatedTypeAliases": [
            [
                "typeAliasName": "PerformResult",
                "opaqueTypeProtocolRequirements": .array(result.map(JSONValue.string)),
            ],
        ],
        "properties": .array(properties),
    ]
}

private let shortcuts: JSONValue = [
    "typeName": "App.Shortcuts",
    "mangledTypeName": "mangledShortcuts",
    "kind": "struct",
    "file": "Shortcuts.swift",
    "line": 1,
    "conformances": ["AppIntents.AppShortcutsProvider"],
    "properties": [
        [
            "label": "appShortcuts",
            "valueKind": "Builder",
            "value": [
                "members": [
                    [
                        "kind": "buildExpression",
                        "element": [
                            "valueKind": "InitCall",
                            "value": [
                                "arguments": [
                                    ["label": "intent", "type": "Shared.StopIntent"],
                                    [
                                        "label": "phrases",
                                        "value": [
                                            [
                                                "valueKind": "InterpolatedStringLiteral",
                                                "value": [
                                                    "segments": [
                                                        ["valueKind": "RawLiteral", "value": "Stop "],
                                                        ["valueKind": "Enum", "value": ["name": "applicationName"]],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                    ["label": "shortTitle", "valueKind": "RawLiteral", "value": "stop.short"],
                                    ["label": "systemImageName", "valueKind": "RawLiteral", "value": "stop.fill"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ],
]

/// The properties the compiler lists for `@Parameter(title:) var name: Value`: the backing property,
/// the property itself and its projection. `arguments` replaces or adds `@Parameter` arguments.
private func parameter(_ name: String, _ value: String, title: String, arguments: [String: JSONValue] = [:]) -> [JSONValue] {
    let type = JSONValue.string("AppIntents.IntentParameter<\(value)>")
    var call: [String: JSONValue] = [
        "title": ["label": "title", "type": "Foundation.LocalizedStringResource", "valueKind": "RawLiteral", "value": .string(title)],
        "description": ["label": "description", "valueKind": "NilLiteral"],
        "default": ["label": "default", "valueKind": "NilLiteral"],
        "controlStyle": ["label": "controlStyle", "valueKind": "Runtime"],
        "requestValueDialog": ["label": "requestValueDialog", "valueKind": "NilLiteral"],
        "inputConnectionBehavior": ["label": "inputConnectionBehavior", "valueKind": "Runtime"],
    ]
    call.merge(arguments) { $1 }
    let initCall: JSONValue = [
        "type": type,
        "arguments": .array(call.keys.sorted().compactMap { call[$0] }),
    ]
    return [
        ["label": .string("_\(name)"), "type": type, "isStatic": "false", "isComputed": "false", "valueKind": "InitCall", "value": initCall],
        ["label": .string(name), "type": .string(value), "isStatic": "false", "isComputed": "true", "valueKind": "InitCall", "value": initCall],
        ["label": .string("$\(name)"), "type": type, "isStatic": "false", "isComputed": "true", "valueKind": "Runtime"],
    ]
}

private func decode(_ files: [String: Data]?) throws -> JSONValue {
    let data = try #require(files?["extract.actionsdata"])
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

@Test func appIntentsMetadataIndexesIntentsAndShortcuts() throws {
    let entries = [
        intent(
            "Shared.StopIntent",
            conformances: ["AppIntents.LiveActivityIntent"],
            properties: [literal("title", "stop.title"), literal("description", "stop.description")]
        ),
        intent(
            "App.OpenIntent",
            properties: [literal("title", "open.title"), literal("openAppWhenRun", "true")],
            result: ["AppIntents.IntentResult", "AppIntents.ProvidesDialog"]
        ),
        shortcuts,
        // types that don't involve App Intents are ignored
        ["typeName": "App.Other", "conformances": ["Swift.Sendable"], "availability": []],
    ]
    let files = try AppIntentsMetadata(
        entries: entries,
        sharedBundleIDs: ["Shared": ["com.example.app", "com.example.app.widget"]]
    ).files()
    #expect(files?["version.json"].map { String(decoding: $0, as: UTF8.self) }?.contains("\"17F113\"") == true)

    let metadata = try decode(files)
    #expect(metadata["autoShortcutProviderMangledName"] == "mangledShortcuts")

    let stop = try #require(metadata["actions"]?["StopIntent"])
    #expect(stop["title"] == ["alternatives": [], "key": "stop.title"])
    #expect(stop["descriptionMetadata"]?["descriptionText"]?["key"] == "stop.description")
    #expect(stop["systemProtocols"] == ["com.apple.link.systemProtocol.SessionStarting"])
    #expect(stop["systemProtocolMetadata"] == ["com.apple.link.systemProtocol.SessionStarting", ["empty": [:]]])
    #expect(stop["supportedModes"] == 1)
    #expect(stop["openAppWhenRun"] == false)
    #expect(stop["mangledTypeNameByBundleIdentifier"] == [
        "com.example.app": "mangledShared.StopIntent",
        "com.example.app.widget": "mangledShared.StopIntent",
    ])

    let open = try #require(metadata["actions"]?["OpenIntent"])
    #expect(open["supportedModes"] == 2)
    #expect(open["outputFlags"] == 4)
    #expect(open["mangledTypeNameByBundleIdentifier"]?.object?.isEmpty == true)
    #expect(open["descriptionMetadata"] == nil)

    #expect(metadata["autoShortcuts"] == [
        [
            "actionIdentifier": "StopIntent",
            "availabilityAnnotations": ["LNPlatformNameWildcard": ["introducedVersion": "*"]],
            "phraseTemplates": [["alternatives": [], "key": "Stop ${applicationName}"]],
            "shortTitle": ["alternatives": [], "key": "stop.short"],
            "systemImageName": "stop.fill",
        ],
    ])
}

@Test func appIntentsMetadataIndexesIntAndStringParameters() throws {
    let entries = [
        intent("Widgets.SetLevel", properties: [literal("title", "Set the level")] + parameter("level", "Swift.Int", title: "Level")),
        intent(
            "App.Search",
            properties: [literal("title", "Search")] + parameter(
                "query", "Swift.String", title: "Query",
                arguments: ["requestValueDialog": ["label": "requestValueDialog", "valueKind": "InitCall"]]
            )
        ),
    ]
    let metadata = try decode(try AppIntentsMetadata(entries: entries, sharedBundleIDs: [:]).files())
    func primitive(_ identifier: Int) -> JSONValue {
        ["primitive": ["wrapper": ["typeIdentifier": .int(identifier)]]]
    }
    func expected(_ name: String, _ title: String, _ valueType: JSONValue, _ inputTypes: [JSONValue]) -> JSONValue {
        [[
            "capabilities": 0, "dynamicOptionsSupport": 0, "inputConnectionBehavior": 0, "isInput": false,
            "isOptional": false, "name": .string(name),
            "resolvableInputTypes": .array(inputTypes.map { ["kindValue": 0, "valueType": $0] }),
            "title": ["alternatives": [], "key": .string(title)], "typeSpecificMetadata": [], "valueType": valueType,
        ]]
    }
    // As Xcode 26.6 writes them
    #expect(metadata["actions"]?["SetLevel"]?["parameters"]
        == expected("level", "Level", primitive(2), [primitive(0), primitive(7), primitive(2)]))
    #expect(metadata["actions"]?["Search"]?["parameters"] == expected(
        "query", "Query", primitive(0),
        [primitive(0), ["array": ["wrapper": ["capabilities": 3, "memberValueType": primitive(2)]]], primitive(2)]
    ))
}

@Test func appIntentsMetadataIsWrittenAsXcodeWritesIt() throws {
    let entries = [intent("App.OpenIntent", properties: [literal("title", "Ouvrir à/b")])]
    let files = try #require(try AppIntentsMetadata(entries: entries, sharedBundleIDs: [:]).files())
    let index = String(decoding: try #require(files["extract.actionsdata"]), as: UTF8.self)
    #expect(index.hasPrefix(#"{"actions":{"OpenIntent":{"assistantDefinedSchemaTraits":[],"#))
    #expect(index.contains(#""key":"Ouvrir à/b""#))
    #expect(String(decoding: try #require(files["version.json"]), as: UTF8.self)
        == "{\n  \"version\" : \"3.0\",\n  \"toolsVersion\" : \"17F113\"\n}")
}

@Test func appIntentsMetadataIsLeftOutWithoutIntents() throws {
    let entries: [JSONValue] = [["typeName": "App.Other", "conformances": ["SwiftUI.App"]]]
    #expect(try AppIntentsMetadata(entries: entries, sharedBundleIDs: [:]).files() == nil)
}

@Test func appIntentsMetadataRefusesWhatItCannotIndex() {
    let title = literal("title", "t")
    let cases: [JSONValue] = [
        intent("App.BoolIntent", properties: [title] + parameter("flag", "Swift.Bool", title: "Flag")),
        intent("App.OptionalIntent", properties: [title] + parameter("level", "Swift.Optional<Swift.Int>", title: "Level")),
        intent("App.DefaultIntent", properties: [title] + parameter(
            "level", "Swift.Int", title: "Level",
            arguments: ["default": ["label": "default", "valueKind": "RawLiteral", "value": "2"]]
        )),
        intent("App.ComputedParameterTitleIntent", properties: [title] + parameter(
            "level", "Swift.Int", title: "Level",
            arguments: ["title": ["label": "title", "valueKind": "Runtime"]]
        )),
        intent("App.NoTitleIntent", properties: []),
        intent("App.ComputedTitleIntent", properties: [["label": "title", "valueKind": "Runtime"]]),
        intent("App.EntityIntent", conformances: ["AppIntents.ForegroundContinuableIntent"], properties: [literal("title", "t")]),
        ["typeName": "App.Entity", "conformances": ["AppIntents.AppEntity"]],
    ]
    for entry in cases {
        #expect(throws: AppIntentsMetadata.Unsupported.self) {
            try AppIntentsMetadata(entries: [entry], sharedBundleIDs: [:]).files()
        }
    }
}
