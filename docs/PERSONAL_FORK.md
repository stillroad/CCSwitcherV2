# Personal fork

Based on upstream commit `80618d6` (version 1.12.0). The original account storage identifiers and formats are retained. The personal build is version 1.12.3 (69).

## Why the CPU was high

A three-second sample of the running upstream app showed its busy thread in `SessionParseCacheV2.scanAndParse` / `parseFile`, including JSON decoding and timestamp parsing. One recorded refresh walked 3,911 files, reparsed 22 changed files for about 211 seconds, and wrote a 236 MB parse cache. Upstream already caches unchanged files and polls active + one inactive account, so reducing account requests alone would not address that scan.

The fork removes local log parsing from the usage-refresh path. As of 1.12.2, it runs **only when requested** by default, with an optional daily schedule and an independent overlap guard. An explicitly selected schedule is preserved. Account monitoring and automatic switching continue while it works. A small aggregate snapshot preserves the last calculation time and results across restarts. Cost/activity cards show their own calculation time; yesterday's snapshot is not presented as today's usage. Unchanged parse caches are no longer rewritten.

Version 1.12.1 exposed a large-history case: multi-GB changed logs could leave the first calculation spinning for many minutes. Version 1.12.2 reads logs in 64 KB chunks, checks cancellation and a monotonic one-minute budget inside each file, and shows the current phase and a **Stop** button. It reads only the file length captured when the file is opened, so new appends cannot extend a scan indefinitely. A record over 8 MB ends the calculation with an explanation instead of allocating an unbounded buffer. Timestamp/version regexes are compiled once per file.

Cancelled, failed and timed-out scans keep the previous complete statistics and do not publish partial results as fresh. Attempts also advance the automatic schedule, persisted across relaunches, so a failed scan cannot restart every time account usage refreshes. The deadline is cooperative: an individual system read, bounded record decode or cache load/save must return before the next check can stop it.

The large in-memory parse cache is released when calculation finishes, fails or is stopped. The disk cache and small display snapshot remain. The parser is still not incremental within a changed file. Very large histories may exceed the budget and leave cost/activity statistics unavailable or outdated; there is no automatic retry loop. Account quota data and switching remain independent. Leave **Only when requested** selected to avoid background log scanning.

## Usage checks

- The active account retains the existing interval (5 minutes on a fresh installation). Existing preferences are preserved.
- With auto-switch enabled, checks accelerate to at most 60 seconds within 10 percentage points of either window's own threshold, and 15 seconds within 2 points. At the default 90% session / 99% weekly settings, this means 60-second checks at 80% session or 89% weekly, and 15-second checks at 88% session or 97% weekly.
- Inactive accounts default to an hourly interval, adjustable to 30 minutes, 3 hours or 6 hours. The scheduler checks for due work every 15 seconds and polls at most one due inactive account per automatic cycle, oldest attempt first. An inactive refresh does not force an extra active-account request. Requests are serialized, so an inactive deadline may be exceeded while another operation finishes.
- Startup and **Refresh all account usage now** seed/update the full list using staggered requests. Switching is evaluated after each account, and due active checks are interleaved through long sweeps. At startup, a threshold-exhausted account may switch to the first verified eligible account while the remaining reset data loads. Full refreshes do not force a log scan.
- A known quota reset makes an inactive account eligible for an early refresh once, rather than leaving its old exhausted reading until the next hour.
- Failed attempts also advance the inactive schedule so an inaccessible account cannot starve the others. Rate limits respect the full server deadline, including when a refresh or switch is requested.
- Menu-bar countdowns tick once a minute; account/configuration changes still update immediately through the existing observer. Unchanged account preferences are not rewritten every poll. Widget updates are coalesced to at most once a minute, except account switches; yesterday's local statistics display as unavailable.

## Automatic switching

Settings → General → Auto-switch contains separate limits and a selection strategy:

1. **5-hour session threshold:** defaults to 90%. This threshold always applies, including near a weekly reset.
2. **Weekly threshold:** defaults to 99%. The current account triggers a switch when either window reaches its own threshold. Both sliders range from 50% to 99% in one-point steps.
3. **Choose next account by:** soonest weekly reset (personal-build default) or most remaining quota (upstream behavior). Eligible accounts are ordered by the next future weekly reset; unknown/past reset timestamps sort last, and remaining quota breaks ties.
4. **Raise weekly threshold to 99% in the final 48 hours:** enabled by default. When the weekly reset is more than zero and at most 48 hours away, this raises only the weekly threshold to 99%. Outside that period, the weekly slider applies. It never raises the session threshold and has no additional effect when the weekly slider is already 99%.

Version 1.12.3 replaces the legacy shared threshold with independent 90% session / 99% weekly defaults. The previous `autoSwitchThreshold` preference is retained for rollback but no longer controls switching. Subsequent choices in the two new sliders are saved separately. The existing auto-switch on/off setting and strategy are preserved; if auto-switch was disabled, enable it to use these policies.

Candidates need 10 percentage points of session headroom (at most 80% session usage with a 90% trigger). Weekly usage must simply remain below the candidate's weekly threshold; no extra ten-point weekly margin is subtracted. At 90% session / 99% weekly, an account with 0% session and 93% weekly usage is eligible, even with several days until reset. Weekly usage at 98.9% is eligible; at 99% it is excluded until reset. A candidate with either applicable window exhausted is rejected.

Cached readings propose candidates; a successful fresh reading is required before a credential swap. Verification takes at most one extra fresh request per evaluation; already-fresh candidates may also be considered. A sample must belong to the current cycle and be no more than 30 seconds old to count as fresh. Failed verification candidates are skipped for a minute to let other accounts be tried. No valid candidate means stay on the current account. A five-minute cooldown prevents repeated switches, except when a fresh sample reaches either configured threshold. This prevents the cooldown from holding a new account at 90% session usage until it runs out. Login, manual switch, removal, add-account and another refresh cannot enter while automatic verification is rotating a backup token. Changes to either slider or other auto-switch settings abort an in-flight decision. The live CLI identity must be confirmed before automatic switching; an external login is not attributed to the previous account.

Polling cannot guarantee uninterrupted sessions: a burst can consume the last 1% between checks, the provider can throttle/delay usage readings, and running Claude clients decide when to reload credentials. Live account swaps are not exercised by the automated tests.

## Additional audit fixes

- Claude commands drain stdout and stderr independently while running, with an output cap and a deadline. Auth/status commands time out after 15 seconds; interactive login allows five minutes. A full pipe or hung CLI can no longer hold the refresh indefinitely. The network session uses a 15-second inactivity timeout and 20-second overall request timeout.
- Routine usage checks no longer launch `claude --version`; they check the executable and use the existing auth-status call. Explicit version checking remains available in Settings.
- `Retry-After` accepts both seconds and an HTTP date, including long server backoff periods. An account whose cached usage already reaches its threshold can still be reconsidered once per minute while its usage endpoint is parked, without bypassing that endpoint's deadline.
- Switching refuses to overwrite unreadable current credentials or proceed after a failed source backup. Token writes update an existing keychain item rather than deleting it first. A failed write or verification attempts to restore both previous credential stores, and restoration failures are surfaced. This is recovery handling, not an atomic transaction across macOS Keychain and the JSON file or across external Claude processes.
- Removing an active account actually switches to a remaining account before deleting its backup. A failed switch/removal keeps the source account visible. Removing the last account clears the active selection and does not immediately re-add it.
- Add/login/reauthentication captures check the expected identity before overwriting a saved backup. Login is stopped if backing up the current account fails.

## Build and install

Running the app requires **macOS 14 or later** and Claude Code already installed. The ZIP contains a universal app with both Apple Silicon (`arm64`) and Intel (`x86_64`) executables. Xcode and XcodeGen are only needed to build from source:

```sh
swift test
scripts/build-personal.sh
```

Outputs:

- `build/DerivedData/Build/Products/Release/CCSwitcher.app`
- `build/CCSwitcher-Personal.zip`

### Replace CCSwitcher on another Mac

1. Download the personal ZIP from [this fork's releases](https://github.com/stillroad/CCSwitcherV2/releases), or AirDrop the ZIP built on the first Mac. Extract it.
2. Quit CCSwitcher on the destination Mac. Keep a copy of its original app so you can roll back, then replace `/Applications/CCSwitcher.app` with the extracted app. Replace the app itself; keep its preferences and Keychain entries.
3. Open the new app from Applications. Because this is an **ad-hoc-signed, unnotarized** personal build, macOS may require System Settings → Privacy & Security → **Open Anyway** after the first attempt. Follow [Apple's opening instructions](https://support.apple.com/en-hk/102445).
4. Approve a Keychain access prompt for the replacement app if one appears. The signing identity changed, so an existing permission may need to be granted again. [Apple explains Allow Once and Always Allow](https://support.apple.com/en-euro/guide/keychain-access/kyca1243/mac).
5. Check that the Mac's existing account list appears and the active account matches Claude. Use **Refresh all account usage now** once, then verify the switching settings. Auto-switch on/off, strategy and refresh intervals are inherited from that Mac's preferences. The independent sliders start at 90% session / 99% weekly when upgrading from the old shared threshold.

The fork uses the destination Mac's existing accounts and settings. The ZIP contains the application only; it carries no account credentials or preferences from the build machine. The stable identifiers are:

| Data | Identifier/location retained |
| --- | --- |
| App/preferences domain | `me.xueshi.ccswitcher` |
| Saved account list | `com.ccswitcher.accounts` in that preferences domain |
| Account backups | Keychain service `me.xueshi.ccswitcher.backups`, account `all-accounts` |
| Older backup migration | `~/.ccswitcher/backups.json` |
| Live Claude credentials | `Claude Code-credentials` Keychain item and `~/.claude.json` |

Existing valid sign-ins should be reused after granting any needed Keychain access. Expired/revoked credentials may still need re-authentication. Running both apps at once on one Mac can interleave writes to the same credentials, so keep only one copy running. Separate Macs choose accounts independently; there is no cross-device lock or account-list synchronization. Usage consumed on either Mac contributes to the same account quotas.

The app and embedded widget are compiled for both architectures and signed with their entitlements. Desktop-widget registration and App Group authorization on another Mac are **not validated** by the local preview or signature check. The app has not been notarized or run on Intel hardware in this audit.

The personal-build flag prevents Sparkle from being initialized even if the existing installation has automatic updates enabled. Future upstream changes must be merged into this fork and rebuilt. To roll back, quit the fork and replace it with the original app; the account storage format is unchanged.

## Validation

The 2026-10-25 audit and regression suite passed **74 automated tests**. The Release app and widget compiled for both architectures, and the packaged app passed strict signature verification. Live OAuth swaps, Intel execution and registration on a second Mac were not exercised by the test suite.

`swift test` covers reset ordering, both threshold modes, exact 48-hour/99% boundaries, invalid and stale readings, provider isolation, cooldown exceptions, nine-account scheduling, server backoff, reset-triggered refreshes, adaptive active polling, daily statistics scheduling and snapshot persistence. It also exercises the actual AppState orchestration with injected in-memory services: concurrent credential operations, a nine-account slow sweep, failed removal, changed external identity, backup write failure, stale candidate verification and long backoff. Subprocess tests use harmless local commands to cover pipe saturation, timeout, output limits and exit codes. Credential transaction tests inject write and verification failures. No test reads real credentials or contacts Claude. Test preference suites and files are isolated and cleaned up.

Statistics regression tests cover a 4 GB sparse file without loading it into memory, chunk boundaries and UTF-8, appending/truncating logs during a read, within-file deadlines and cancellation, maximum-output deduplication, preservation of the complete cache after failure, and unavailable history. AppState tests verify spinner cleanup, no repeated retries after failure/relaunch, manual defaults, and account polling while a statistics job is running.

Separate-threshold regressions cover nine accounts with high weekly usage and empty sessions, independent exact trigger boundaries, weekly candidate eligibility up to (but below) 99%, session headroom, weekly-only near-reset overrides, adaptive polling for either threshold, and fresh-threshold cooldown bypass. Coordinator tests verify custom slider values, legacy shared-99% upgrades, rejection of a candidate whose fresh weekly usage reaches 99%, and cancellation of an in-flight decision when either slider changes.

`CCSwitcherPreview` is an isolated native settings preview target. It uses its own preferences domain and an empty AppState; it never starts account polling or restores credentials. The new controls were inspected in this preview. The Release application and widget are also compiled together.

```sh
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcherPreview \
  -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Build configuration remains in `project.yml`; generated Xcode project and Info.plist files are disposable.
