// swift-tools-version: 6.0
import PackageDescription

// Runtime coordination tests inject synthetic services; they never launch the
// app or use real account storage. Xcode builds the application from project.yml.
let package = Package(
    name: "CCSwitcherPolicy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CCSwitcherPolicy",
            path: ".",
            exclude: [
                "AGENTS.md",
                "ARCHITECTURE.md",
                "BUILD_GUIDE.md",
                "CCSwitcher.xcodeproj",
                "CCSwitcherWidget",
                "CLAUDE.md",
                "COST_VERIFICATION.md",
                "MACOS_APP_PLAYBOOK.md",
                "README.de.md",
                "README.fr.md",
                "README.ja.md",
                "README.md",
                "README.zh-CN.md",
                "RELEASE_NOTES.md",
                "Tests",
                "Tools",
                "assets",
                "build",
                "docs",
                "project.yml",
                "scripts",
                "CCSwitcher/CCSwitcherApp.swift",
                "CCSwitcher/Info.plist",
                "CCSwitcher/Resources",
                "CCSwitcher/Views",
                "CCSwitcher/de.lproj",
                "CCSwitcher/en.lproj",
                "CCSwitcher/fr.lproj",
                "CCSwitcher/ja.lproj",
                "CCSwitcher/zh-Hans.lproj",
                "CCSwitcher/Models/AppStyle.swift",
                "CCSwitcher/Models/BrandColor.swift",
                "CCSwitcher/Models/DoubleUsagePromo.swift",
                "CCSwitcher/Models/MenuBarConfig.swift",
                "CCSwitcher/Models/MenuBarModule.swift",
                "CCSwitcher/Models/VerifiedAgainst.swift",
                "CCSwitcher/Services/StatusItemController.swift",
                "CCSwitcher/Services/UpdateChecker.swift"
            ],
            sources: [
                "CCSwitcher/AppState.swift",
                "Shared/WidgetData.swift",
                "CCSwitcher/Models/Account.swift",
                "CCSwitcher/Models/AccountBackup.swift",
                "CCSwitcher/Models/UsageData.swift",
                "CCSwitcher/Models/String+Obfuscation.swift",
                "CCSwitcher/Models/ActivityData.swift",
                "CCSwitcher/Models/CostData.swift",
                "CCSwitcher/Models/LocalStatsSnapshot.swift",
                "CCSwitcher/Services/AccountServices.swift",
                "CCSwitcher/Services/AutoSwitchEngine.swift",
                "CCSwitcher/Services/RefreshPolicy.swift",
                "CCSwitcher/Services/BoundedProcess.swift",
                "CCSwitcher/Services/CredentialSwitchTransaction.swift",
                "CCSwitcher/Services/OAuthCredential.swift",
                "CCSwitcher/Services/ActivityParser.swift",
                "CCSwitcher/Services/ClaudeService.swift",
                "CCSwitcher/Services/CostParser.swift",
                "CCSwitcher/Services/FileLogger.swift",
                "CCSwitcher/Services/KeychainService.swift",
                "CCSwitcher/Services/L10n.swift",
                "CCSwitcher/Services/LocalStatsWork.swift",
                "CCSwitcher/Services/PricingService.swift",
                "CCSwitcher/Services/SessionParseCache.swift",
                "CCSwitcher/Services/SessionParseCacheV2.swift",
                "CCSwitcher/Services/StatsParser.swift"
            ]
        ),
        .testTarget(name: "CCSwitcherPolicyTests", dependencies: ["CCSwitcherPolicy"], path: "Tests")
    ]
)
