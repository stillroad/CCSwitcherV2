# Personal fork

Based on upstream commit `80618d6` (version 1.12.0). The original account storage and credential-switching implementation are retained.

## Why the CPU was high

A three-second sample of the running upstream app showed its busy thread in `SessionParseCacheV2.scanAndParse` / `parseFile`, including JSON decoding and timestamp parsing. One recorded refresh walked 3,911 files, reparsed 22 changed files for about 211 seconds, and wrote a 236 MB parse cache. Upstream already caches unchanged files and polls active + one inactive account, so reducing account requests alone would not address that scan.

The fork removes local log parsing from the usage-refresh path. It runs as a separate background task, once per day by default, with an independent overlap guard. Account monitoring and automatic switching continue while it works. A small aggregate snapshot preserves the last calculation time and results across restarts. Cost/activity cards show their own calculation time; yesterday's snapshot is not presented as today's usage. Unchanged parse caches are no longer rewritten.

This changes when expensive scans run; it does not make the JSONL parser incremental. A requested/daily scan can still consume CPU while running. Choose **Only when requested** to eliminate automatic scans entirely.

## Usage checks

- The active account retains the existing interval (5 minutes on a fresh installation). Existing preferences are preserved.
- With auto-switch enabled, checks accelerate to at most 60 seconds within 10 percentage points of the effective threshold, and 15 seconds within 2 points.
- Inactive accounts default to an hourly interval, adjustable to 30 minutes, 3 hours or 6 hours. Automatic cycles poll at most one due inactive account, oldest attempt first. With many accounts or a long active interval, actual inactive refreshes can be later than the chosen interval.
- Startup and **Refresh all account usage now** seed/update the full list using staggered requests. They do not force a log scan.
- A known quota reset makes an inactive account eligible for an early refresh once, rather than leaving its old exhausted reading until the next hour.
- Failed attempts also advance the inactive schedule so an inaccessible account cannot starve the others. Rate limits respect the full server deadline, including when a refresh or switch is requested.
- Menu-bar countdowns tick once a minute; account/configuration changes still update immediately through the existing observer.

## Automatic switching

Settings → General → Auto-switch contains two independent controls:

1. **Choose next account by:** soonest weekly reset (personal-build default) or most remaining quota (upstream behavior). The app keeps using the current account until its threshold is reached. It then orders eligible accounts by the next future weekly reset; unknown/past reset timestamps sort last, and remaining quota breaks ties.
2. **Use up to 99% in the last 48 hours before weekly reset:** enabled by default. When the active account's weekly reset is more than zero and at most 48 hours away, the effective threshold becomes 99% for both the 5-hour and weekly windows. Outside that period, the configured normal threshold applies. This option also works with the original most-remaining mode.

The current auto-switch on/off setting and normal threshold are preserved. If auto-switch was disabled, enable it to use either strategy.

Candidates normally need 10 percentage points of headroom below their own effective threshold. A candidate in its final 48 hours may be selected up to 98%, leaving a point before its 99% switch threshold. Both windows are checked; a candidate with either window exhausted is rejected.

Cached readings propose candidates; a successful fresh reading is required before a credential swap. Verification takes at most one extra fresh request per evaluation; already-fresh candidates may also be considered. Failed verification candidates are skipped for a minute to let other accounts be tried. No valid candidate means stay on the current account. A five-minute cooldown prevents repeated switches, except when a fresh sample already reports at least 99%. Removed accounts, concurrent login/switch operations and changed settings abort an in-flight automatic decision.

Polling cannot guarantee uninterrupted sessions: a burst can consume the last 1% between checks, the provider can throttle/delay usage readings, and running Claude clients decide when to reload credentials. Live account swaps are not exercised by the automated tests.

## Build and install

Requires macOS 14+, Xcode and XcodeGen (`brew install xcodegen`).

```sh
swift test
scripts/build-personal.sh
```

Outputs:

- `build/DerivedData/Build/Products/Release/CCSwitcher.app`
- `build/CCSwitcher-Personal.zip`

Quit the existing CCSwitcher before opening the personal build. To install, keep a copy of the original app, then replace `/Applications/CCSwitcher.app` with the built app. The bundle identifier, preferences and account backup locations are retained, so the existing account list is reused. Run only one copy at a time because both manage the same Claude credentials. This is a locally ad-hoc-signed build, not an upstream notarized release; desktop-widget signing/registration is not validated by the local UI preview.

The personal-build flag prevents Sparkle from being initialized even if the existing installation has automatic updates enabled. Future upstream changes must be merged into this fork and rebuilt.

## Validation

`swift test` covers reset ordering, both threshold modes, exact 48-hour/99% boundaries, invalid and stale readings, provider isolation, cooldown exceptions, nine-account scheduling, server backoff, reset-triggered refreshes, adaptive active polling, daily statistics scheduling and snapshot persistence. It uses synthetic accounts and temporary files, without accessing real credentials or calling Claude.

`CCSwitcherPreview` is an isolated native settings preview target. It uses its own preferences domain and an empty AppState; it never starts account polling or restores credentials. The new controls were inspected in this preview. The Release application and widget are also compiled together.

```sh
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcherPreview \
  -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Build configuration remains in `project.yml`; generated Xcode project and Info.plist files are disposable.
