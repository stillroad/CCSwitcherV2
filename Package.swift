// swift-tools-version: 6.0
import PackageDescription

// Pure policy tests run without launching the app, reading credentials or
// contacting Claude. The application is still built from project.yml.
let package = Package(
    name: "CCSwitcherPolicy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CCSwitcherPolicy",
            path: "CCSwitcher",
            exclude: [
                "AppState.swift", "CCSwitcherApp.swift", "Info.plist", "Resources", "Views",
                "en.lproj", "de.lproj", "fr.lproj", "ja.lproj", "zh-Hans.lproj",
                "Models/AppStyle.swift", "Models/BrandColor.swift", "Models/DoubleUsagePromo.swift",
                "Models/MenuBarConfig.swift", "Models/MenuBarModule.swift", "Models/VerifiedAgainst.swift",
                "Services/ActivityParser.swift", "Services/ClaudeService.swift", "Services/CostParser.swift",
                "Services/FileLogger.swift", "Services/KeychainService.swift", "Services/L10n.swift",
                "Services/PricingService.swift", "Services/SessionParseCache.swift",
                "Services/SessionParseCacheV2.swift", "Services/StatsParser.swift",
                "Services/StatusItemController.swift", "Services/UpdateChecker.swift"
            ],
            sources: [
                "Models/Account.swift", "Models/UsageData.swift", "Models/String+Obfuscation.swift",
                "Models/ActivityData.swift", "Models/CostData.swift", "Models/LocalStatsSnapshot.swift",
                "Services/AutoSwitchEngine.swift", "Services/RefreshPolicy.swift"
            ]
        ),
        .testTarget(name: "CCSwitcherPolicyTests", dependencies: ["CCSwitcherPolicy"], path: "Tests")
    ]
)
