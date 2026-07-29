import ProjectDescription

let project = Project(
    name: "TalkToMe",
    targets: [
        .target(
            name: "TalkToMe",
            destinations: [.iPhone, .iPad, .mac],
            product: .app,
            bundleId: "com.mightystrongsoftware.TalkToMe",
            deploymentTargets: .multiplatform(
                iOS: "26.0",
                macOS: "26.0"
            ),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "TalkToMe",
                "NSMicrophoneUsageDescription": "TalkToMe listens to your voice so it can transcribe what you say.",
                "NSSpeechRecognitionUsageDescription": "TalkToMe uses on-device speech recognition to turn your voice into text.",
                "UILaunchScreen": [:],
            ]),
            sources: ["Sources/TalkToMeApp/**"],
            resources: [
                .folderReference(path: "Resources/Piper", inclusionCondition: .when([.macos])),
            ],
            entitlements: .file(path: "Support/TalkToMe.entitlements"),
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                ]
            )
        )
    ]
)
