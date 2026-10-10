# Operations

## Project layout

`Sources/` contains the native Swift apps and probes. `Tests/` contains disposable SQLite tests and synthetic AX fixtures. `NotificationLab.xcodeproj` has shared Capture and Generator schemes. `scripts/` provides building, controls, reading, health, testing, analysis and packaging.

Generated local data is excluded from Git:

| Path | Purpose |
| --- | --- |
| `apps/` | Built Capture and synthetic Sender apps |
| `state/capture.sqlite` | Durable events and seen-ID fingerprints |
| `state/configuration.json` | Sources, active state, AX toggle and consumed command |
| `runs/` | Per-session database/AX journals and diagnostics |
| `generator/` | Synthetic requests, results and retained-delivery snapshots |
| `capture-health.json` | Collector heartbeat and feed counts |
| `deployment/` | Machine-specific agent and local Mini ZIP |
| `work/` | Build caches and disposable fixtures |

Do not commit or transfer runtime state between Macs. Raw local validation reports are also ignored; only aggregate `validation/results.json` and the fixture check log are published.

## Capture behavior

The source database is `~/Library/Group Containers/group.com.apple.usernoted/db2/db`, opened read-only. Schema discovery checks required columns and notices file replacement. SQL filters selected bundle IDs before decoding notification content. The default normalized source is `com.hnc.discord`.

The collector polls every 500 ms. Its own SQLite transaction writes the event and deduplication checkpoint together. Failed commits roll back and retry later. First use of a source seeds retained history; subsequent restarts resume it. UUID identity is preferred; request ID or database row position are fallbacks, with provisional identity labeled explicitly.

The feed retains the newest 10,000 events. Seen-ID fingerprints remain for deduplication and grow with the total notification count. The state directory is owner-only (0700). Each JSONL stream rotates around 2 MiB with three archives; Capture keeps ten session directories. A large individual record can exceed the rotation threshold. Preserve local evidence before retention removes it.

AX subscribes to supported UI events and polls as a fallback, with traversal limits. Its journal can miss, delay or repeat observations when cards are hidden, grouped or redisplayed. It is separate from the durable feed.

## Controls and health

```sh
python3 scripts/command.py capture start --sources com.hnc.discord
python3 scripts/command.py capture stop
python3 scripts/command.py capture disable_ax
python3 scripts/command.py capture enable_ax
python3 scripts/command.py capture inventory
python3 scripts/command.py capture diagnose
```

Capture commands have unique IDs, wait up to ten seconds for acknowledgement by default, and persist the consumed ID. Sources, active/stop state and the AX setting survive restart. The other command is `request_accessibility`; it opens the usual OS authorization flow rather than granting access automatically.

`python3 scripts/health.py` exits 0 for healthy and fresh capture, 1 for stopped/degraded/stale capture, and 2 for missing status. The heartbeat updates every two seconds and is stale after 15 seconds. Healthy means the collector can scan and persist; it does not prove Discord is online or issuing notifications. Startup errors that reach the app are recorded in `startup-error.json`.

Read with `python3 scripts/read_events.py --follow --source com.hnc.discord`. `--after N` resumes after a sequence. A nonzero cursor older than retained history raises a gap error; `--after 0` reads the oldest available event. The reader opens only the collector's own database read-only.

## Xcode and development

Open `NotificationLab.xcodeproj` and select a shared scheme. Schemes set `NOTIFICATION_LAB_ROOT` to the source root. CLI equivalent:

```sh
xcodebuild -project NotificationLab.xcodeproj \
  -scheme NotificationLabCapture -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath work/xcode build CODE_SIGN_IDENTITY=-
```

Build intermediates and fixtures use `work/`, or `NOTIFICATION_LAB_WORK` when supplied. `NOTIFICATION_LAB_BUILD_APPS` chooses another app directory so development does not overwrite an authorized collector. A staged app launched manually needs `NOTIFICATION_LAB_ROOT` set to the intended data directory; the fixture lifecycle runner sets its own isolated root.

Rebuilding/moving an ad-hoc signed app may require re-adding the exact binary to Full Disk Access and Accessibility. Full Disk Access takes effect after a complete restart. Keep a frozen, tested binary for unattended use; stable signing is not configured by this project.

## Live synthetic tests

Launch `apps/NotificationLabGenerator.app`, shown as **NotificationLab Sender**, and allow its notifications. Use persistent alerts, grouping Off and previews Always. Start Capture before sending requests:

```sh
python3 scripts/command.py capture start --sources com.hnc.discord,local.notificationlab.generator
python3 scripts/run_suite.py
python3 scripts/command.py generator stop
python3 scripts/command.py capture start --sources com.hnc.discord
```

The suite posts smoke (5 at 1/s), baseline (20 at 1/s), burst (20 at 5/s), identical text (2) and long/Unicode (1). It waits for sender completion and retained-delivery snapshots, then measures coverage, fidelity and latency. Accepted requests alone do not prove delivery; retained snapshots are positive evidence, not complete history.

For a single run, use `python3 scripts/command.py generator smoke`, get the run ID from `generator/generator-status.json`, then `python3 scripts/analyze.py --run RUN_ID`. Sender also accepts `baseline`, `burst`, `identical`, `long`, `snapshot` and `request_permission`. Its consumed ID is session-local: leave a fresh `stop` command before quitting so relaunch does not repeat a test. Sender has one pending command file; wait for consumption before writing another.

## Mini deployment

Build on the target Mac, or create a local package with `python3 scripts/package_mini.py`. The ZIP includes the apps, source, documentation, synthetic fixtures and curated aggregate results. It excludes captured messages, raw reports, state, commands and machine-specific agents. The package targets Apple Silicon and macOS 14 or later; test the Mini's actual OS/database format.

1. Put the project at a stable location, such as `~/NotificationLab`, and launch Capture from its final app path.
2. Grant Full Disk Access and optionally Accessibility. Configure Discord notifications and verify a healthy heartbeat. To use only the database, issue `capture disable_ax`.
3. Quit the manual collector and, within two minutes of verifying health, run `python3 scripts/login_agent.py install`. This writes `~/Library/LaunchAgents/local.notificationlab.capture.plist` for the current GUI user and loads it. No root daemon is installed.
4. Check `python3 scripts/login_agent.py status` and a fresh healthy heartbeat. The `NL` menu-bar item opens the status window. The agent runs at GUI login and restarts after an abnormal exit; ordinary Quit stops it until next login or explicit restart. A persisted `stop` pauses capture without exiting.
5. Remove the agent with `python3 scripts/login_agent.py uninstall`. `prepare` generates its absolute-path plist without installing it; generate it on the target Mac.
6. Keep the GUI account logged in and test actual sleep/lock settings, reconnect, restart, incoming notifications and storage growth in a 24–48-hour soak. Those deployment cases remain unverified.

The agent follows Apple's [per-user LaunchAgent model](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) and [launchd plist keys](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5). Payload decoding was informed by the primary-source [mac_apt notification parser](https://github.com/ydkhatri/mac_apt/blob/master/plugins/notifications.py); the UI probe uses [AXObserver](https://developer.apple.com/documentation/applicationservices/axobserver), and Sender uses [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter) for its own notifications.
