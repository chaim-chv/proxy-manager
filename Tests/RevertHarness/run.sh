#!/bin/bash
# Regression harness for revert.sh (the user's emergency lifeline).
#
# The real script is executed, but every system tool it can mutate is replaced
# with a fake that only logs its argv, and HOME / TMPDIR /
# PROXYMANAGER_SUPPORT_DIR point at a throwaway directory. No real network
# service, launchd job, default, process or user file is touched.
#
#   ./Tests/RevertHarness/run.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/revert.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pm-revert-harness.XXXXXX")"
FAKEBIN="$WORK/fakebin"
SLEEP_PID=""
FAKE_PS_LSTART=""   # fake `ps -o lstart=` output for the current case

cleanup() {
    if [ -n "$SLEEP_PID" ]; then kill -9 "$SLEEP_PID" 2>/dev/null; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

expect_file() { # file, description
    if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

expect_absent() { # path, description
    if [ ! -e "$1" ]; then ok "$2"; else bad "$2 (still exists: $1)"; fi
}

expect_contains() { # file, needle, description
    if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (no '$2' in $1)"; fi
}

expect_not_contains() { # file, needle, description
    if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found '$2')"; else ok "$3"; fi
}

expect_count() { # file, needle, expected, description
    local n
    n="$(grep -cF -- "$2" "$1" 2>/dev/null || true)"
    if [ "${n:-0}" -eq "$3" ]; then ok "$4"; else bad "$4 (expected $3, got ${n:-0})"; fi
}

expect_rc() { # actual, expected, description
    if [ "$1" -eq "$2" ]; then ok "$3"; else bad "$3 (exit $1, expected $2)"; fi
}

expect_stat_gone() { # pid, description
    local stat
    stat="$(/bin/ps -p "$1" -o stat= 2>/dev/null | tr -d '[:space:]')"
    case "$stat" in
        ''|Z*) ok "$2" ;;
        *)     bad "$2 (process still $stat)" ;;
    esac
}

expect_stat_alive() { # pid, description
    local stat
    stat="$(/bin/ps -p "$1" -o stat= 2>/dev/null | tr -d '[:space:]')"
    case "$stat" in
        ''|Z*) bad "$2 (process is not running)" ;;
        *)     ok "$2" ;;
    esac
}

# Real start time of a pid in the exact format `ps -o lstart=` prints (C locale,
# internal spaces preserved so `date -j -f "%a %b %e %T %Y"` can parse it).
lstart_of() {
    LC_ALL=C /bin/ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

epoch_of_lstart() {
    LC_ALL=C date -j -f "%a %b %e %T %Y" "$1" +%s 2>/dev/null
}

# ── Fakes ────────────────────────────────────────────────────────────────────
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/networksetup" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG_DIR/networksetup"
if [ "${1:-}" = "-listallnetworkservices" ]; then
    cat "$FAKE_LIST" 2>/dev/null
    exit 0
fi
svc="${2:-}"
case " ${FAKE_MISSING:-} " in
    *" $svc "*)
        printf '%s\n' "** Error: Unable to find item in network database."
        exit 8
        ;;
esac
if [ -n "${FAKE_FAIL_SERVICE:-}" ] && [ "$svc" = "$FAKE_FAIL_SERVICE" ]; then
    printf '%s\n' "** Error: could not set the proxy for $svc." >&2
    exit 1
fi
exit 0
FAKE

cat > "$FAKEBIN/launchctl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG_DIR/launchctl"
exit 0
FAKE

cat > "$FAKEBIN/defaults" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG_DIR/defaults"
exit 0
FAKE

cat > "$FAKEBIN/pkill" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG_DIR/pkill"
exit 1
FAKE

cat > "$FAKEBIN/ps" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG_DIR/ps"
for arg in "$@"; do
    case "$arg" in
        lstart=)
            cat "$FAKE_PS_LSTART" 2>/dev/null
            exit 0
            ;;
        comm=)
            echo ssh
            exit 0
            ;;
    esac
done
echo ssh
exit 0
FAKE

chmod +x "$FAKEBIN"/*

# ── Static guards: every tool must be reachable through its override ─────────
# Exactly one hard-coded absolute path each (the `VAR="${VAR:-default}"` line).
for tool in /usr/sbin/networksetup /bin/launchctl /usr/bin/defaults /usr/bin/pkill /bin/ps; do
    n="$(grep -cF -- "$tool" "$SCRIPT" || true)"
    if [ "${n:-0}" -eq 1 ]; then
        ok "revert.sh uses the override for $tool"
    else
        bad "revert.sh hard-codes $tool $n time(s)"
    fi
done
if grep -qE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "$SCRIPT"; then
    bad "revert.sh does not eval snapshot values"
else
    ok "revert.sh does not eval snapshot values"
fi

write_snapshot() { # target
    cat > "$1" <<'JSON'
{
  "Wi-Fi": {
    "webEnabled": true,
    "webServer": "proxy.corp",
    "webPort": "8080",
    "webAuthenticated": true,
    "secureEnabled": true,
    "secureServer": "proxy.corp",
    "securePort": "8443",
    "secureAuthenticated": false,
    "pacEnabled": true,
    "pacURL": "http://pac.corp/proxy.pac",
    "autoDiscoveryEnabled": false,
    "bypassDomains": ["*.corp"]
  },
  "Gone": {
    "webEnabled": true,
    "webServer": "proxy.corp",
    "webPort": "8080",
    "webAuthenticated": false,
    "secureEnabled": false,
    "secureServer": "",
    "securePort": "",
    "secureAuthenticated": false,
    "pacEnabled": false,
    "pacURL": "",
    "autoDiscoveryEnabled": false,
    "bypassDomains": []
  }
}
JSON
}

new_case() { # name → prints dir
    local dir="$WORK/$1"
    mkdir -p "$dir/home" "$dir/support" "$dir/tmp" "$dir/logs"
    printf '%s\n' "$dir"
}

run_revert() { # dir, missing-services, fail-service, skip-app-kill, [extra args]
    local dir="$1" missing="${2:-}" fail_svc="${3:-}" skip_kill="${4:-1}" rc=0
    shift 4
    (
        cd "$ROOT" || exit 1
        HOME="$dir/home" \
        PROXYMANAGER_SUPPORT_DIR="$dir/support" \
        TMPDIR="$dir/tmp" \
        NETWORKSETUP="$FAKEBIN/networksetup" \
        LAUNCHCTL="$FAKEBIN/launchctl" \
        DEFAULTS="$FAKEBIN/defaults" \
        PKILL="$FAKEBIN/pkill" \
        PS="$FAKEBIN/ps" \
        FAKE_LOG_DIR="$dir/logs" \
        FAKE_LIST="$dir/list.txt" \
        FAKE_MISSING="$missing" \
        FAKE_FAIL_SERVICE="$fail_svc" \
        FAKE_PS_LSTART="$FAKE_PS_LSTART" \
        SKIP_APP_KILL="$skip_kill" \
        bash "$SCRIPT" "$@" > "$dir/out.txt" 2>&1
    )
    rc=$?
    printf '%s' "$rc"
}

printf '== revert.sh harness ==\n'

# ── 1. Snapshot present: originals are restored, snapshot cleared ────────────
printf '\n-- snapshot restore --\n'
CASE="$(new_case snapshot)"
write_snapshot "$CASE/support/system-proxy-snapshot.json"
rc="$(run_revert "$CASE" "Gone" "" 1)"
LOG="$CASE/logs/networksetup"
expect_rc "$rc" 0 "restore exits 0 even though a snapshotted service is gone"
expect_contains "$CASE/out.txt" "restored Wi-Fi" "reports the restored service"
expect_contains "$LOG" "-setwebproxy Wi-Fi proxy.corp 8080 on" "restores web proxy + port + auth flag"
expect_contains "$LOG" "-setsecurewebproxy Wi-Fi proxy.corp 8443 off" "restores secure proxy + port"
expect_contains "$LOG" "-setwebproxystate Wi-Fi on" "restores web enabled state"
expect_contains "$LOG" "-setsecurewebproxystate Wi-Fi on" "restores secure enabled state"
expect_contains "$LOG" "-setautoproxyurl Wi-Fi http://pac.corp/proxy.pac" "restores the PAC URL"
expect_contains "$LOG" "-setautoproxystate Wi-Fi on" "re-enables PAC"
expect_contains "$LOG" "-setproxyautodiscovery Wi-Fi off" "restores auto-proxy discovery"
expect_contains "$LOG" "-setproxybypassdomains Wi-Fi *.corp" "restores the bypass list"
expect_contains "$CASE/out.txt" "no longer exist: Gone" "skips the deleted service and continues"
expect_absent "$CASE/support/system-proxy-snapshot.json" "deletes the snapshot after a successful restore"
MARKER="$CASE/support/system-proxy-snapshot.restored"
expect_file "$MARKER" "writes the restore marker before deleting the snapshot"
expect_contains "$MARKER" "restored_at=" "the marker records a timestamp"
expect_contains "$MARKER" "services=1" "the marker counts only the restored service (Gone was skipped)"
expect_contains "$CASE/logs/launchctl" "bootout gui/$(id -u)/com.proxymanager.watchdog" "unloads the crash watchdog"
expect_contains "$CASE/logs/launchctl" "unsetenv HTTP_PROXY" "unsets the GUI proxy env"
expect_contains "$CASE/logs/defaults" "delete com.proxymanager.app routingWasOn" "clears the auto-enable flag"
expect_contains "$CASE/out.txt" "Done." "prints the success line"

# ── 2. Snapshot present but a real restore failure: keep everything ──────────
printf '\n-- snapshot restore failure --\n'
CASE="$(new_case restore-failure)"
write_snapshot "$CASE/support/system-proxy-snapshot.json"
rc="$(run_revert "$CASE" "Gone" "Wi-Fi" 1)"
LOG="$CASE/logs/networksetup"
expect_rc "$rc" 1 "exit code is non-zero when the restore fails"
expect_file "$CASE/support/system-proxy-snapshot.json" "keeps the snapshot after a failed restore"
expect_contains "$CASE/out.txt" "could not be restored" "explains the failure"
expect_contains "$CASE/out.txt" "snapshot was KEPT" "tells the user the snapshot is intact"
expect_contains "$CASE/out.txt" "no longer exist: Gone" "still skips gone services before failing"
expect_not_contains "$LOG" "-setwebproxystate Wi-Fi off" "does not clear the proxy on a failed restore"
expect_absent "$CASE/support/system-proxy-snapshot.restored" "does not write the marker on a failed restore"

# ── 2b. Unreadable snapshot: never clear, never delete ──────────────────────
printf '\n-- unreadable snapshot --\n'
CASE="$(new_case bad-snapshot)"
printf '{ "Wi-Fi": ' > "$CASE/support/system-proxy-snapshot.json"
rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 1 "exit code is non-zero for an unreadable snapshot"
expect_file "$CASE/support/system-proxy-snapshot.json" "keeps an unreadable snapshot"
expect_contains "$CASE/out.txt" "not valid JSON" "says the snapshot is unreadable"
expect_not_contains "$CASE/logs/networksetup" "-setwebproxystate" "does not reset to direct over an unreadable snapshot"
expect_absent "$CASE/support/system-proxy-snapshot.restored" "does not write a marker from an unreadable snapshot"

# ── 2c. Empty bypass list is cleared with `Empty`; PAC off without a URL ────
printf '\n-- empty bypass and PAC guard --\n'
CASE="$(new_case empty-bypass)"
cat > "$CASE/support/system-proxy-snapshot.json" <<'JSON'
{
  "Wi-Fi": {
    "webEnabled": false,
    "webServer": "",
    "webPort": "",
    "webAuthenticated": false,
    "secureEnabled": false,
    "secureServer": "",
    "securePort": "",
    "secureAuthenticated": false,
    "pacEnabled": true,
    "pacURL": "",
    "autoDiscoveryEnabled": true,
    "bypassDomains": []
  }
}
JSON
rc="$(run_revert "$CASE" "" "" 1)"
LOG="$CASE/logs/networksetup"
expect_rc "$rc" 0 "empty-bypass restore exits 0"
expect_contains "$LOG" "-setproxybypassdomains Wi-Fi Empty" "clears an empty bypass list with Empty"
expect_contains "$LOG" "-setautoproxystate Wi-Fi off" "never leaves PAC enabled without a URL"
expect_not_contains "$LOG" "-setautoproxyurl" "does not set an empty PAC URL"
expect_contains "$LOG" "-setproxyautodiscovery Wi-Fi on" "restores auto-discovery on"
expect_absent "$CASE/support/system-proxy-snapshot.json" "deletes the snapshot after this restore"
MARKER="$CASE/support/system-proxy-snapshot.restored"
expect_file "$MARKER" "writes the marker for a single-service restore"
expect_contains "$MARKER" "services=1" "the marker counts the restored service"

# ── 3. No snapshot: reset to direct, strip '*', tolerate a missing service ───
printf '\n-- no snapshot (reset to direct) --\n'
CASE="$(new_case direct)"
printf '%s\n' \
    'An asterisk (*) denotes that a network service is disabled.' \
    '*Thunderbolt Bridge' \
    'Wi-Fi' > "$CASE/list.txt"
rc="$(run_revert "$CASE" "Wi-Fi" "" 1)"
LOG="$CASE/logs/networksetup"
expect_rc "$rc" 0 "reset exits 0"
expect_contains "$LOG" "-setwebproxystate Thunderbolt Bridge off" "clears HTTP on a disabled service without the '*'"
expect_contains "$LOG" "-setsecurewebproxystate Thunderbolt Bridge off" "clears HTTPS on a disabled service without the '*'"
expect_not_contains "$LOG" "*Thunderbolt" "never passes '*Name' to networksetup"
expect_contains "$LOG" "-setwebproxystate Wi-Fi off" "tries the missing service"
expect_contains "$CASE/out.txt" "skipped Wi-Fi" "skips the missing service"
expect_count "$LOG" "-setwebproxystate Thunderbolt Bridge off" 2 "re-checks the reset after the app is stopped"
expect_absent "$CASE/support/system-proxy-snapshot.json" "does not create or delete a snapshot"
expect_absent "$CASE/support/system-proxy-snapshot.restored" "does not write a marker on a first-ever reset"

# ── 3b. Second run with only the marker: proxy is left alone ─────────────────
printf '\n-- repeat run (marker present, no snapshot) --\n'
CASE="$(new_case repeat)"
write_snapshot "$CASE/support/system-proxy-snapshot.json"
rc="$(run_revert "$CASE" "Gone" "" 1)"
expect_rc "$rc" 0 "first run restores and exits 0"
MARKER="$CASE/support/system-proxy-snapshot.restored"
expect_file "$MARKER" "first run writes the restore marker"
cp "$CASE/logs/networksetup" "$CASE/logs/networksetup.run1"
cp "$CASE/out.txt" "$CASE/out.run1.txt"
: > "$CASE/logs/networksetup"   # only the second run's commands land here

# Arm things the second run must still clean up (rc block + managed ssh).
cat > "$CASE/home/.zshrc" <<'RC'
# >>> proxy-manager >>>
source env.sh
# <<< proxy-manager <<<
RC
sleep 120 &
SLEEP_PID=$!
disown 2>/dev/null || true
SSH_LSTART="$(lstart_of "$SLEEP_PID")"
SSH_SEC="$(epoch_of_lstart "$SSH_LSTART")"
printf '%s %s 0' "$SLEEP_PID" "$SSH_SEC" > "$CASE/support/ssh.pid"
printf '%s\n' "$SSH_LSTART" > "$CASE/lstart.txt"
FAKE_PS_LSTART="$CASE/lstart.txt"

rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 0 "second run (marker only) exits 0"
expect_contains "$CASE/out.txt" "already restored" "second run says the originals were already restored"
expect_contains "$CASE/out.txt" "leaving the system proxy untouched" "second run leaves the proxy untouched"
if [ -s "$CASE/logs/networksetup" ]; then
    bad "second run issues no networksetup command at all"
else
    ok "second run issues no networksetup command at all"
fi
expect_not_contains "$CASE/logs/networksetup" "-setwebproxystate" "second run never clears a proxy state"
expect_not_contains "$CASE/logs/networksetup" "-setwebproxy" "second run never resets a proxy server"
expect_file "$CASE/logs/networksetup.run1" "the first run's command log is preserved for the record"
expect_file "$MARKER" "the marker survives the second run"
expect_not_contains "$CASE/home/.zshrc" "proxy-manager" "second run still strips the rc block"
expect_contains "$CASE/logs/launchctl" "unsetenv HTTP_PROXY" "second run still clears the GUI env"
expect_contains "$CASE/out.txt" "killed managed ssh tunnel (pid $SLEEP_PID)" "second run still reaps the managed ssh"
expect_stat_gone "$SLEEP_PID" "the ssh process is gone after the second run"
SLEEP_PID=""

# ── 3c. --reset-to-direct after a restore: clears and removes the marker ────
printf '\n-- --reset-to-direct after a restore --\n'
CASE="$(new_case reset-direct)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
write_snapshot "$CASE/support/system-proxy-snapshot.json"
rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 0 "restore run exits 0 before the explicit reset"
MARKER="$CASE/support/system-proxy-snapshot.restored"
expect_file "$MARKER" "the restore marker exists before the explicit reset"
: > "$CASE/logs/networksetup"   # keep only the reset run's commands in the log
rc="$(run_revert "$CASE" "" "" 1 --reset-to-direct)"
expect_rc "$rc" 0 "--reset-to-direct exits 0"
expect_contains "$CASE/logs/networksetup" "-setwebproxystate Wi-Fi off" "explicit reset clears the proxy"
expect_contains "$CASE/out.txt" "direct connection" "explicit reset reports a direct connection"
expect_absent "$MARKER" "explicit reset removes the restore marker"
expect_absent "$CASE/support/system-proxy-snapshot.json" "explicit reset removes the recovery snapshot"

# ── 3d. --reset-to-direct wins over a still-present snapshot ─────────────────
printf '\n-- --reset-to-direct with a snapshot present --\n'
CASE="$(new_case reset-direct-snapshot)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
write_snapshot "$CASE/support/system-proxy-snapshot.json"
rc="$(run_revert "$CASE" "" "" 1 --reset-to-direct)"
expect_rc "$rc" 0 "--reset-to-direct with a snapshot exits 0"
expect_contains "$CASE/logs/networksetup" "-setwebproxystate Wi-Fi off" "explicit reset clears instead of restoring"
expect_not_contains "$CASE/logs/networksetup" "-setwebproxy Wi-Fi proxy.corp" "explicit reset does not restore the snapshot proxy"
expect_absent "$CASE/support/system-proxy-snapshot.json" "explicit reset removes the snapshot after clearing"
expect_absent "$CASE/support/system-proxy-snapshot.restored" "explicit reset leaves no marker behind"

# ── 3e. Failed --reset-to-direct keeps the recovery data ────────────────────
printf '\n-- failed --reset-to-direct --\n'
CASE="$(new_case reset-direct-failure)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
write_snapshot "$CASE/support/system-proxy-snapshot.json"
rc="$(run_revert "$CASE" "" "Wi-Fi" 1 --reset-to-direct)"
expect_rc "$rc" 1 "a failed explicit reset exits non-zero"
expect_file "$CASE/support/system-proxy-snapshot.json" "a failed explicit reset keeps the snapshot"
expect_not_contains "$CASE/out.txt" "Done. The system proxy is set to a direct connection" "a failed explicit reset does not claim success"

# ── 4. Managed ssh reaping: pid + kernel start time must both match ──────────
printf '\n-- managed ssh reaping (3-field record) --\n'
CASE="$(new_case ssh)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
sleep 120 &
SLEEP_PID=$!
disown 2>/dev/null || true   # keep bash from printing "Killed: 9" for our own test child
SSH_LSTART="$(lstart_of "$SLEEP_PID")"
SSH_SEC="$(epoch_of_lstart "$SSH_LSTART")"
printf '%s %s 0' "$SLEEP_PID" "$SSH_SEC" > "$CASE/support/ssh.pid"
printf '%s\n' "$SSH_LSTART" > "$CASE/lstart.txt"
FAKE_PS_LSTART="$CASE/lstart.txt"
rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 0 "ssh case exits 0"
expect_contains "$CASE/out.txt" "killed managed ssh tunnel (pid $SLEEP_PID)" "kills the managed ssh when pid and start time match"
expect_contains "$CASE/logs/ps" "-o comm=" "verifies the executable is still ssh"
expect_contains "$CASE/logs/ps" "-o lstart=" "verifies the kernel start time"
expect_stat_gone "$SLEEP_PID" "the ssh process is gone"
expect_absent "$CASE/support/ssh.pid" "removes the stale ssh pid file"
SLEEP_PID=""

# ── 4b. Recorded start time differs: PID was reused, never signal it ─────────
printf '\n-- managed ssh reaping (start-time mismatch) --\n'
CASE="$(new_case ssh-mismatch)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
sleep 120 &
SLEEP_PID=$!
disown 2>/dev/null || true
SSH_LSTART="$(lstart_of "$SLEEP_PID")"
SSH_SEC="$(epoch_of_lstart "$SSH_LSTART")"
printf '%s %s 0' "$SLEEP_PID" "$((SSH_SEC - 3600))" > "$CASE/support/ssh.pid"
printf '%s\n' "$SSH_LSTART" > "$CASE/lstart.txt"
FAKE_PS_LSTART="$CASE/lstart.txt"
rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 0 "mismatched-start case exits 0"
expect_contains "$CASE/out.txt" "start time differs" "detects the reused pid"
expect_contains "$CASE/out.txt" "not killing it" "refuses to kill a reused pid"
expect_stat_alive "$SLEEP_PID" "the process with the mismatched start time survives"
expect_absent "$CASE/support/ssh.pid" "removes the stale pid file after the mismatch"
kill -9 "$SLEEP_PID" 2>/dev/null
SLEEP_PID=""

# ── 4c. Legacy pid-only record: never trusted, never killed ──────────────────
printf '\n-- managed ssh reaping (legacy pid-only record) --\n'
CASE="$(new_case ssh-legacy)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
sleep 120 &
SLEEP_PID=$!
disown 2>/dev/null || true
printf '%s' "$SLEEP_PID" > "$CASE/support/ssh.pid"
FAKE_PS_LSTART=""
rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 0 "legacy pid-only case exits 0"
expect_contains "$CASE/out.txt" "legacy pid-only record" "recognizes the legacy pid-only format"
expect_contains "$CASE/out.txt" "skipped the kill for safety" "does not kill from a pid-only file"
expect_stat_alive "$SLEEP_PID" "the legacy-record process survives"
expect_absent "$CASE/support/ssh.pid" "removes the legacy pid file"
kill -9 "$SLEEP_PID" 2>/dev/null
SLEEP_PID=""

# ── 4d. Malformed / empty pid file: removed, nothing signalled ───────────────
printf '\n-- managed ssh reaping (malformed record) --\n'
CASE="$(new_case ssh-malformed)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
printf 'not a pid\n' > "$CASE/support/ssh.pid"
FAKE_PS_LSTART=""
rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 0 "malformed pid file case exits 0"
expect_contains "$CASE/out.txt" "malformed ssh pid file" "reports the malformed pid file"
expect_absent "$CASE/support/ssh.pid" "removes the malformed pid file"
: > "$CASE/support/ssh.pid"
rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 0 "empty pid file case exits 0"
expect_absent "$CASE/support/ssh.pid" "removes an empty pid file"

# ── 5. App kill branch is reachable (fake pkill reports "not running") ───────
printf '\n-- app kill via pkill --\n'
CASE="$(new_case app-kill)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
rc="$(run_revert "$CASE" "" "" 0)"
expect_rc "$rc" 0 "app-kill case exits 0"
expect_contains "$CASE/logs/pkill" "-x ProxyManager" "asks pkill for the app by exact name"
expect_contains "$CASE/out.txt" "ProxyManager not running" "reports when the app is already gone"

# ── 6. rc blocks (default + custom) and symlinks are cleaned ─────────────────
printf '\n-- shell rc cleanup --\n'
CASE="$(new_case rc)"
printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' > "$CASE/list.txt"
cat > "$CASE/home/.zshrc" <<'RC'
export EDITOR=vim
# >>> proxy-manager >>>
[ -f "$HOME/.config/proxy-manager/env.sh" ] && . "$HOME/.config/proxy-manager/env.sh"
# <<< proxy-manager <<<
alias ll='ls -l'
RC
cat > "$CASE/home/.customrc" <<'RC'
# custom rc
# >>> proxy-manager >>>
source env.sh
# <<< proxy-manager <<<
# end
RC
ln -sf .customrc "$CASE/home/.linkedrc"
cat > "$CASE/support/config.json" <<'JSON'
{"system": {"managedShellRcs": ["~/.customrc", "~/.linkedrc"]}}
JSON
cat > "$CASE/support/gui-env-snapshot.json" <<'JSON'
{"HTTP_PROXY": "http://corp-pac:3128"}
JSON
rc="$(run_revert "$CASE" "" "" 1)"
expect_rc "$rc" 0 "rc case exits 0"
expect_not_contains "$CASE/home/.zshrc" "proxy-manager" "strips the block from ~/.zshrc"
expect_contains "$CASE/home/.zshrc" "export EDITOR=vim" "keeps the rest of ~/.zshrc"
expect_contains "$CASE/home/.zshrc" "alias ll='ls -l'" "keeps ~/.zshrc content after the block"
expect_not_contains "$CASE/home/.customrc" "proxy-manager" "strips the block from a custom rc file"
expect_contains "$CASE/home/.customrc" "# custom rc" "keeps custom rc content"
expect_contains "$CASE/logs/launchctl" "setenv HTTP_PROXY http://corp-pac:3128" "restores a saved GUI env value"
expect_contains "$CASE/logs/launchctl" "unsetenv HTTPS_PROXY" "unsets GUI env vars that were not saved"
expect_absent "$CASE/support/gui-env-snapshot.json" "removes the GUI env snapshot"

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n'
if [ "$fail" -eq 0 ]; then
    printf '✅ PASS: revert.sh (%d checks)\n' "$pass"
    exit 0
fi
printf '❌ FAIL: revert.sh (%d passed, %d failed)\n' "$pass" "$fail"
exit 1
