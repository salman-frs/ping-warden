<p align="center">
  <img src="PingWarden/PingWarden/AppIcon.icon/Assets/network-error-svgrepo-com.svg" width="80" height="80" alt="Ping Warden">
</p>

<h1 align="center">Ping Warden (personal build)</h1>

<p align="center">
  <strong>Keep AWDL paused while you play, with latency readings you can inspect.</strong>
</p>

<p align="center">
  <code>event-driven protection</code> &bull;
  <code>macOS 13+</code> &bull;
  <code>no license gate</code> &bull;
  <code>no telemetry</code>
</p>

---

This is a personal fork of [Ping Warden](https://github.com/oliverames/ping-warden) by Oliver Ames. It keeps the original app, its interface, and every feature, with these differences:

- **Ping Protection is free.** The Gumroad license check, the existing-user transition, and every purchase prompt are removed. Protection, Latency Sessions, Game Mode, the pause, and the Control Center toggle all work without a key.
- **Nothing is sent to the original developer.** Sentry crash and error reporting is removed, along with its settings toggle.
- **No automatic updates.** Sparkle is removed, so the app never fetches the upstream appcast or installs an upstream (licensed) build over this one. Update by pulling and rebuilding.

Ping Warden watches Apple Wireless Direct Link (AWDL), the interface used by AirDrop, AirPlay, Handoff, and other nearby-device features, and keeps it down while protection is on. The dashboard shows latency, jitter, and probe history so you can judge the effect on your own network.

## The tradeoff

Ping Protection makes AirDrop, AirPlay, Handoff, and other AWDL-dependent features unavailable while it is on. Turn it off when you need them, or use the 10-minute pause from the menu bar. Ping Warden restores AWDL when protection stops, when the app quits, and during its removal flow.

## How it works

A privileged helper waits for kernel route and interface events. When macOS raises `awdl0` while Ping Protection is on, the helper lowers it again and increments an intervention counter. That count records attempts, not measured spikes prevented. The helper only switches `awdl0` off and on, accepts requests only from this app and its widget, and never connects to the internet.

## What it includes

| Feature | What it does |
|---------|--------------|
| Ping Protection | Keeps `awdl0` down with an event-driven privileged helper |
| Live dashboard | Tracks latency, jitter, probe failures, history, and helper interventions |
| Latency Sessions | Protects a game or call and records a recap of it |
| Game Mode auto-detect | Turns protection on when a recognized game is frontmost; optional Screen Recording access also catches fullscreen games |
| Quick pause | Restores nearby-device features for 10 minutes |
| Control Center toggle | Turns protection on or off from Control Center on macOS 26 or newer |
| Diagnostics export | Creates a local support snapshot you can review before sharing |

## Privacy

Latency history, protection state, settings, and intervention counts stay on your Mac. The app makes only these outbound connections:

- TCP latency probes to the ping target you select or let Ping Warden choose.
- A request to `status.geforcenow.com` to discover GeForce NOW target hostnames.

Diagnostics exports are written locally and never uploaded.

## Build from source

```bash
git clone https://github.com/salman-frs/ping-warden.git
cd ping-warden
open PingWarden/PingWarden.xcodeproj
```

Building needs Xcode. The helper only accepts a signature from the Team ID compiled into it, so before building you must sign the app, helper, and widget targets with your own team and replace the upstream Team ID (`PV3W52NDZ3`) and bundle identifiers (`com.salmanfrs.pingwarden*`). The helper-registration flow only works when the built app is installed in `/Applications`.

Tests that run without Xcode:

```bash
bash scripts/test_helper.sh
python3 scripts/test_monitor.py
python3 scripts/test_coordinator.py
python3 scripts/test_presentation.py --repo .
```

`swift test` runs the Foundation-based core suite and needs Xcode's XCTest.

## Documentation

- [Quick Start](PingWarden/QUICKSTART.md) covers setup.
- [Full documentation](PingWarden/README.md) explains the architecture, settings, and operating model.
- [Troubleshooting](PingWarden/TROUBLESHOOTING.md) provides safe recovery steps and diagnostic commands.

## Credits

- [Ping Warden](https://github.com/oliverames/ping-warden) by Oliver Ames is the app this fork is built from.
- [jamestut/awdlkiller](https://github.com/jamestut/awdlkiller) provided inspiration for the approach to AWDL control.
- [james-howard/AWDLControl](https://github.com/james-howard/AWDLControl) provided a reference for the SMAppService and XPC architecture.

## License

MIT, Copyright (c) 2025-2026 Oliver Ames. See [LICENSE](LICENSE).
