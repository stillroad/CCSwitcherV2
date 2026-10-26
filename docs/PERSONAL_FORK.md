# Personal fork

Based on upstream commit `80618d6` (version 1.12.0). The original account storage identifiers and formats are retained. The personal build is version 1.12.5 (71).

## Why the CPU was high

A three-second sample of the running upstream app showed its busy thread in `SessionParseCacheV2.scanAndParse` / `parseFile`, including JSON decoding and timestamp parsing. One recorded refresh walked 3,911 files, reparsed 22 changed files for about 211 seconds, and wrote a 236 MB parse cache. Upstream already caches unchanged files and polls active + one inactive account, so reducing account requests alone would not address that scan.

The fork removes local log parsing from the usage-refresh path. As of 1.12.2, it runs **only when requested** by default, with an optional daily schedule and an independent overlap guard. An explicitly selected schedule is preserved. Account monitoring and automatic switching continue while it works. A small aggregate snapshot preserves the last calculation time and results across restarts. Cost/activity cards show their own calculation time; yesterday's snapshot is not presented as today's usage. Unchanged parse caches are no longer rewritten.

Version 1.12.1 exposed a large-history case: multi-GB changed logs could leave the first calculation spinning for many minutes. Version 1.12.2 reads logs in 64 KB chunks, checks cancellation and a monotonic one-minute budget inside each file, and shows the current phase and a **Stop** button. It reads only the file length captured when the file is opened, so new appends cannot extend a scan indefinitely. A record over 8 MB ends the calculation with an explanation instead of allocating an unbounded buffer. Timestamp/version regexes are compiled once per file.

Cancelled, failed and timed-out scans keep the previous complete statistics and do not publish partial results as fresh. Attempts also advance the automatic schedule, persisted across relaunches, so a failed scan cannot restart every time account usage refreshes. The deadline is cooperative: an individual system read, bounded record decode or cache load/save must return before the next check can stop it.

The large in-memory parse cache is released when calculation finishes, fails or is stopped. The disk cache and small display snapshot remain. The parser is still not incremental within a changed file. Very large histories may exceed the budget and leave cost/activity statistics unavailable or outdated; there is no automatic retry loop. Account quota data and switching remain independent. Leave **Only when requested** selected to avoid background log scanning.

## Usage checks

- The active account retains the existing interval (5 minutes on a fresh installation). Existing preferences are preserved.
- Usage checks stay at the selected interval even near a switching threshold. Version 1.12.4 removes the automatic 60/15-second speed-up: fast polling preceded long periods without readings when the usage endpoint rejected requests. A single timer is scheduled from the actual cycle/request timestamp, avoiding the extra 15-second delay caused by the previous timer grid. It runs in common run-loop modes, including while menus are open.
- Inactive accounts default to an hourly interval, adjustable to 30 minutes, 3 hours or 6 hours. Each normal cycle polls at most one due inactive account, oldest attempt first. There is no separate fast polling loop. An inactive deadline or reset is handled on a normal cycle; requests are serialized, so deadlines may be exceeded while another operation finishes.
- Startup and **Refresh all account usage now** seed/update the full list using staggered requests. Switching is evaluated after each account, and due active checks are interleaved through long sweeps. At startup, a threshold-exhausted account may switch to the first verified eligible account while the remaining reset data loads. Full refreshes do not force a log scan.
- A known quota reset makes an inactive account eligible for an early refresh once, rather than leaving its old exhausted reading until the next hour.
- Failed attempts also advance the inactive schedule so an inaccessible account cannot starve the others. A failed candidate verification counts as that sweep's attempt, preventing an immediate duplicate request. Rate limits wait 5, 10, 20, then 30 minutes after consecutive failures, or longer if the user interval or server deadline requires it. A successful reading resets this backoff. Manual refreshes and candidate verification also respect parking. Backoff is held in memory during the current run.
- Menu-bar countdowns tick once a minute; account/configuration changes still update immediately through the existing observer. Unchanged account preferences are not rewritten every poll. Widget updates are coalesced to at most once a minute, except account switches; yesterday's local statistics display as unavailable.

## Automatic switching

Use the pause button beside an account in **Usage** or **Accounts** to exclude it from automatic rotation. Paused accounts show **Rotation paused** and a resume button. Their sign-in and usage history stay available, and **Switch** still selects them manually without clearing the pause. Pausing the active account leaves its current session running; normal threshold switching can still move away from it. Resume makes it eligible again on the next normal evaluation, subject to the existing quota checks. If all alternatives are paused, automatic switching stays on the current account.

The pause choice survives app restarts and is local to each Mac. Existing accounts remain in rotation on upgrade. Pausing during candidate verification cancels selection of that account; the button is briefly disabled once the credential swap itself has begun. Pausing and resuming issue no usage requests, and do not change the polling intervals.

Settings → General → Auto-switch contains separate limits and a selection strategy:

1. **5-hour session threshold:** defaults to 90%. This threshold always applies, including near a weekly reset.
2. **Weekly threshold:** defaults to 99%. The current account triggers a switch when either window reaches its own threshold. Both sliders range from 50% to 99% in one-point steps.
3. **Choose next account by:** soonest weekly reset (personal-build default) or most remaining quota (upstream behavior). Eligible accounts are ordered by the next future weekly reset; unknown/past reset timestamps sort last, and remaining quota breaks ties.
4. **Raise weekly threshold to 99% in the final 48 hours:** enabled by default. When the weekly reset is more than zero and at most 48 hours away, this raises only the weekly threshold to 99%. Outside that period, the weekly slider applies. It never raises the session threshold and has no additional effect when the weekly slider is already 99%.

Version 1.12.3 replaces the legacy shared threshold with independent 90% session / 99% weekly defaults. The previous `autoSwitchThreshold` preference is retained for rollback but no longer controls switching. Subsequent choices in the two new sliders are saved separately. The existing auto-switch on/off setting and strategy are preserved; if auto-switch was disabled, enable it to use these policies.

Candidates need 10 percentage points of session headroom (at most 80% session usage with a 90% trigger). Weekly usage must simply remain below the candidate's weekly threshold; no extra ten-point weekly margin is subtracted. At 90% session / 99% weekly, an account with 0% session and 93% weekly usage is eligible, even with several days until reset. Weekly usage at 98.9% is eligible; at 99% it is excluded until reset. A candidate with either applicable window exhausted is rejected.

Cached readings propose candidates; a successful fresh reading is required before a credential swap. Verification takes at most one extra request per active account per configured interval; already-fresh candidates may also be considered. A sample must belong to the current cycle and be no more than 30 seconds old to count as fresh. Failed candidates are skipped for two configured intervals to let another candidate be tried on the following cycle; any successful new reading clears that exclusion. No valid candidate means stay on the current account. A five-minute cooldown prevents repeated switches, except when a fresh sample reaches either configured threshold. This prevents the cooldown from holding a new account at 90% session usage until it runs out. Login, manual switch, removal, add-account and another refresh cannot enter while automatic verification is rotating a backup token. Changes to either slider or other auto-switch settings abort an in-flight decision. The live CLI identity must be confirmed before automatic switching; an external login is not attributed to the previous account.

When the active account's usage check is rate-limited and its last known, unexpired window is within two percentage points of its threshold, auto-switch can leave early. At 90% session / 99% weekly this means at least 88% session or 97% weekly. This fallback still requires a freshly verified eligible destination and respects the switch cooldown. Healthy checks continue to use the exact configured thresholds. Unknown or expired windows cannot trigger the fallback; the trigger is checked again after candidate verification in case a reset occurred during that request. Rate-limit warnings remain visible alongside cached usage and its original timestamp.

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

The 2026-10-26 regression suite passed **93 automated tests**. The Release app and widget compiled for both architectures, and the packaged app passed strict signature verification. Pause/resume controls were exercised in both tabs in the native preview at the real 360-point menu width. Live OAuth swaps, Intel execution and registration on a second Mac were not exercised by the test suite.

`swift test` covers reset ordering, both threshold modes, exact 48-hour/99% boundaries, invalid and stale readings, provider isolation, cooldown exceptions, nine-account scheduling, server backoff, reset-triggered refreshes, fixed active polling, daily statistics scheduling and snapshot persistence. It also exercises the actual AppState orchestration with injected in-memory services: concurrent credential operations, a nine-account slow sweep, failed removal, changed external identity, backup write failure, stale candidate verification and long backoff. Subprocess tests use harmless local commands to cover pipe saturation, timeout, output limits and exit codes. Credential transaction tests inject write and verification failures. No test reads real credentials or contacts Claude. Test preference suites and files are isolated and cleaned up.

Statistics regression tests cover a 4 GB sparse file without loading it into memory, chunk boundaries and UTF-8, appending/truncating logs during a read, within-file deadlines and cancellation, maximum-output deduplication, preservation of the complete cache after failure, and unavailable history. AppState tests verify spinner cleanup, no repeated retries after failure/relaunch, manual defaults, and account polling while a statistics job is running.

Separate-threshold regressions cover nine accounts with high weekly usage and empty sessions, independent exact trigger boundaries, weekly candidate eligibility up to (but below) 99%, session headroom, weekly-only near-reset overrides, fixed polling near either threshold, and fresh-threshold cooldown bypass. Coordinator tests verify custom slider values, legacy shared-99% upgrades, rejection of a candidate whose fresh weekly usage reaches 99%, and cancellation of an in-flight decision when either slider changes.

Version 1.12.4 regressions reproduce five-minute scheduling with request latency, near-limit active-account 429s, repeated zero Retry-After responses, progressive backoff and recovery, failed-verification request limits, fresh exhausted candidates, and a quota reset during fallback verification.

Version 1.12.5 regressions cover loading older saved accounts without a pause field, pause persistence, both selection strategies and rate-limit fallback, manual use of a paused account, resuming automatic eligibility, all alternatives paused, switching away from a paused active account, and pausing during verification. The `--rotation` native preview uses synthetic accounts at the real menu width and allows testing pause/resume in both tabs without credentials or polling.

`CCSwitcherPreview` is an isolated native settings preview target. It uses its own preferences domain and an empty AppState; it never starts account polling or restores credentials. The new controls were inspected in this preview. The Release application and widget are also compiled together.

```sh
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcherPreview \
  -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Build configuration remains in `project.yml`; generated Xcode project and Info.plist files are disposable.
