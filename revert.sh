#!/bin/bash
# ProxyManager — emergency revert.
#
# Puts the machine back the way it was before Proxy Manager touched it:
#
#   1. Unloads the crash watchdog LaunchAgent (so it cannot re-arm or race us).
#   2. Restores the user's saved originals from system-proxy-snapshot.json
#      (HTTP/HTTPS server + port + enabled + auth flag, PAC URL/state, auto
#      proxy discovery, bypass domains) on every service in the snapshot.
#      When no snapshot exists it resets every current service to a direct
#      connection (HTTP/HTTPS off) instead — unless a previous run already
#      restored the originals, which is recorded in
#      system-proxy-snapshot.restored (timestamp + service count). That marker
#      makes re-running safe: a later run leaves the restored proxy untouched.
#      `--reset-to-direct` explicitly asks for a direct connection instead;
#      it clears the proxy and, on success, removes both the marker and any
#      recovery snapshot.
#   3. Stops the app and the managed `ssh -N -D` tunnel (ssh.pid: pid + kernel
#      start time must both match, so a reused PID is never killed), and sweeps
#      stale askpass temp dirs.
#   4. Removes the shell rc block + env.sh, restores the GUI-session env from
#      gui-env-snapshot.json (or unsets our vars), and clears the "routing was
#      on" flag.
#
# The proxy snapshot is deleted ONLY after a restore that actually succeeded;
# the restore marker is written BEFORE it is deleted, so an interrupted run can
# never make the next run fall back to "reset to direct" and wipe the originals.
# On failure the snapshot stays on disk: fix the error above, then re-run this
# script or relaunch Proxy Manager, which restores from the same snapshot.
#
# Safe to run repeatedly: with a snapshot it restores the originals once, with
# only the marker it changes no proxy setting, and with neither (first-ever run)
# it resets to direct. Usage: ./revert.sh [--reset-to-direct]
#
# Test seams (production defaults shown). Tests/RevertHarness/run.sh points all
# of these at fakes and a temp HOME, so no real system state is ever touched:
#   NETWORKSETUP, LAUNCHCTL, DEFAULTS, PKILL, PS, OSASCRIPT,
#   PROXYMANAGER_SUPPORT_DIR, TMPDIR, SKIP_APP_KILL=1.
set -u

NETWORKSETUP="${NETWORKSETUP:-/usr/sbin/networksetup}"
LAUNCHCTL="${LAUNCHCTL:-/bin/launchctl}"
DEFAULTS="${DEFAULTS:-/usr/bin/defaults}"
PKILL="${PKILL:-/usr/bin/pkill}"
PS="${PS:-/bin/ps}"
OSASCRIPT="${OSASCRIPT:-/usr/bin/osascript}"
SUPPORT_DIR="${PROXYMANAGER_SUPPORT_DIR:-$HOME/Library/Application Support/ProxyManager}"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
SKIP_APP_KILL="${SKIP_APP_KILL:-0}"

SNAPSHOT="$SUPPORT_DIR/system-proxy-snapshot.json"
MARKER="$SUPPORT_DIR/system-proxy-snapshot.restored"
CONFIG="$SUPPORT_DIR/config.json"
SSH_PID_FILE="$SUPPORT_DIR/ssh.pid"
GUI_ENV_SNAPSHOT="$SUPPORT_DIR/gui-env-snapshot.json"
WATCHDOG_LABEL="com.proxymanager.watchdog"
CONTROL_AGENT_LABEL="com.proxymanager.control-agent"
CONTROL_SOCKET="$SUPPORT_DIR/control.sock"
CONTROL_TOKEN="$SUPPORT_DIR/control.token"
INTEGRATION_PERMISSIONS="$SUPPORT_DIR/integration-permissions.json"
BUNDLE_ID="com.proxymanager.app"
GUI_ENV_KEYS="HTTP_PROXY HTTPS_PROXY ALL_PROXY WSS_PROXY NO_PROXY PROXY_MANAGER_ACTIVE"

FAILED=0          # a step did not complete: exit non-zero
RESTORE_FAILED=0  # the snapshot exists but could not be applied
RESET_TO_DIRECT=0 # --reset-to-direct: clear the proxy instead of restoring
PROXY_ACTION="none"

usage() {
    cat <<EOF
Usage: $0 [--reset-to-direct]

Without arguments this restores the original proxy settings saved in
$SNAPSHOT. After a successful restore the originals are recorded in
$MARKER so running the script again does not touch the proxy.

  --reset-to-direct   ignore the saved originals: clear the HTTP/HTTPS proxy on
                      every network service and, on success, remove both the
                      restore marker and any recovery snapshot.
  -h, --help          show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --reset-to-direct) RESET_TO_DIRECT=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf 'Unknown argument: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done


say()  { echo "  • $*"; }
warn() { echo "⚠️  $*" >&2; }
fail() { FAILED=1; echo "✗ $*" >&2; }

# Trims leading/trailing whitespace without spawning a process.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# True when a networksetup failure means "that service no longer exists"
# (deleted/renamed USB, dock or VPN service). networksetup exits 8 and prints
# "** Error: Unable to find item in network database.".
is_missing_service() {
    local code="$1" text="$2"
    [ "$code" -eq 8 ] && return 0
    printf '%s' "$text" | grep -qi 'unable to find item in network database'
}

# ── 0. Crash watchdog ────────────────────────────────────────────────────────
unload_watchdog() {
    if "$LAUNCHCTL" bootout "gui/$(id -u)/$WATCHDOG_LABEL" 2>/dev/null; then
        say "crash watchdog unloaded"
    else
        say "crash watchdog not loaded"
    fi
    rm -f "$HOME/Library/LaunchAgents/$WATCHDOG_LABEL.plist"
    rm -f "$SUPPORT_DIR/watchdog.json"
}

# ── 0b. External control ─────────────────────────────────────────────────────
# Registered with SMAppService.agent. bootout stops the running instance;
# removing the socket, token and approvals makes the API unreachable even if
# launchd still knows the on-demand service. The app itself unregisters the
# agent when the Settings switch is turned off.
unload_control_agent() {
    if "$LAUNCHCTL" bootout "gui/$(id -u)/$CONTROL_AGENT_LABEL" 2>/dev/null; then
        say "control agent unloaded"
    else
        say "control agent not loaded"
    fi
    rm -f "$CONTROL_SOCKET" "$CONTROL_TOKEN" "$INTEGRATION_PERMISSIONS"
}

# ── 1a. Restore the saved originals (snapshot exists) ────────────────────────
#
# The snapshot is JSON written by the app ([service: proxy state]). JXA reads
# it and shells out to networksetup with every value single-quoted — snapshot
# values are data, never evaluated. Mirrors NetworksetupCommands.restore():
# auth flags and enabled states are restored as captured, PAC is only enabled
# for a valid http(s) URL, auto-discovery is always set, and an empty bypass
# list is cleared with the documented `Empty` argument.
#
# Exit codes: 0 restored (or nothing to restore) and the marker was written,
# 1 real failure (caller keeps the snapshot), 2 unreadable/invalid snapshot
# (caller also keeps it), 3 the proxy was restored but the marker could not be
# written (caller keeps the snapshot so a re-run restores again).
restore_saved_proxy() {
    "$OSASCRIPT" -l JavaScript - "$SNAPSHOT" "$NETWORKSETUP" "$MARKER" <<'JXA'
ObjC.import('Foundation');
ObjC.import('stdlib');

function shq(v) {
    return "'" + String(v).replace(/'/g, "'\\''") + "'";
}

function trim(s) {
    return String(s).replace(/^\s+|\s+$/g, '');
}

// doShellScript runs `sh -c` but throws away the exit status (its error
// message is stderr). Print the status from inside the shell so exit 8
// ("service no longer exists") can be told apart from a real failure.
function runCommand(app, args) {
    var line = args.map(shq).join(' ');
    var text;
    try {
        text = app.doShellScript(line + ' 2>&1; printf "\\n__PM_EXIT__%d" $?');
    } catch (e) {
        return { code: 127, out: trim(e.message) };
    }
    var m = /__PM_EXIT__([0-9]+)\s*$/.exec(text);
    if (!m) { return { code: 127, out: trim(text) }; }
    return { code: parseInt(m[1], 10), out: trim(text.slice(0, m.index)) };
}

function isMissingService(r) {
    return r.code === 8 || r.out.toLowerCase().indexOf('unable to find item in network database') >= 0;
}

function truthy(v) {
    return v === true || v === 1 || v === '1' || v === 'true';
}

function str(v) {
    return (v === undefined || v === null) ? '' : String(v);
}

function validPort(p) {
    if (!/^[0-9]+$/.test(p)) { return false; }
    var n = parseInt(p, 10);
    return n >= 1 && n <= 65535;
}

function isHTTPURL(s) {
    return /^https?:\/\/.+/i.test(s);
}

// `-getautoproxyurl` reports `(null)` when no PAC is set; the app normalizes
// that before saving, but tolerate it anyway (old snapshots).
function normalizePAC(raw) {
    var t = trim(raw);
    if (t === '' || t === '(null)' || t === '(nil)' || t.toLowerCase() === 'null') { return ''; }
    return t;
}

function bypassList(state) {
    if (!Array.isArray(state.bypassDomains)) { return []; }
    return state.bypassDomains.map(function (d) { return trim(d); })
        .filter(function (d) { return d !== ''; });
}

function commandsFor(svc, state) {
    var cmds = [];
    var webServer = str(state.webServer), webPort = str(state.webPort);
    var secureServer = str(state.secureServer), securePort = str(state.securePort);

    if (webServer !== '' && validPort(webPort)) {
        cmds.push(['-setwebproxy', svc, webServer, webPort, truthy(state.webAuthenticated) ? 'on' : 'off']);
        cmds.push(['-setwebproxystate', svc, truthy(state.webEnabled) ? 'on' : 'off']);
    } else {
        cmds.push(['-setwebproxystate', svc, 'off']);
    }
    if (secureServer !== '' && validPort(securePort)) {
        cmds.push(['-setsecurewebproxy', svc, secureServer, securePort, truthy(state.secureAuthenticated) ? 'on' : 'off']);
        cmds.push(['-setsecurewebproxystate', svc, truthy(state.secureEnabled) ? 'on' : 'off']);
    } else {
        cmds.push(['-setsecurewebproxystate', svc, 'off']);
    }

    // -setautoproxyurl also enables PAC, so only emit it for a real URL and
    // never leave PAC on without one; the explicit state command wins.
    var pacURL = normalizePAC(str(state.pacURL));
    var pacValid = pacURL !== '' && isHTTPURL(pacURL);
    if (pacValid) { cmds.push(['-setautoproxyurl', svc, pacURL]); }
    cmds.push(['-setautoproxystate', svc, (truthy(state.pacEnabled) && pacValid) ? 'on' : 'off']);
    cmds.push(['-setproxyautodiscovery', svc, truthy(state.autoDiscoveryEnabled) ? 'on' : 'off']);

    // Always restore the bypass list; `man networksetup` documents `Empty` as
    // the way to clear all entries (leaving the app's list would break the
    // user's direct traffic).
    var bypass = bypassList(state);
    cmds.push(['-setproxybypassdomains', svc].concat(bypass.length > 0 ? bypass : ['Empty']));
    return cmds;
}

function describe(state) {
    var parts = [];
    var ws = str(state.webServer);
    if (ws !== '' && validPort(str(state.webPort))) {
        parts.push('HTTP ' + ws + ':' + str(state.webPort) + ' ' + (truthy(state.webEnabled) ? 'on' : 'off'));
    }
    var ss = str(state.secureServer);
    if (ss !== '' && validPort(str(state.securePort))) {
        parts.push('HTTPS ' + ss + ':' + str(state.securePort) + ' ' + (truthy(state.secureEnabled) ? 'on' : 'off'));
    }
    var pac = normalizePAC(str(state.pacURL));
    if (pac !== '' && isHTTPURL(pac)) {
        parts.push('PAC ' + pac + ' ' + (truthy(state.pacEnabled) ? 'on' : 'off'));
    }
    if (truthy(state.autoDiscoveryEnabled)) { parts.push('auto-discovery on'); }
    var bypass = bypassList(state);
    if (bypass.length > 0) { parts.push('bypass ' + bypass.join(',')); }
    return parts.length > 0 ? ' (' + parts.join('; ') + ')' : '';
}

// The restore marker is written before the caller deletes the snapshot. A
// later run with the marker and no snapshot must not fall back to "reset to
// direct" (that would wipe the originals we just restored).
function writeMarker(path, serviceCount) {
    var body = 'restored_at=' + (new Date()).toISOString() + '\nservices=' + serviceCount + '\n';
    return $.NSString.alloc.initWithUTF8String(body)
        .writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}

function run(argv) {
    var snapshotPath = argv[0];
    var networksetup = argv[1];
    var markerPath = argv[2];
    var app = Application.currentApplication();
    app.includeStandardAdditions = true;

    var raw = $.NSString.stringWithContentsOfFileEncodingError(snapshotPath, $.NSUTF8StringEncoding, null);
    if (!raw || raw.isNil()) {
        console.log('cannot read ' + snapshotPath);
        $.exit(2);
    }
    var snapshot;
    try {
        snapshot = JSON.parse(raw.js);
    } catch (e) {
        console.log(snapshotPath + ' is not valid JSON: ' + e);
        $.exit(2);
    }
    if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
        console.log(snapshotPath + ' does not contain a service map');
        $.exit(2);
    }

    var services = Object.keys(snapshot).sort();
    if (services.length === 0) {
        if (!writeMarker(markerPath, 0)) {
            console.log('✗ could not write ' + markerPath);
            $.exit(3);
        }
        console.log('snapshot holds no services; nothing to restore');
        $.exit(0);
    }

    var failures = [];
    var skipped = [];
    var restored = 0;

    services.forEach(function (svc) {
        var state = snapshot[svc];
        if (!state || typeof state !== 'object' || Array.isArray(state)) {
            failures.push(svc + ': snapshot entry is not an object');
            return;
        }
        var cmds = commandsFor(svc, state);
        for (var i = 0; i < cmds.length; i++) {
            var r = runCommand(app, [networksetup].concat(cmds[i]));
            if (r.code === 0) { continue; }
            if (isMissingService(r)) {
                skipped.push(svc);
                return;
            }
            failures.push(svc + ': ' + cmds[i].join(' ') + ' → ' + (r.out || ('exit ' + r.code)));
            return;
        }
        restored += 1;
        console.log('  • restored ' + svc + describe(state));
    });

    if (skipped.length > 0) {
        console.log('  • skipped network service(s) that no longer exist: ' + skipped.join(', '));
    }
    if (failures.length > 0) {
        console.log('✗ the saved proxy settings could not be restored:');
        failures.forEach(function (f) { console.log('    ' + f); });
        $.exit(1);
    }
    if (!writeMarker(markerPath, restored)) {
        console.log('✗ restored the proxy but could not write ' + markerPath);
        $.exit(3);
    }
    console.log('  • restored the saved proxy settings on ' + restored + ' service(s)');
    $.exit(0);
}
JXA
}

# ── 1b. No snapshot: reset every current service to direct ───────────────────
#
# `-listallnetworkservices` prefixes disabled services with `*`; networksetup
# rejects `*Name` as a service name, so the marker is stripped (a temporarily
# disabled service still exists). Each clear is verified: a missing service is
# skipped, anything else is reported. Returns non-zero if a real clear failed.
clear_system_proxy() {
    local listing svc name out rc service_failed
    if ! listing="$("$NETWORKSETUP" -listallnetworkservices 2>&1)"; then
        fail "cannot list network services ($listing)"
        return 1
    fi
    while IFS= read -r svc; do
        svc="${svc%$'\r'}"
        case "$svc" in
            ''|'An asterisk'*) continue ;;
        esac
        name="$(trim "${svc#\*}")"
        [ -z "$name" ] && continue
        service_failed=0
        for state in -setwebproxystate -setsecurewebproxystate; do
            out="$("$NETWORKSETUP" "$state" "$name" off 2>&1)"
            rc=$?
            [ "$rc" -eq 0 ] && continue
            if is_missing_service "$rc" "$out"; then
                say "skipped $name ($state): service no longer exists"
                service_failed=1
                break
            fi
            fail "$state \"$name\" off: ${out:-exit $rc} (exit $rc)"
            service_failed=1
        done
        if [ "$service_failed" -eq 0 ]; then
            say "reset $name to direct"
        fi
    done <<< "$listing"
    return 0
}

# ── 2. App + managed ssh ─────────────────────────────────────────────────────
stop_app() {
    if [ "$SKIP_APP_KILL" = "1" ]; then
        say "app kill skipped (SKIP_APP_KILL=1)"
        return 0
    fi
    if ! "$PKILL" -x ProxyManager 2>/dev/null; then
        say "ProxyManager not running"
        return 0
    fi
    say "stopping ProxyManager"
    local i=0
    while [ "$i" -lt 20 ] && "$PKILL" -0 -x ProxyManager 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
    if "$PKILL" -0 -x ProxyManager 2>/dev/null; then
        "$PKILL" -9 -x ProxyManager 2>/dev/null \
            && say "force-killed ProxyManager (SIGKILL)" \
            || warn "ProxyManager is still running after SIGKILL"
    fi
}

# True for a non-empty string of ASCII digits (no sign, no spaces).
is_digits() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Kills the managed `ssh -N -D` left behind by a crash.
#
# `ssh.pid` is `"<pid> <start_sec> <start_usec>"` (TC-14): a bare pid cannot
# prove identity, because PID reuse could make an unrelated ssh match. Kill only
# when BOTH the executable is still ssh AND the kernel start time (via
# `ps -o lstart=`, second granularity → ±1 s) matches the recorded one. A legacy
# pid-only file, a malformed file, or an unavailable `date`/`lstart` is never
# signalled (same policy as SSHTunnelRunner.reapStaleProcess).
reap_ssh() {
    [ -f "$SSH_PID_FILE" ] || { say "no managed ssh tunnel recorded"; return 0; }

    local pid="" sec="" usec="" extra="" comm="" lstart="" start_epoch="" delta=""
    read -r pid sec usec extra < "$SSH_PID_FILE" 2>/dev/null || true

    if ! is_digits "$pid" || [ "$pid" -le 0 ] || [ -n "$extra" ]; then
        rm -f "$SSH_PID_FILE"
        warn "removed a malformed ssh pid file (no process was signalled)"
        return 0
    fi
    if [ -z "$sec" ] || [ -z "$usec" ]; then
        rm -f "$SSH_PID_FILE"
        say "ssh.pid is a legacy pid-only record (no start time); skipped the kill for safety"
        return 0
    fi
    if ! is_digits "$sec" || ! is_digits "$usec" || [ "${#sec}" -gt 11 ] \
        || [ "${#usec}" -gt 6 ] || [ "$usec" -ge 1000000 ]; then
        rm -f "$SSH_PID_FILE"
        warn "removed an invalid ssh pid file (no process was signalled)"
        return 0
    fi

    comm="$(LC_ALL=C "$PS" -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')"
    case "$comm" in
        '')
            rm -f "$SSH_PID_FILE"
            say "managed ssh tunnel (pid $pid) not running"
            return 0
            ;;
        ssh|*/ssh) ;;
        *)
            rm -f "$SSH_PID_FILE"
            warn "pid $pid from ssh.pid is '$comm', not ssh — not killing it"
            return 0
            ;;
    esac

    lstart="$(LC_ALL=C "$PS" -p "$pid" -o lstart= 2>/dev/null)"
    lstart="$(trim "$lstart")"
    if [ -z "$lstart" ]; then
        rm -f "$SSH_PID_FILE"
        warn "cannot read the start time of pid $pid (ps lstart unavailable) — not killing it"
        return 0
    fi
    start_epoch="$(LC_ALL=C date -j -f "%a %b %e %T %Y" "$lstart" +%s 2>/dev/null)"
    if ! is_digits "$start_epoch"; then
        rm -f "$SSH_PID_FILE"
        warn "cannot parse the start time of pid $pid ('$lstart') — not killing it"
        return 0
    fi
    delta=$((start_epoch - sec))
    [ "$delta" -lt 0 ] && delta=$((-delta))
    if [ "$delta" -gt 1 ]; then
        rm -f "$SSH_PID_FILE"
        warn "pid $pid from ssh.pid was reused (start time differs) — not killing it"
        return 0
    fi

    if kill -9 "$pid" 2>/dev/null; then
        say "killed managed ssh tunnel (pid $pid)"
    else
        say "managed ssh tunnel (pid $pid) already gone"
    fi
    rm -f "$SSH_PID_FILE"
}

# Best-effort sweep of askpass dirs a crashed app left behind. Their secret
# file is single-use, but the directory (and a stale secret) should not
# outlive the tunnel.
sweep_askpass() {
    local dirs=() d
    [ -n "$TMP_ROOT" ] && dirs+=("$TMP_ROOT")
    [ "$TMP_ROOT" != "/tmp" ] && dirs+=("/tmp")
    for d in "${dirs[@]}"; do
        case "$d" in
            /*) rm -rf "$d"/proxymanager-ssh-* 2>/dev/null ;;
        esac
    done
    say "stale askpass dirs removed"
}

# ── 3. Shell rc files + env ──────────────────────────────────────────────────
#
# Strips the `# >>> proxy-manager >>>` block from the shell rc files we know
# about plus any custom path from config.json (`system.managedShellRcs`).
# Symlinks are followed so the link target is edited (never replaced), files
# without our block are left byte-identical, and modes are preserved.
cleanup_shell_env() {
    local rcs=(
        "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc"
        "$HOME/.bash_profile" "$HOME/.profile"
    )
    if ! "$OSASCRIPT" -l JavaScript - "$CONFIG" "$HOME" "${rcs[@]}" <<'JXA'
ObjC.import('Foundation');
ObjC.import('stdlib');

var START = '# >>> proxy-manager >>>';
var END = '# <<< proxy-manager <<<';

function trim(s) { return String(s).replace(/^\s+|\s+$/g, ''); }

function readText(path) {
    var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    return (s && !s.isNil()) ? s.js : null;
}

function symlinkDestination(path) {
    var d = $.NSFileManager.defaultManager.destinationOfSymbolicLinkAtPathError(path, null);
    return (d && !d.isNil()) ? d.js : null;
}

function dirname(p) {
    var i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
}

// Follows symlinks (up to 32 hops) so writing cannot replace a linked rc file.
function resolve(path) {
    var current = path;
    for (var i = 0; i < 32; i++) {
        var d = symlinkDestination(current);
        if (d === null) { break; }
        current = d.charAt(0) === '/' ? d : dirname(current) + '/' + d;
    }
    return current;
}

function stripBlocks(content) {
    var removed = false;
    for (;;) {
        var start = content.indexOf(START);
        if (start < 0) { break; }
        var end = content.indexOf(END, start + START.length);
        if (end < 0) { break; }
        content = content.substring(0, start) + content.substring(end + END.length);
        removed = true;
    }
    if (removed) { content = content.replace(/\n\n\n/g, '\n\n'); }
    return { content: content, removed: removed };
}

function customRcFiles(configPath) {
    var text = readText(configPath);
    if (text === null) { return []; }
    var config;
    try { config = JSON.parse(text); } catch (e) { return []; }
    var list = config && config.system && config.system.managedShellRcs;
    if (!Array.isArray(list)) { return []; }
    return list.filter(function (p) { return typeof p === 'string' && trim(p) !== ''; });
}

function run(argv) {
    var configPath = argv[0];
    var home = argv[1];
    var seen = {};
    var paths = [];

    function add(p) {
        var full = p === '~' ? home : (p.indexOf('~/') === 0 ? home + p.substring(1) : p);
        if (seen[full]) { return; }
        seen[full] = true;
        paths.push(full);
    }

    for (var i = 2; i < argv.length; i++) { add(argv[i]); }
    customRcFiles(configPath).forEach(add);

    var failures = 0;
    paths.forEach(function (path) {
        var fm = $.NSFileManager.defaultManager;
        if (!fm.fileExistsAtPath(path)) { return; }
        var target = resolve(path);
        var original = readText(target);
        if (original === null) {
            console.log('⚠️  cannot read ' + target + ' — leaving it alone');
            failures += 1;
            return;
        }
        var result = stripBlocks(original);
        if (!result.removed) { return; }

        var attrs = fm.attributesOfItemAtPathError(target, null);
        var perm = attrs ? attrs.objectForKey('NSFilePosixPermissions') : null;
        var wrote = $.NSString.alloc.initWithUTF8String(result.content)
            .writeToFileAtomicallyEncodingError(target, true, $.NSUTF8StringEncoding, null);
        if (!wrote) {
            console.log('⚠️  could not rewrite ' + target + ' — it still sources the proxy env');
            failures += 1;
            return;
        }
        if (perm) {
            fm.setAttributesOfItemAtPathError(
                $.NSDictionary.dictionaryWithObjectForKey(perm, 'NSFilePosixPermissions'), target, null);
        }
        console.log('  • removed proxy-manager block from ' + target);
    });

    $.exit(failures > 0 ? 1 : 0);
}
JXA
    then
        FAILED=1
        warn "some rc files still source the proxy env; remove the '# >>> proxy-manager >>>' block by hand"
    fi
    rm -f "$HOME/.config/proxy-manager/env.sh" "$SUPPORT_DIR/env/env.sh" 2>/dev/null
    say "shell env injection removed"
}

# ── 4. GUI session env ───────────────────────────────────────────────────────
#
# GuiEnvInjector saved the user's pre-existing values before publishing ours;
# restore those when the snapshot is readable, otherwise unset our variables.
# Never leave a var pointing at the dead local proxy.
cleanup_gui_env() {
    if "$OSASCRIPT" -l JavaScript - "$GUI_ENV_SNAPSHOT" "$LAUNCHCTL" $GUI_ENV_KEYS <<'JXA'
ObjC.import('Foundation');
ObjC.import('stdlib');

function shq(v) { return "'" + String(v).replace(/'/g, "'\\''") + "'"; }

function run(argv) {
    var snapshotPath = argv[0];
    var launchctl = argv[1];
    var keys = argv.slice(2);
    var app = Application.currentApplication();
    app.includeStandardAdditions = true;

    var snapshot = null;
    var raw = $.NSString.stringWithContentsOfFileEncodingError(snapshotPath, $.NSUTF8StringEncoding, null);
    if (raw && !raw.isNil()) {
        try { snapshot = JSON.parse(raw.js); } catch (e) { snapshot = null; }
        if (snapshot && (typeof snapshot !== 'object' || Array.isArray(snapshot))) { snapshot = null; }
    }

    function call(args) {
        try {
            app.doShellScript([launchctl].concat(args).map(shq).join(' ') + ' 2>/dev/null');
            return true;
        } catch (e) {
            return false;
        }
    }

    var restored = 0;
    var failed = 0;
    keys.forEach(function (key) {
        if (snapshot && typeof snapshot[key] === 'string' && snapshot[key] !== '') {
            if (call(['setenv', key, snapshot[key]])) { restored += 1; } else { failed += 1; }
        } else {
            call(['unsetenv', key]);
        }
    });
    if (failed > 0) {
        console.log('⚠️  could not restore ' + failed + ' GUI env var(s)');
        $.exit(1);
    }
    console.log(restored > 0
        ? '  • restored ' + restored + ' GUI env var(s), unset the rest'
        : '  • GUI env vars unset');
    $.exit(0);
}
JXA
    then
        rm -f "$GUI_ENV_SNAPSHOT"
    else
        FAILED=1
        warn "could not update the GUI session env; leaving $GUI_ENV_SNAPSHOT in place."
        warn "Apps launched from Finder may still use the dead proxy — log out or reboot."
    fi
}

# ── 5. Auto-enable flag ──────────────────────────────────────────────────────
clear_was_on_flag() {
    if "$DEFAULTS" delete "$BUNDLE_ID" routingWasOn 2>/dev/null; then
        say "auto-re-enable flag cleared"
    else
        say "auto-re-enable flag already clear"
    fi
}

# ── Marker helpers ───────────────────────────────────────────────────────────
# `restored_at=<ISO-8601>` is the first line of the marker, written by the JXA
# restore (which also records the service count).
marker_stamp() {
    grep '^restored_at=' "$MARKER" 2>/dev/null | head -n 1 | cut -d= -f2-
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo "🧹 Reverting Proxy Manager effects…"

unload_watchdog
unload_control_agent

did_clear=0
if [ "$RESET_TO_DIRECT" -eq 1 ]; then
    say "explicit --reset-to-direct: clearing the system proxy"
    clear_system_proxy
    did_clear=1
elif [ -s "$SNAPSHOT" ]; then
    restore_saved_proxy
    restore_rc=$?
    if [ "$restore_rc" -eq 0 ]; then
        if rm -f "$SNAPSHOT"; then
            PROXY_ACTION="restored"
            say "saved proxy settings restored; snapshot cleared"
            say "restore marker written (later runs leave the proxy untouched)"
        else
            fail "restored the proxy but could not delete $SNAPSHOT"
        fi
    elif [ "$restore_rc" -eq 3 ]; then
        # The proxy is back, but without the marker a later run would reset to
        # direct. Keep the snapshot so a re-run restores (and retries the marker).
        fail "the proxy was restored but $MARKER could not be written; snapshot kept"
    else
        RESTORE_FAILED=1
        FAILED=1
        warn "the saved proxy settings in $SNAPSHOT could not be restored."
        warn "The snapshot was KEPT. Fix the error above, then re-run ./revert.sh"
        warn "or relaunch Proxy Manager (it restores from the same snapshot)."
        if [ "$restore_rc" -eq 2 ]; then
            warn "The snapshot itself is unreadable or invalid JSON. If the system proxy"
            warn "is already correct in System Settings, delete $SNAPSHOT by hand."
        fi
    fi
elif [ -f "$MARKER" ]; then
    # A previous run already put the user's originals back: touching the proxy
    # now (reset to direct) is exactly the bug this marker exists to prevent.
    PROXY_ACTION="already"
    marker_time="$(marker_stamp)"
    say "the original proxy settings were already restored on ${marker_time:-a previous run}"
    say "leaving the system proxy untouched; pass --reset-to-direct to clear it"
else
    if [ -f "$SNAPSHOT" ]; then
        warn "ignoring empty snapshot file $SNAPSHOT"
    fi
    clear_system_proxy
    did_clear=1
fi

stop_app
reap_ssh
sweep_askpass

# The app may have re-applied the proxy while it was shutting down; when this
# run clears (first-ever reset or --reset-to-direct), verify once more. A
# restored snapshot, or a marker-only run, must never be cleared again.
if [ "$did_clear" -eq 1 ]; then
    sleep 1
    clear_system_proxy
    if [ "$FAILED" -eq 0 ]; then
        PROXY_ACTION="cleared"
    fi
fi

cleanup_shell_env
cleanup_gui_env
clear_was_on_flag

# --reset-to-direct is the only path that removes the recovery data: only after
# every clear command succeeded (a failed reset keeps the snapshot so a plain
# re-run can still restore the originals).
if [ "$RESET_TO_DIRECT" -eq 1 ]; then
    if [ "$FAILED" -eq 0 ]; then
        if rm -f "$MARKER" "$SNAPSHOT"; then
            say "reset to direct; removed the restore marker and any recovery snapshot"
        else
            fail "could not remove $MARKER or $SNAPSHOT"
        fi
    else
        warn "keeping $MARKER and any recovery snapshot because the reset did not complete"
    fi
fi

if [ "$RESTORE_FAILED" -ne 0 ]; then
    echo ""
    echo "❌ INCOMPLETE: your original proxy settings were not restored."
    echo "   The recovery snapshot is intact. Re-run ./revert.sh after fixing the"
    echo "   error above, or relaunch Proxy Manager to let it restore them."
    exit 1
fi

if [ "$FAILED" -ne 0 ]; then
    echo ""
    echo "❌ INCOMPLETE: some steps failed (see the messages above). Re-run ./revert.sh."
    exit 1
fi

case "$PROXY_ACTION" in
    restored) echo "✅ Done. The original proxy settings are restored." ;;
    already)  echo "✅ Done. The proxy was already restored by a previous run; it was left untouched." ;;
    cleared)  echo "✅ Done. The system proxy is set to a direct connection." ;;
    *)        echo "✅ Done." ;;
esac
