# Validation results

Version **0.2.0**, tested October 9, 2026; consolidated October 10. Host: Apple M1 Max, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4. Both native macOS Xcode targets and direct arm64 builds passed. The deployment target is macOS 14; live capture on earlier OS versions has not been validated.

The public [results.json](validation/results.json) contains aggregate measurements derived from the recorded local reports. Notification text, names, IDs, hashes, exact event times, host paths and app inventories are omitted.

## Correctness and recovery

**58 fixture checks** passed. Coverage includes binary plist decoding; Unicode, multiline and long text; identical text with distinct identities; revision detection; source filtering and case aliases; WAL writes; fresh-process recovery; atomic source database replacement; failed commit rollback/retry; malformed-record repair; bounded payload retention; log rotation; persisted controls; and singleton ownership. Recorded synthetic temporary-banner and persistent-alert trees test AX extraction. See [unit-tests.txt](validation/unit-tests.txt).

**15 native application lifecycle checks** passed against a disposable source database with AX disabled. These exercise persisted stop/resume, restart catch-up, stale-command suppression, single-instance ownership, JSON cursor retrieval, healthy/stale heartbeat handling and empty-source rejection. AppKit startup required access to the local GUI session outside the restricted shell sandbox.

## Hardened live synthetic suite

Settings: persistent alerts, previews Always, grouping Off. Every request appeared in retained delivery snapshots. Each captured title, subtitle and body matched the payload macOS delivered.

| Test | Requests | Database IDs | AX IDs | Exact delivered payloads, DB / AX |
| --- | ---: | ---: | ---: | ---: |
| Smoke, 1/s | 5 | 5 | 5 | 5 / 5 |
| Baseline, 1/s | 20 | 20 | 20 | 20 / 20 |
| Burst, 5/s | 20 | 20 | 20 | 20 / 20 |
| Identical visible text | 2 | 2 | 2 | 2 / 2 |
| Long / Unicode | 1 | 1 | 1 | 1 / 1 |
| **Total** | **48** | **48** | **48** | **48 / 48** |

The durable feed contained 48 distinct request IDs, notification IDs and sequences, with exact delivered fields. AX UUIDs distinguish separate notifications that have identical visible text.

| Delivery-to-observation delay | Median | Maximum |
| --- | ---: | ---: |
| Baseline database | 15.352 s | 24.852 s |
| Baseline AX | 0.482 s | 0.878 s |
| Burst database | 9.223 s | 11.124 s |
| Burst AX | 1.145 s | 1.633 s |

These are wall-clock delays after macOS delivery, not network-to-message latency or guaranteed bounds. Polling every 500 ms does not eliminate OS persistence batching.

The long test requested 2,211 Unicode code points. macOS delivered 1,999 code points (2,000 UTF-16 code units). Both probes captured the delivered body exactly; omitted source text cannot be recovered.

## Live app restart

Capture was closed normally. The local sender delivered five additional notifications before it reopened. The database probe recovered **5/5**, preserving their delivered text. The durable feed grew from **48 to 53** events without replaying earlier IDs. The previous start command stayed consumed, both permissions survived the unchanged binary's restart, and capture returned healthy. AX seeded existing visible cards as history and was not used for recovery.

## Actual Discord

The earlier prototype captured **five distinct Discord notifications** through both probes with matching titles and bodies. Its database delay ranged from 5.473 to 10.883 seconds, median 5.605 seconds.

The hardened build saved **six distinct Discord notifications** to its durable feed. All six IDs joined to AX observations, and all six titles and bodies matched both journals. Database delay was **5.429–5.598 seconds**, median **5.554 seconds**. Discord's database subtitles were empty; AX omitted that empty field.

The first two hardened AX observations arrived after 0.601 and 0.606 seconds. Four subsequent cards were first observed approximately 21–44 minutes after delivery; the cause was not established. AX also produced eight raw observations for six IDs because cards can reappear. The primary database feed kept six distinct events and captured them promptly. This is why AX remains optional.

The eleven actual notifications across both versions were uncontrolled arrivals. No independently known count of expected Discord messages or original source text/send time was available. This proves retrieval of observed notification payloads, not complete coverage of all Discord traffic.

## Implementation lessons

- Temporary alerts with Automatic grouping captured 48/48 through the database but only 33/48 through AX; the 5/s burst yielded 5/20 AX observations.
- A banner-only AX parser initially captured 0/40 persistent alerts while the database captured 40/40. Persistent cards expose `AXNotificationCenterAlert`; recognizing source/field structure fixed synthetic coverage.
- Discord reports `com.hnc.Discord` as the app bundle but `com.hnc.discord` in the database. Filters and event identities now normalize case.
- Ad-hoc rebuilds invalidated permission registrations and once stalled startup while opening a local file. Re-adding the exact app and fully restarting restored access; subsequent restart of the frozen binary retained grants.
- Xcode emitted simulator/device framework warnings while both native macOS builds completed. No simulator repair was required.

## Remaining validation

A controlled Discord source-text/timing test; foreground suppression, Focus, lock/display sleep and reconnect cases; Mini login/logout, reboot and actual launchd crash recovery; and a continuous 24–48-hour soak with storage-growth checks. The per-user agent was generated and syntax-checked, but was not installed on the development Mac. A later stale heartbeat means the local session does not establish uninterrupted overnight operation. X/Twitter and Android/emulator capture are outside the implemented scope.
