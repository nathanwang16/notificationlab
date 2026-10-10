# NotificationLab

Retrieve Discord notifications delivered to macOS, using a native Swift collector and a local JSON feed. Version **0.2.0** targets Apple Silicon and macOS 14 or later; live behavior has been validated on macOS 27.0.1.

The primary probe reads the macOS notification database **read-only**. Each captured message and its deduplication checkpoint are committed together to a separate local SQLite database. An optional Accessibility probe provides separate UI observations. No Discord API token or bot account is required. The default source is Discord only; X/Twitter is not implemented.

## Results

Validation performed on October 9, 2026; aggregate results consolidated October 10.

| Check | Result |
| --- | --- |
| Fixture checks | **58/58 passed** |
| Native app lifecycle checks | **15/15 passed** |
| Live synthetic notifications | **48/48** through both probes, exact delivered text |
| Durable feed | **48 distinct events**, without duplicates |
| Live restart | **5/5** notifications delivered during downtime recovered; previous 48 preserved |
| Actual Discord, hardened build | **6 observed notifications** saved, with matching IDs, titles and bodies across both probes |
| Actual Discord, earlier prototype | **5 observed notifications**, matching titles and bodies |
| Real Discord database delay, hardened build | **5.429–5.598 seconds**, median **5.554 seconds** |

These are observed notification payloads, not proof that every Discord message produces a notification. The first two hardened Discord UI observations took about 0.6 seconds; four later notifications only became observable through AX 21–44 minutes after delivery. The database captured all six promptly. Use the durable database feed for retrieval.

[Validation and lessons](VALIDATION.md) · [Aggregate results](validation/results.json) · [Operations and Mini deployment](docs/OPERATIONS.md)

## Build and run

Download the [0.2.0 Mini package](https://github.com/nathanwang16/notificationlab/releases/tag/v0.2.0) for the frozen arm64 apps and source, or build locally below. The package contains curated results and no captured notification data.

Requirements: Apple Silicon Mac, compatible Xcode or Command Line Tools providing `xcrun swiftc`, and Python 3. The build uses Apple frameworks only and creates ad-hoc signed apps.

```sh
git clone https://github.com/nathanwang16/notificationlab.git
cd notificationlab
zsh scripts/build.sh
open apps/NotificationLabCapture.app
```

Grant **Full Disk Access** to the exact Capture app for the database probe. Grant **Accessibility** only if using the optional UI probe. These are broad OS permissions; the source filter limits logged content, not the OS grant itself. Quit and reopen Capture after granting Full Disk Access. Rebuilding or moving an ad-hoc signed app can require reauthorization.

In Discord's macOS notification settings, enable notifications, choose persistent alerts, set previews to Always and grouping to Off. Discord's own app/channel preferences must also permit the desired notifications. Check capture health:

```sh
python3 scripts/health.py
```

## Retrieve new messages

```sh
python3 scripts/read_events.py --follow --source com.hnc.discord
```

The reader outputs JSON lines with `sequence`, `event_id`, `notification_id`, `source_bundle`, `kind`, `title`, `subtitle`, `body`, `observed_at`, and `delivered_at` when available. `kind` is `posted` or `updated`. Resume with `--after SEQUENCE`. The reader accesses only the collector's own database and needs no additional OS permission.

The first successful scan of a new source seeds existing history. Later starts resume retained notifications, including arrivals during downtime. The feed retains the newest 10,000 events and reports expired nonzero cursors. Distinct IDs stay distinct even when message text is identical. AX observations are kept separately and do not create duplicate feed events.

```sh
python3 scripts/command.py capture stop
python3 scripts/command.py capture start --sources com.hnc.discord
python3 scripts/command.py capture disable_ax
```

## Reproduce tests

```sh
zsh scripts/test.sh
NOTIFICATION_LAB_BUILD_APPS="$PWD/work/staged-apps" zsh scripts/build.sh
python3 scripts/test_lifecycle.py --app work/staged-apps/NotificationLabCapture.app
```

Fixture tests use disposable databases. Lifecycle tests need a local GUI session but disable AX and use a disposable source. The [operations guide](docs/OPERATIONS.md) describes live synthetic tests, Xcode schemes, log retention and the optional per-user login agent.

## Limits

macOS can suppress notifications or omit/truncate source text. This program captures only what macOS receives. In the long Unicode test, a requested 2,211-character body became 1,999 characters before delivery; both probes preserved that delivered body exactly. Database persistence can batch notifications: the synthetic baseline reached 24.852 seconds of delay despite 500 ms polling.

The notification database format is undocumented and AX depends on UI visibility and layout. Changes across macOS versions may require adaptation. Mini login/reboot/crash recovery and a continuous 24–48-hour soak remain unverified. The repository publishes source, synthetic fixtures and aggregate measurements; captured messages, raw reports, app state, logs and local binaries remain untracked.
