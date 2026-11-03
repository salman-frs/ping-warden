# Quick start

Ping Protection keeps Apple's AWDL network interface (`awdl0`) offline. While it is active, AirDrop, AirPlay, Handoff, and other nearby-device features may be unavailable. You can turn protection off at any time or pause it for 10 minutes from the menu bar.

This guide walks through every step of setup in order. Each step lists what you will see, what to do, and what Ping Warden and macOS are doing in the background. If something on screen does not match, the [Troubleshooting guide](TROUBLESHOOTING.md#messages-you-might-see) is organized by the exact message Ping Warden shows.

On macOS 15 and later the System Settings page is called **Login Items & Extensions**. On macOS 13 and 14 it is called **Login Items**. Ping Warden uses the name that matches your Mac, and this guide uses the newer name.

## Install and verify

### 1. Build Ping Warden

**What to do:** Build the app from source as described in the [README](../README.md#build-from-source), signed with your own team.

### 2. Move it to Applications and open it

**What to do:** Copy Ping Warden to Applications and open it from there. Do not open it from Downloads, Desktop, or Documents.

**Behind the scenes:** Ping Warden's background helper must start from the copy in Applications. If you open the app from Downloads, Desktop, or Documents, setup stops with **Move Ping Warden to Applications** instead of registering a helper that macOS would refuse to start. If macOS cannot verify the copy at all, Ping Warden shows **macOS Could Not Verify Ping Warden**. See [Troubleshooting](TROUBLESHOOTING.md#macos-could-not-verify-ping-warden).

### 3. Read the welcome window

The welcome window opens automatically on the first launch. It is titled **Welcome to Ping Warden** and lists what the app does. You'll see:

- **Turn On Ping Protection** as the main button.
- **Not Now** below it.
- "Setup asks for one approval in Login Items & Extensions."

**What to do:** Click **Turn On Ping Protection** to continue, or choose **Not Now** to use the dashboard and set up protection later.

**Behind the scenes:** Nothing changes on your Mac until you click a setup button. The window opens automatically only once. If you choose **Not Now**, the menu bar shows **Status: Not Set Up**, and the protection item in the menu reads **Finish Setup…**. Choosing it opens the welcome window again.

### 4. Approve the helper

Ping Protection needs a small background helper. This is the only step that needs your approval in System Settings.

**What to do:**

1. Click **Turn On Ping Protection** in the welcome window. You can also click **Finish Setup…** in **Settings → General**, on the Dashboard, or in the menu bar menu.
2. The welcome window changes to "Waiting for approval" and says: "In System Settings, allow Ping Warden under Login Items & Extensions, then return here."
3. macOS shows a **Background Items Added** notification. If approval is still pending after about 10 seconds, Ping Warden opens **System Settings → General → Login Items & Extensions** for you. You can also click **Open Login Items & Extensions** in the welcome window.
4. Under **Allow in the Background**, turn on **Ping Warden**.
5. macOS may ask for an administrator password or Touch ID. That prompt comes from macOS, not from Ping Warden.
6. Return to Ping Warden.

<!-- Screenshot: ![The Welcome window in the Waiting for approval state, with the Open Login Items and Extensions button](../docs/images/setup-welcome-waiting.png) -->

<!-- Screenshot: ![The macOS Background Items Added notification for Ping Warden](../docs/images/setup-background-items-notification.png) -->

<!-- Screenshot: ![System Settings, General, Login Items and Extensions, with Ping Warden turned on under Allow in the Background](../docs/images/setup-login-items-allow.png) -->

Finish the approval within about a minute. If you take longer, Ping Warden shows **Helper Approval Timed Out** and the welcome window shows "Setup did not finish". Click **Try Again**. See [Troubleshooting](TROUBLESHOOTING.md#helper-approval-timed-out).

**Behind the scenes:** Ping Warden asks macOS to register its helper with Apple's `SMAppService` service, which is why macOS announces a new background item. Approval lets macOS start the helper when the app asks for it. Ping Warden then waits for the helper to answer before it reports that setup worked.

#### What the helper is and why it needs approval

The helper, `PingWardenHelper`, ships inside the Ping Warden app. macOS runs it as a system background item with administrator-level rights, because only a privileged process can take a network interface down. Ping Warden itself never runs with those rights.

The helper does one job: it keeps the `awdl0` interface down while Ping Protection is on.

- It reads and sets the up or down state of `awdl0` only.
- It counts its attempts to lower `awdl0` and reports its version and status to the app.
- It accepts requests only from the Ping Warden app and its Control Center control, signed by the same developer.
- It starts when the app asks for it. After the app disconnects, it stops blocking, brings `awdl0` back up if it was the one that lowered it, and exits.

The helper never:

- Touches Wi-Fi, Ethernet, or any interface other than `awdl0`.
- Reads, records, or sends your network traffic.
- Connects to the internet.
- Asks for your password. The only password prompt comes from macOS during approval.

You can turn the helper off at any time under **Allow in the Background** in **Login Items & Extensions**. Protection stops, and Ping Warden shows **Status: Not Set Up** until you approve it again. To remove it completely, use **Prepare to Remove**, described in [Uninstall Ping Warden](TROUBLESHOOTING.md#uninstall-ping-warden).

### 5. Confirm that Ping Protection is on

<!-- Screenshot: ![The Welcome window showing Setup complete. Ping Protection is on, with the Open Dashboard button](../docs/images/setup-welcome-complete.png) -->

**What you'll see:**

- The welcome window shows "Setup complete. Ping Protection is on." and an **Open Dashboard** button.

**What to do:** Check any of these.

- **Menu bar icon:** The antenna icon gains a slash while protection is on. Hovering over it shows "Ping Protection: Active".
- **Menu:** The first line reads **Status: Protected**. The protection item reads **Turn Off Ping Protection**, and **Pause for 10 Minutes** appears below it.
- **Dashboard:** The **Ping Protection** card shows a **Turn Off** button and "Ping Protection is active."
- **Settings → General:** **Status** reads **Protected** with a green dot.

<!-- Screenshot: ![The Ping Warden menu open, showing Status: Protected, Turn Off Ping Protection, and Pause for 10 Minutes](../docs/images/setup-menu-protected.png) -->

<!-- Screenshot: ![The Dashboard Ping Protection card with the Turn Off button and the intervention attempt counter](../docs/images/setup-dashboard-protected.png) -->

For a full helper check, open **Settings → Advanced** and click **Run Test** under **Test Helper Connection**. A working helper reports **Helper Is Working**, with its version and "Ping Protection is on." Any other result is covered in [Troubleshooting](TROUBLESHOOTING.md#messages-you-might-see).

**Behind the scenes:** The menu, Dashboard, and Settings all read the state the helper reports, not just the setting you chose. The intervention counter records the helper's attempts to lower AWDL after macOS raises it again. It does not measure confirmed blocks or spikes prevented. Leave the Dashboard open during a normal game or call to compare latency, jitter, and probe failures.

## Automatic protection for games

1. Open **Settings → Automation**.
2. Turn on **Game Mode Auto-Detect**. No permission is needed.
3. Optional: click **Enable Fullscreen Detection…** and allow Screen Recording if you also want fullscreen games behind other windows caught.

**Behind the scenes:** Game Mode turns protection on and records a Latency Session while a recognized game is the frontmost app. The menu shows **Status: Protected, Game Mode Session Active**. Once no game is detected through either the frontmost or the optional fullscreen path, it restores your previous protection state. Game Mode skips automatic activation on Ethernet. It does not turn off protection that you enabled yourself. Some games do not declare the metadata macOS uses for Game Mode; use the menu bar toggle for those titles.

Screen Recording only lets Ping Warden read window metadata to notice a fullscreen game. Ping Warden never captures or saves screen contents.

## Control Center widget

The Control Center widget requires [macOS Tahoe 26](https://support.apple.com/en-us/122868) or newer and a signed build.

1. Click **Control Center** in the menu bar, then click **Edit Controls**.
2. Find **Ping Protection** and add it. To pin it to the menu bar, drag it there while you edit.
3. Optional: open **Settings → General** (**Settings → Automation** in 4.3.0) and turn on **Control Center Only**. Ping Warden asks "Use Control Center Only?" Click **Use Control Center Only**, and the toggle replaces Ping Warden's menu bar and Dock icons. Open Ping Warden from Applications or Spotlight to return to Settings. Version 4.2.1 and earlier offer **Hide Menu Bar Icon** instead, which keeps the Dock icon.

<!-- Screenshot: ![Control Center in edit mode with the Ping Protection control added](../docs/images/setup-control-center.png) -->

The control uses the same helper, so it needs the approval from step 4. If **Control Center Only** shows **Unavailable**, the footer below it explains why. See [The Control Center widget does not appear](TROUBLESHOOTING.md#the-control-center-widget-does-not-appear).

## Everyday controls

- Choose **Pause for 10 Minutes** from the menu bar when you need AirDrop, AirPlay, or Handoff briefly. The menu shows **Status: Paused** and offers **Resume Ping Protection**. After 10 minutes, protection returns to your saved choice. Pausing ends a running Latency Session. A Game Mode session starts again after the pause if the game is still running, but a Latency Session you started yourself stays ended.
- Choose **Turn Off Ping Protection** to restore those features until you turn protection on again.
- Start a **Latency Session** from the dashboard when you want a beginning-to-end recap for one game or call. Starting a session enables Ping Protection.
- Turn on **Launch at Login** under **Settings → General** if you want protection available after every restart.
- Use **Settings → Advanced → Diagnostics Snapshot** to create a local troubleshooting file you can review before sharing.

## Get help

- Read the [Troubleshooting guide](TROUBLESHOOTING.md).
- Read the [full documentation](README.md).
