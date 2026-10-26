import AppKit

/// The app's implementation of the router's host protocol.
///
/// Every mutation here goes through the same `commitConfig()` path as the UI, so
/// an external call cannot leave the listener, the system proxy, the shell env
/// or the telemetry flusher in a state the UI could not produce. None of these
/// methods call `SessionState.noteUserAction()`: an external caller is never a
/// present user and must never reach an authorization prompt.
extension AppModel: IntegrationHost {
    // MARK: - Snapshot

    func integrationSnapshot() -> IntegrationSnapshot {
        IntegrationSnapshot(
            state: state.rawValue,
            routingIntended: routingIntended,
            tunnelUp: tunnelUp,
            bindHost: config.proxy.bindHost,
            port: config.proxy.port,
            lastError: lastError,
            onboardingComplete: !showOnboarding,
            authorizationDeferred: authorizationDeferred,
            targets: config.targets.map {
                IntegrationTarget(id: $0.id, pattern: $0.pattern, enabled: $0.enabled)
            },
            appsEnabled: config.apps.enabled,
            appsDefaultMode: config.apps.defaultMode,
            appsRecordInTelemetry: config.apps.recordInTelemetry,
            appRules: config.apps.rules.map {
                IntegrationAppRule(id: $0.id, key: $0.key, keyKind: $0.keyKind,
                                   mode: $0.mode, enabled: $0.enabled)
            }
        )
    }

    // MARK: - Routing

    func setRoutingIntent(_ enabled: Bool) {
        setRoutingIntentFromIntegration(enabled)
    }

    func toggleRoutingIntent() {
        switch state {
        case .off: setRoutingIntentFromIntegration(true)
        case .on, .degraded: setRoutingIntentFromIntegration(false)
        case .starting, .stopping: break
        }
    }

    func retryRoutingIntent() {
        retryDeferredFromIntegration()
    }

    // MARK: - Targets

    func addTarget(pattern: String, enabled: Bool) -> (id: UUID, added: Bool) {
        let normalized = RoutingEngine.normalize(pattern)
        if let existing = config.targets.first(where: {
            $0.pattern.lowercased() == normalized
        }) {
            return (existing.id, false)
        }
        let rule = TargetRule(pattern: normalized, enabled: enabled)
        config.targets.append(rule)
        commitConfig()
        return (rule.id, true)
    }

    func removeTargetRule(id: UUID) -> Bool {
        let before = config.targets.count
        config.targets.removeAll { $0.id == id }
        guard config.targets.count != before else { return false }
        commitConfig()
        return true
    }

    func removeTargetRule(pattern: String) -> Bool {
        let key = RoutingEngine.normalize(pattern)
        let before = config.targets.count
        config.targets.removeAll { $0.pattern.lowercased() == key }
        guard config.targets.count != before else { return false }
        commitConfig()
        return true
    }

    func updateTargetRule(id: UUID, pattern: String?, enabled: Bool?) -> Bool {
        guard let index = config.targets.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if let pattern {
            config.targets[index].pattern = RoutingEngine.normalize(pattern)
        }
        if let enabled {
            config.targets[index].enabled = enabled
        }
        commitConfig()
        return true
    }

    func clearTargetRules() {
        guard !config.targets.isEmpty else { return }
        config.targets = []
        commitConfig()
    }

    func applyTargetPreset(idOrName: String) -> Int? {
        guard let preset = TargetPreset.all.first(where: {
            $0.id == idOrName
                || $0.name.caseInsensitiveCompare(idOrName) == .orderedSame
        }) else {
            return nil
        }
        var existing = Set(config.targets.map { $0.pattern.lowercased() })
        var added = 0
        for rule in preset.rules {
            let key = rule.pattern.lowercased()
            guard !existing.contains(key) else { continue }
            config.targets.append(TargetRule(pattern: rule.pattern, enabled: rule.enabled))
            existing.insert(key)
            added += 1
        }
        if added > 0 { commitConfig() }
        return added
    }

    // MARK: - Per-app routing

    func setAppsEnabled(_ enabled: Bool) {
        guard config.apps.enabled != enabled else { return }
        config.apps.enabled = enabled
        commitConfig()
    }

    func setAppsDefaultMode(_ mode: AppRoutingMode) {
        guard config.apps.defaultMode != mode else { return }
        config.apps.defaultMode = mode
        commitConfig()
    }

    func setAppRule(key: String, kind: AppRuleKeyKind,
                    mode: AppRoutingMode, enabled: Bool) -> UUID {
        if let index = config.apps.rules.firstIndex(where: {
            $0.key == key && $0.keyKind == kind
        }) {
            config.apps.rules[index].mode = mode
            config.apps.rules[index].enabled = enabled
            let id = config.apps.rules[index].id
            commitConfig()
            return id
        }
        let rule = AppRule(key: key, keyKind: kind, mode: mode, enabled: enabled)
        config.apps.rules.append(rule)
        commitConfig()
        return rule.id
    }

    func deleteAppRule(id: UUID) -> Bool {
        let before = config.apps.rules.count
        config.apps.rules.removeAll { $0.id == id }
        guard config.apps.rules.count != before else { return false }
        commitConfig()
        return true
    }

    func deleteAppRule(key: String, kind: AppRuleKeyKind) -> Bool {
        let before = config.apps.rules.count
        config.apps.rules.removeAll { $0.key == key && $0.keyKind == kind }
        guard config.apps.rules.count != before else { return false }
        commitConfig()
        return true
    }

    // MARK: - Reads

    func explain(host: String, bundleID: String?) -> IntegrationExplanation {
        let normalized = RoutingEngine.normalize(host)
        let matched = proxyServer.routingEngine.matchingRule(for: normalized)

        var appMode: AppRoutingMode?
        var appKey: String?
        if config.apps.enabled {
            if let bundleID,
               let rule = config.apps.rules.first(where: {
                   $0.enabled && $0.keyKind == .bundle && $0.key == bundleID
               }) {
                appMode = rule.mode
                appKey = rule.key
            } else {
                appMode = config.apps.defaultMode
            }
        }

        let decision: String
        if let appMode {
            switch appMode {
            case .tunnel: decision = "tunnel"
            case .direct: decision = "direct"
            case .targets: decision = matched == nil ? "direct" : "tunnel"
            }
        } else {
            decision = matched == nil ? "direct" : "tunnel"
        }

        return IntegrationExplanation(
            host: normalized,
            decision: decision,
            matchedPattern: matched?.pattern,
            matchedTargetID: matched?.id,
            appMode: appMode?.rawValue,
            appRuleKey: appKey
        )
    }

    func resolveApp(bundleID: String?, path: String?,
                    pid: Int32?) -> IntegrationAppResolution? {
        var resolvedBundle = bundleID
        var executable = path
        var name: String?

        if let pid, let identity = AppResolver().identity(forPid: pid) {
            resolvedBundle = resolvedBundle ?? identity.bundleId
            executable = executable ?? identity.executablePath
            name = identity.displayName
        }
        if let path, let bundle = AppResolver.enclosingBundle(path: path) {
            resolvedBundle = resolvedBundle ?? bundle.bundleId
            name = name ?? bundle.displayName
        }
        if let bundleID,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == bundleID
           }) {
            executable = executable ?? app.executableURL?.path
            name = name ?? app.localizedName
        }

        guard resolvedBundle != nil || executable != nil else { return nil }

        let rule = resolvedBundle.flatMap { bundle in
            config.apps.rules.first {
                $0.enabled && $0.keyKind == .bundle && $0.key == bundle
            }
        }
        let mode: AppRoutingMode = config.apps.enabled
            ? (rule?.mode ?? config.apps.defaultMode)
            : .targets

        return IntegrationAppResolution(
            bundleID: resolvedBundle,
            executablePath: executable,
            displayName: name,
            mode: mode,
            ruleID: rule?.id
        )
    }

    // MARK: - Windows

    func openPane(_ pane: String, section: String?,
                  revealPattern: String?, revealAppRuleID: UUID?) {
        switch pane.lowercased() {
        case "dashboard":
            DashboardWindowController.shared.show()
        case "onboarding":
            replayOnboarding()
        case "about":
            settingsSelection = .about
            openSettings()
        case "settings":
            if let section, let parsed = Self.settingsSection(for: section) {
                settingsSelection = parsed
            }
            openSettings()
        default:
            break
        }

        if let revealAppRuleID {
            revealAppInSettings(revealAppRuleID)
        }
        if let revealPattern {
            let key = RoutingEngine.normalize(revealPattern)
            if let rule = config.targets.first(where: {
                $0.pattern.lowercased() == key
            }) {
                revealTargetInSettings(rule)
            }
        }
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func settingsSection(for slug: String) -> SettingsSection? {
        SettingsSection.allCases.first {
            $0.rawValue.caseInsensitiveCompare(slug) == .orderedSame
        }
    }
}
