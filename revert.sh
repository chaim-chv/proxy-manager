#!/bin/bash
# ProxyManager — emergency revert.
#
# Immediately removes everything Proxy Manager does, so internet works again
# after a crash or hang. Safe to run repeatedly; idempotent.
#
# Usage:  ./revert.sh
set -u

echo "🧹 Reverting Proxy Manager effects…"

# 0. Unload the crash watchdog LaunchAgent FIRST, so it can't re-arm or
#    interfere, then remove its plist and armed-state marker.
launchctl bootout "gui/$(id -u)/com.proxymanager.watchdog" 2>/dev/null && \
    echo "  • crash watchdog unloaded" || \
    echo "  • crash watchdog not loaded"
rm -f "$HOME/Library/LaunchAgents/com.proxymanager.watchdog.plist"
rm -f "$HOME/Library/Application Support/ProxyManager/watchdog.json"

# 1. Stop the app (also stops the local proxy on 127.0.0.1:8888). This also
#    reaps the watchdog child, since it runs the same executable name.
if pkill -x ProxyManager 2>/dev/null; then
    echo "  • stopped ProxyManager"
else
    echo "  • ProxyManager not running"
fi

# 2. Clear the manual HTTP/HTTPS proxy it set on every network service. Do NOT
#    touch Auto Proxy (PAC) state: the app only ever disabled it, so re-enabling
#    it (possibly with a stale/WPAD URL) is not "restoring" anything.
while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    networksetup -setwebproxystate "$svc" off 2>/dev/null
    networksetup -setsecurewebproxystate "$svc" off 2>/dev/null
done < <(networksetup -listallnetworkservices | tail -n +2)
echo "  • system proxy cleared"

# 2b. Remove the persisted original-proxy snapshot so a later launch does not
#     load stale state (and then "restore" the user's proxy to an old value).
rm -f "$HOME/Library/Application Support/ProxyManager/system-proxy-snapshot.json"

# 3. Remove the shell env injection (HTTP_PROXY/HTTPS_PROXY) and its rc-file
#    source block.
for rc in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile"; do
    [ -f "$rc" ] && sed -i '' '/# >>> proxy-manager >>>/,/# <<< proxy-manager <<</d' "$rc"
done
rm -f "$HOME/.config/proxy-manager/env.sh"
echo "  • shell env injection removed"

# 4. Clear the persisted "was enabled" flag so a later relaunch does not
#    auto-re-enable routing.
defaults delete com.proxymanager.app routingWasOn 2>/dev/null && \
    echo "  • auto-re-enable flag cleared" || \
    echo "  • auto-re-enable flag already clear"

echo "✅ Done. Internet should work again (direct / PAC)."
