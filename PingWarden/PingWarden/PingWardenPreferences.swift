//
//  PingWardenPreferences.swift
//  PingWarden
//
//  Manages shared state between app and widget using App Groups.
//
//  Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.salmanfrs.pingwarden", category: "Preferences")

/// Manages shared state between app and widget using App Groups
final class PingWardenPreferences: @unchecked Sendable {
    static let shared = PingWardenPreferences()

    private let monitoringEnabledKey = "AWDLMonitoringEnabled" // User intent
    private let effectiveMonitoringEnabledKey = "AWDLEffectiveMonitoringEnabled" // Runtime state
    private let protectionPauseUntilKey = "ProtectionPauseUntil" // Epoch seconds of an active pause, absent when none
    private let lastStateKey = "AWDLLastState"
    /// Hide Menu Bar Icon in 4.2.1 and earlier. Its meaning never changes:
    /// true hides only the menu bar icon and keeps the Dock icon.
    private let controlCenterEnabledKey = "ControlCenterWidgetEnabled"
    private let controlCenterOnlyKey = InterfaceVisibilityPolicy.controlCenterOnlyPreferenceKey
    private let gameModeAutoDetectKey = "GameModeAutoDetect"
    private let showDockIconKey = "ShowDockIcon"
    private let showMenuDropdownMetricsKey = "ShowMenuDropdownMetrics"
    private let completedSessionCountKey = "CompletedProtectedSessionCount"
    private let lifetimeInterventionCountKey = "LifetimeInterventionCount"

    /// Shared App Group defaults handle, exposed so non-singleton consumers
    /// (CustomPingTargetStore, tests, future widget targets) can re-use the
    /// same suite without duplicating the suite name.
    let defaults: UserDefaults

    /// The App Group from this build's signed entitlements. The entitlements
    /// prefix it with the signing team, so it is nil in an unsigned build.
    static let appGroupID: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ) as? [String] else { return nil }
        return groups.first
    }()

    private init() {
        if let groupID = Self.appGroupID, let suite = UserDefaults(suiteName: groupID) {
            log.debug("Successfully connected to App Group suite")
            defaults = suite
        } else {
            log.error("Failed to create App Group suite, using standard defaults")
            defaults = UserDefaults.standard
        }
    }

    /// User intent for whether AWDL monitoring should be enabled.
    /// This is shared with the widget.
    var isMonitoringEnabled: Bool {
        get { defaults.bool(forKey: monitoringEnabledKey) }
        set {
            defaults.set(newValue, forKey: monitoringEnabledKey)
            DistributedNotificationCenter.default().postNotificationName(
                .awdlMonitoringStateChanged,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            ControlCenterSupport.reloadPingProtectionControl()
        }
    }

    /// Effective runtime state of monitoring as reported by the app/helper.
    /// This value is used for accurate status display and should not be used as user intent.
    var effectiveMonitoringEnabled: Bool {
        get { defaults.bool(forKey: effectiveMonitoringEnabledKey) }
        set {
            defaults.set(newValue, forKey: effectiveMonitoringEnabledKey)
            DistributedNotificationCenter.default().postNotificationName(
                .awdlEffectiveMonitoringStateChanged,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            NotificationCenter.default.post(name: .awdlMonitorStateChanged, object: nil)
            ControlCenterSupport.reloadPingProtectionControl()
        }
    }

    /// Last known AWDL state (for widget display)
    var lastKnownState: String {
        get { defaults.string(forKey: lastStateKey) ?? "unknown" }
        set { defaults.set(newValue, forKey: lastStateKey) }
    }

    /// Expiration time of an active protection pause, persisted so the pause
    /// survives an app relaunch or crash. `nil` means no pause is stored.
    var protectionPauseUntil: Date? {
        get {
            let timestamp = defaults.double(forKey: protectionPauseUntilKey)
            guard timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: protectionPauseUntilKey)
            } else {
                defaults.removeObject(forKey: protectionPauseUntilKey)
            }
        }
    }

    /// Hide Menu Bar Icon from 4.2.1 and earlier (hides only the menu bar
    /// icon). New choices go through `enableControlCenterOnly()` and
    /// `showMenuBarIcon()`; read `interfaceVisibilityMode` for the result.
    var controlCenterWidgetEnabled: Bool {
        get { defaults.bool(forKey: controlCenterEnabledKey) }
        set {
            defaults.set(newValue, forKey: controlCenterEnabledKey)
            NotificationCenter.default.post(name: .controlCenterModeChanged, object: nil)
        }
    }

    /// Control Center Only: no menu bar or Dock icon.
    var controlCenterOnlyEnabled: Bool {
        defaults.bool(forKey: controlCenterOnlyKey)
    }

    /// The icons the saved preferences ask for, before checking whether the
    /// Control Center control can be used on this Mac.
    var interfaceVisibilityMode: InterfaceVisibilityMode {
        InterfaceVisibilityPolicy.mode(
            controlCenterOnlySaved: controlCenterOnlyEnabled,
            legacyHideMenuBarIconSaved: controlCenterWidgetEnabled
        )
    }

    /// Turns on Control Center Only. The legacy value is left as it is, so a
    /// downgrade to 4.2.1 falls back to whatever the person chose there.
    func enableControlCenterOnly() {
        defaults.set(true, forKey: controlCenterOnlyKey)
        NotificationCenter.default.post(name: .controlCenterModeChanged, object: nil)
    }

    /// Shows the menu bar icon again, from either icon-hiding mode. Runs only
    /// when the person asks for the icon back, and writes only the keys that
    /// are currently on.
    func showMenuBarIcon() {
        if defaults.bool(forKey: controlCenterOnlyKey) {
            defaults.set(false, forKey: controlCenterOnlyKey)
        }
        if defaults.bool(forKey: controlCenterEnabledKey) {
            defaults.set(false, forKey: controlCenterEnabledKey)
        }
        NotificationCenter.default.post(name: .controlCenterModeChanged, object: nil)
    }

    /// Whether to auto-enable AWDL blocking when Game Mode is active
    var gameModeAutoDetect: Bool {
        get { defaults.bool(forKey: gameModeAutoDetectKey) }
        set {
            defaults.set(newValue, forKey: gameModeAutoDetectKey)
            NotificationCenter.default.post(name: .gameModeAutoDetectChanged, object: nil)
        }
    }

    /// Whether to show the app icon in the Dock
    var showDockIcon: Bool {
        get { defaults.bool(forKey: showDockIconKey) }
        set {
            defaults.set(newValue, forKey: showDockIconKey)
            NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: nil)
        }
    }

    /// Whether to show live ping and intervention metrics in the menu bar dropdown
    var showMenuDropdownMetrics: Bool {
        get { defaults.bool(forKey: showMenuDropdownMetricsKey) }
        set {
            defaults.set(newValue, forKey: showMenuDropdownMetricsKey)
            NotificationCenter.default.post(name: .menuDropdownMetricsChanged, object: nil)
        }
    }

    var completedProtectedSessionCount: Int {
        get { max(0, defaults.integer(forKey: completedSessionCountKey)) }
        set { defaults.set(max(0, newValue), forKey: completedSessionCountKey) }
    }

    var lifetimeInterventionCount: Int {
        get { max(0, defaults.integer(forKey: lifetimeInterventionCountKey)) }
        set { defaults.set(max(0, newValue), forKey: lifetimeInterventionCountKey) }
    }

    /// Remove every value owned by the shared app-group suite. This is used
    /// only after Ping Protection is confirmed off and the helper has been
    /// unregistered, so a partial removal cannot strand privileged state.
    func resetForRemoval() {
        if let groupID = Self.appGroupID {
            defaults.removePersistentDomain(forName: groupID)
        }
    }
}

extension Notification.Name {
    // Use namespaced notification names to avoid collisions with other apps
    static let awdlMonitoringStateChanged = Notification.Name("com.salmanfrs.pingwarden.notification.MonitoringStateChanged")
    static let awdlEffectiveMonitoringStateChanged = Notification.Name("com.salmanfrs.pingwarden.notification.EffectiveMonitoringStateChanged")
    static let awdlMonitorStateChanged = Notification.Name("com.salmanfrs.pingwarden.notification.MonitorStateChanged")
    static let controlCenterModeChanged = Notification.Name("com.salmanfrs.pingwarden.notification.ControlCenterModeChanged")
    static let gameModeAutoDetectChanged = Notification.Name("com.salmanfrs.pingwarden.notification.GameModeAutoDetectChanged")
    static let dockIconVisibilityChanged = Notification.Name("com.salmanfrs.pingwarden.notification.DockIconVisibilityChanged")
    static let menuDropdownMetricsChanged = Notification.Name("com.salmanfrs.pingwarden.notification.MenuDropdownMetricsChanged")
}
