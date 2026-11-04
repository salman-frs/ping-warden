# Ping Warden Full Documentation

This document is the detailed technical and operational guide for Ping Warden.

For quick setup, see [Quick Start](QUICKSTART.md). For issue recovery, see [Troubleshooting](TROUBLESHOOTING.md).

## 1. Overview

Ping Warden is a macOS utility that keeps AWDL from reactivating during latency-sensitive work.

AWDL (Apple Wireless Direct Link) is used by Apple ecosystem features such as AirDrop, AirPlay, and Handoff. On some networks and workflows, AWDL interface transitions can correlate with sudden latency jumps. Ping Warden provides a controlled, user-friendly way to keep AWDL suppressed when desired, while retaining the ability to restore the interface when protection stops.

Primary goals:

- Keep AWDL suppressed during latency-sensitive games, cloud streaming, and calls.
- Avoid repeated password prompts for normal day-to-day usage.
- Provide clear observability (status, ping history, interventions).
- Offer safe operational controls (enable/disable/pause/restore).

## 2. Why Not Just Run `sudo ifconfig awdl0 down`?

A one-time shell command might seem like a simple fix, but it doesn't actually solve the problem.

**The core issue:** macOS can bring AWDL back up automatically. A polling script reacts only after the interface is active, so it cannot prevent the transition itself.

**Why Ping Warden is different:** Instead of polling, the helper daemon waits for kernel route and interface events through an `AF_ROUTE` socket. When macOS raises AWDL while protection is active, the helper requests that the interface return down and records an intervention attempt. The count does not establish that the request succeeded or that a particular latency spike was avoided.

Additional benefits:

- **No repeated sudo prompts:** One-time approval during setup, then background operation.
- **Observability:** Live dashboard with ping history, intervention counts, and spike timeline.
- **Proper lifecycle:** Explicit startup, reconnect, health-check, and shutdown behavior.

## 3. High-Level Architecture

Ping Warden uses a split architecture:

- Main app (Swift/SwiftUI + AppKit bridge):
  - UI, settings, dashboard, diagnostics, automation.
- Helper daemon (Objective-C):
  - Privileged AWDL control and low-level monitoring.

Communication boundary:

- XPC service: `com.salmanfrs.pingwarden.xpc`
- Protocol: `PingWardenHelperProtocol` (in `PingWarden/Common/HelperProtocol.h`)

Registration model:

- Helper is registered using `SMAppService.daemon(plistName:)`.
- Registration requires one-time user approval in System Settings.

## 4. Key Components

### 4.1 Main App

Important files:

- `PingWarden/PingWarden/PingWardenApp.swift`
- `PingWarden/PingWarden/PingWardenMonitor.swift`
- `PingWarden/PingWarden/DashboardView.swift`
- `PingWarden/PingWarden/ProtectedSessionCoordinator.swift`
- `PingWarden/PingWarden/PingWardenPreferences.swift`
- `PingWarden/PingWarden/DiagnosticsExporter.swift`

Responsibilities:

- Menu bar app behavior and settings window lifecycle.
- User intent state persistence (`isMonitoringEnabled`).
- Effective runtime state tracking (`effectiveMonitoringEnabled`).
- Dashboard data collection and charting.
- Latency Session lifecycle and local recap history.

### 4.2 Helper Daemon

Important files:

- `PingWarden/PingWardenHelper/main.m`
- `PingWarden/PingWardenHelper/PingWardenMonitor.h`
- `PingWarden/PingWardenHelper/PingWardenMonitor.m`
- `PingWarden/PingWardenHelper/com.salmanfrs.pingwarden.helper.plist`

Responsibilities:

- Monitor interface change events through `AF_ROUTE`.
- Enforce desired AWDL state through `ioctl` on interface flags.
- Count and report interventions.
- Restore AWDL to enabled state when helper exits.

## 5. Monitoring Model and Timing Behavior

Core behavior:

- AWDL blocking mode means: keep `awdl0` down.
- Allow mode means: permit `awdl0` to remain up.
- Helper thread blocks on `poll()` waiting for:
  - Route/interface events (`AF_ROUTE` socket).
  - Internal control messages (`pipe`).

When monitoring is active and the system raises AWDL:

1. Kernel route event arrives.
2. Helper identifies `awdl0` state change (`RTM_IFINFO`).
3. The intervention-attempt counter increments.
4. The helper attempts to clear `IFF_UP` on `awdl0` via `SIOCSIFFLAGS` and reads back the resulting flag state.

This is event-driven, not a delayed periodic shell loop.

## 6. State Model

Two state concepts are used:

- User intent state:
  - Preference for whether monitoring should be enabled.
  - Stored in user defaults.
- Effective runtime state:
  - Actual active status considering helper availability and XPC connectivity.

This separation allows robust behavior during reconnects, restarts, or temporary failures.

## 7. Setup and Approval Flow

Initial setup sequence:

1. Launch app.
2. App checks helper registration status via `SMAppService`.
3. If unregistered or approval required, user is guided to System Settings.
4. App polls registration status and proceeds once enabled.
5. XPC connection is activated.

The design avoids recurring password prompts after the one-time approval step.

The welcome appears automatically once. Dismissing it leaves the free dashboard usable without helper setup; **Settings → General → Finish Setup** and the menu bar protection action both resume the flow later.

## 8. Settings and UI Areas

Settings sections:

- Dashboard
- General
- Targets
- Automation
- Advanced

### 8.1 Dashboard

Provides real-time latency visibility and tuning controls.

Cards include:

- Latency Session:
  - Start and end a measured game or call. Starting a session enables Ping Protection.
  - Review duration, median, p95, jitter, Probe Failures, and interventions.
  - Review router P95 and the share of router pings delayed past 50 ms, and whether delays started on the local network or past the router.
  - Share a privacy-scrubbed text recap.

- Network Quality:
  - Current ping, average, best, worst, jitter, Probe Failures, AWDL state.
- Local Network:
  - ICMP echo to the default gateway every 100 ms, without the helper or any permission, summarized over the last minute: median, P95, and the share delayed past 50 ms or lost.
  - Wi-Fi signal, link rate, band, and channel from CoreWLAN.
  - Advice when the link is weak, on 2.4 GHz, or delaying while Ping Protection is off.
- Last GeForce NOW Stream (shown when the GeForce NOW app is installed):
  - Reads the client's own log (`~/Library/Application Support/NVIDIA/GeForceNOW/geronimo.log` and its backup) after each stream: server zone, video mode, round trip, router spikes, and the Wi-Fi link the client saw.
  - Explains what to fix: a server above NVIDIA's 80 ms recommendation, a Wi-Fi link too slow for the stream's bitrate, local delays, or spikes past the router.
  - Ping This Server switches the dashboard's target to the stream's zone.
  - The log format is NVIDIA's and undocumented. Anything the parser does not recognize is left out of the report.
- Ping History:
  - Timeframe zoom windows: 1 min, 5 min, 15 min, 30 min, 1 hour.
  - Timeframe changes are non-destructive (history is not deleted by zoom changes).
- Latency Timeline:
  - Spike and intervention event list.
- Ping Protection:
  - Intervention counter and explanatory status.
- Ping Target:
  - Shows the current target with a Change… button that opens Settings > Targets.

Data retention behavior:

- Dashboard keeps a rolling history window (approximately one hour plus buffer).
- Chart zoom filters the in-memory history for display only.

### 8.2 General

Controls:

- Ping Protection setup and status.
- Launch at Login.
- Show Dock Icon.
- Show Live Metrics in Menu (current ping and interventions in the menu dropdown; the same toggle appears in the menu itself).

Status block:

- Displays helper registration and effective blocking status.

### 8.3 Automation

Controls:

- Game Mode Auto-Detect: engages when a recognized game is the frontmost app, no permission needed; an optional Enable Fullscreen Detection… button requests Screen Recording to also catch fullscreen games behind other windows. Skipped while the Mac is on Ethernet.
- Control Center Only mode, which removes the menu bar and Dock icons for people who use the Control Center toggle (macOS 26+, signed release builds only). It is saved as `ControlCenterOnlyEnabled`. Version 4.2.1 and earlier offer Hide Menu Bar Icon instead, saved as `ControlCenterWidgetEnabled`, which hides only the menu bar icon and keeps the Dock icon. Later versions keep that saved choice and its behavior until the person picks Control Center Only or shows the menu bar icon again.

### 8.4 Advanced

Tools:

- Test the registered helper and signed XPC connection.
- Open Console logs.
- Create a local diagnostics snapshot and review it before sharing.
- Repair the helper connection without changing the protection preference.
- Prepare for removal by turning off protection, unregistering services, clearing local data, revealing the app, and quitting.

### 8.5 Targets

- Ping target selection, including discovered GeForce NOW zones and the network gateway.
- Find Fastest Target.
- Update interval selection.
- Custom servers (add, edit, remove).

## 9. Menu Bar and App Menu Integration

Menu bar:

- One primary Ping Protection action, plus a contextual 10-minute pause.
- Latency Sessions stay in the dashboard so they are not confused with the persistent protection control.
- Optional live metrics in dropdown.
- Settings and About.
- Help and Documentation opens the project repository. The Help menu and About also link to troubleshooting.

## 10. Security Model

Security controls include:

- Privileged helper exposed only through XPC interface.
- Mandatory code-signing requirements for the app and widget XPC clients.
- Exact Team ID and bundle identifier validation in the helper bootstrap path.
- Unsigned or ad-hoc helper builds fail closed instead of falling back to UID-only access.
- Shared defaults and distributed notifications never authorize privileged changes.
- Bounded error handling and controlled shutdown paths.
- Developer ID signing, Hardened Runtime, notarization, and stapling are release gates.

## 11. Diagnostics and Health Checks

Built-in diagnostics surface:

- Helper registration state.
- XPC reachability.
- Helper version and status calls.
- Current `awdl0` flags snapshot.
- Health check pass/fail messaging.
- Intervention counter and reset support.

Export diagnostics:

- Generates a local support snapshot with owner-only permissions.
- Redacts custom ping targets to a category before writing.
- Shows the contents for review and never uploads the file automatically.

## 12. Performance Characteristics

Design choices for low overhead:

- Event-driven helper thread using `poll()` rather than busy loops.
- One reference-counted telemetry stream shared by dashboard, menu, and sessions.
- Rolling bounded history with statistics calculated off the main thread.
- Five-minute hostname and address caching with cancellable probe deadlines.
- Game Mode uses event-triggered checks plus a safety timer: 2 seconds while a game is detected, 10 seconds otherwise, dropping to 30 seconds after about 90 seconds without a game. App activation and display changes trigger an immediate re-check.
- Narrow command surface over XPC.
- Dashboard sampling rate configurable by user.

## 13. Build and Development

Prerequisites:

- macOS 13+
- Xcode supporting project targets and current SDK requirements

Open in Xcode:

```bash
cd PingWarden
open PingWarden.xcodeproj
```

Build from CLI (example):

```bash
xcodebuild -project PingWarden.xcodeproj -scheme PingWarden -configuration Debug build
```

Key project areas:

- App target: UI and orchestration.
- Helper target: privileged monitoring and control.
- Widget target: optional control-center/menu integration path.

## 14. Release and Distribution

This fork has no release pipeline and no in-app updates. Update by pulling the source and building again.

## 15. Limitations and Tradeoffs

Behavioral tradeoff while blocking AWDL:

- Apple features that depend on AWDL (for example AirDrop/AirPlay/Handoff) may be unavailable until blocking is disabled.

Other practical limits:

- Automation features depend on system permissions, game metadata, and signed-release packaging.
- Game mode detection depends on permissions and app/game behavior.
- Network conditions and endpoint choice still influence baseline latency.

## 16. Operational Best Practices

Recommended usage:

- Start a Latency Session before a latency-sensitive game or call.
- Use dashboard target auto-select periodically if your network path changes.
- Keep update interval moderate unless actively investigating jitter.
- Use diagnostics export before opening support issues.

## 17. Related Documentation

- [Quick Start](QUICKSTART.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Repository Root README](../README.md)
- [Release Notes](../RELEASE_NOTES.md)

## 18. Credits

- [jamestut/awdlkiller](https://github.com/jamestut/awdlkiller)
- [james-howard/AWDLControl](https://github.com/james-howard/AWDLControl), SMAppService and XPC architecture inspiration

## 19. License

MIT, Copyright (c) 2025-2026 Oliver Ames. See the repository [LICENSE](../LICENSE).
