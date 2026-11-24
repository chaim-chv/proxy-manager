# Internet outages: are they caused by the SOCKS tunnel?

Case study of one anonymized 7-day telemetry sample (86,314 connections)
against a recurring user report:

> "My provider blocks or degrades the line when I use the SOCKS tunnel heavily.
> Maybe this app's tunnel implementation takes the internet down."

Reproduce every number here with:

```bash
python3 Tools/analyze-telemetry.py --days 7 --html /tmp/outage-analysis.html
```

## Verdict

**The hypothesis is not supported.** Heavy tunnel traffic is not followed by,
nor correlated with, internet outages. The opposite is visible in the data:
the worst direct-route failure rates happen in minutes with **no** tunnel
traffic at all.

The offline episodes are real, but they are a **DNS resolution failure**, not a
bandwidth or blocking side effect of the tunnel. During a DNS outage the
SOCKS tunnel keeps working, because the tunnel's hostnames are resolved by the
remote SSH server, not by the Mac.

There is a second, separate problem: **the tunnel itself degrades under load**
(5 s SOCKS handshake timeouts). That affects only tunneled traffic and does not
take the internet down.

Finally, **this app makes DNS outages look much worse than they are**. 66% of
all direct-connection failures are `dns_busy`, and every one of them was
rejected in under 0.5 s without even asking a resolver. That is the resolver
gate in `Sources/Socks/Socket.swift`, not the network. So the answer to "is it
this program?" is: *not the cause, but a significant amplifier of the visible
impact* — and that part is now fixed.

## 1. What the data can and cannot say

One telemetry row is one accepted connection. It records route, host, timing,
bytes and a stable error code. It does **not** contain:

- traffic that bypasses the proxy (an app configured to talk directly to the
  SOCKS port is invisible here);
- the OS reason for a resolver failure (only that `getaddrinfo` did not answer
  within 10 s);
- historical system/network logs — they were no longer retained, so the trigger
  is inferred from the proxy's own evidence.

What it can say is decisive: for every minute of the week, whether direct
connections were attempted, whether they succeeded, whether tunneled
connections were attempted, and whether they succeeded.

## 2. Failure composition

| Route | Connections | Failed | What dominates |
|---|---:|---:|---|
| DIRECT | 78,829 | 9,784 (12.4%) | `dns_busy` 66.0%, `dns` 26.7%, `timeout` 4.2% |
| TUNNEL | 7,317 | 954 (13.0%) | `socks_timeout` 77.7%, `closed` 12.4%, `timeout` 9.6% |

**92.7% of every direct failure is DNS.** Only 0.5% is a TCP-level timeout, and
0.4% is "unreachable". If the ISP were blocking or shaping the line, TCP
timeouts / resets / unreachable would dominate. They do not.

Duration histogram for `connect_failed: dns`:

| Wait | Rows |
|---|---:|
| ~10.0 s | 2,267 |
| ~0.0 s | 272 |
| everything else (1–9 s) | ~80 |

10.0 s is exactly the proxy's resolver budget (`Socket.resolve`). So in 2,267
cases the **system resolver never answered at all** — the lookup was abandoned
at the deadline, not refused by a remote server.

## 3. The direct evidence: DNS dies, the tunnel keeps working

Minutes where direct connections all failed while tunneled connections
succeeded are not theoretical. One representative sequence (hostnames
anonymized) inside a larger sample:

```
h:mm:04  DIRECT  probe.example.net   connect_failed: dns   waited 10.0 s
h:mm:12  DIRECT  api.example.com     connect_failed: dns   waited 10.0 s
h:mm:14  DIRECT  probe.example.net   connect_failed: dns   waited 10.0 s
h:mm:15  TUNNEL  api.example.com     OK                    connect 43 ms
h:mm:38  TUNNEL  cdn.example.org     OK                    connect 411 ms
h:mm:41  TUNNEL  api.example.com     OK                    connect 31 ms
h:mm:59  DIRECT  probe.example.net   connect_failed: dns   waited 10.0 s
```

While *every* new direct connection was failing at the resolver, the tunneled
connections opened in 29–411 ms. The network path was fine. DNS was not. The
tunnel is immune because it sends the hostname to the SOCKS server.

The same signature appears in other outage episodes (11-16 22:34, 11-21 14:15,
11-23 11:38): direct failures, tunnel successes.

## 4. Load correlation: the hypothesis in numbers

Pearson correlation over a **continuous** minute grid (missing minutes are
zeros, so quiet periods cannot inflate the result):

| Predictor | same minute | +1 min | +3 min | +10 min |
|---|---:|---:|---:|---:|
| tunnel connections → DNS errors | +0.063 | −0.019 | −0.023 | −0.017 |
| tunnel upload bytes → DNS errors | −0.007 | −0.010 | −0.008 | −0.009 |

There is no relationship, and the lagged values are slightly negative: if
anything, DNS failures are *less* likely after a tunnel burst.

Direct failure rate grouped by tunnel upload:

| Tunnel upload | Minutes | Direct connections | Failed |
|---|---:|---:|---:|
| 0 KB/min | 6,215 | 33,674 | **17.1%** |
| 1–50 KB/min | 3,519 | 38,716 | 10.0% |
| 50–500 KB/min | 29 | 928 | 6.0% |
| 0.5–2 MB/min | 37 | 1,008 | 2.4% |
| > 2 MB/min | 281 | 4,600 | **2.0%** |

The busiest tunnel minutes have the *lowest* direct failure rate. The 17.1% in
the zero-upload bucket is survivorship, not causation: outage minutes contain
only failing background retries, so they show no tunnel upload precisely
because nothing could connect.

## 5. The outages are real — and clustered

33 outage episodes (≥3 direct attempts, zero successes). The large ones:

| Start | Minutes | Direct attempts | DNS errors | Tunnel ok/attempts |
|---|---:|---:|---:|---:|
| 11-20 21:21 | 7 | 349 | 338 | 0/6 |
| 11-21 01:49 | 7 | 226 | 220 | 0/0 |
| 11-21 03:24 | 7 | 305 | 299 | 0/0 |
| 11-23 00:42 | 2 | 62 | 38 | 0/4 |
| 11-18 02:24 | 1 | 47 | 41 | 0/2 |

During the three 7-minute episodes the tunnel was barely used (0–6 attempts)
and those attempts also failed with SOCKS timeouts. That is consistent with a
**whole-network outage**, not DNS-only: when the SSH connection itself breaks,
the tunnel cannot open new streams either. Every direct connection still
manifests as a *DNS* failure, because DNS is the first step of every
connection — which is exactly why the monitor could not tell the two apart.

Many smaller episodes are exactly one minute long and cluster around 07:30–09:00
(e.g. 11-19 07:31, 07:47, 08:03, 08:20, 08:37, 08:54). That cadence looks like
a periodic network transition (resolver reconfiguration, VPN re-connect, or
sleep/wake with apps reconnecting before DNS is ready), not a data-volume
effect.

## 6. The tunnel has its own problem

Tunnel failures are dominated by `socks_timeout` (741), whose `connect_ms` is
pinned at ~5,004 ms — the SOCKS handshake timeout. They cluster in bursts
(12–18 per minute) and in hours with heavy tunnel use. Example: 2026-11-23
12:00–15:00 had repeated bursts of 17–39 SOCKS timeouts with multi-second
average connects, but **no direct-route DNS outage**.

So "heavy SOCKS" does have a cost — it degrades the tunnel's own handshakes.
It does not take the internet down. If Telegram talks to `127.0.0.1:1080`
directly, it would feel this as "Telegram is slow/offline" while everything
else works.

## 7. What the app contributes (and what changed)

This is the part of the user's suspicion that was justified.

1. **The resolver gate turned a slow resolver into instant failures.**
   `Socket.resolve` allowed only 8 concurrent `getaddrinfo` calls and waited
   50 ms for a slot. When the resolver stalled, the 8 slots stayed occupied for
   the full stall, and every new connection was rejected in ~50 ms with
   `dns_busy`. **6,458 such rows — 66% of all direct failures — and 100% of
   them were rejected in under 0.5 s.** They never asked a resolver.
   *Fixed:* 24 concurrent lookups and a 200 ms gate (`Socket.swift`), so bursts
   queue instead of failing. Regression: `Tests/CrashProbes/dns_timeout`.

2. **The monitor could not distinguish DNS from "no internet".**
   The probe is an HTTPS request, which starts with DNS. During a DNS-only
   outage it reported a flat "Offline" even though IP connectivity (and the
   tunnel) were fine.
   *Fixed:* when the name probe fails, the monitor now runs a raw TCP connect to
   literal IPs (`1.1.1.1:443`, `9.9.9.9:443`, no resolver, no system proxy) and
   reports **"Offline — DNS failing"** vs **"Offline"** with an honest
   explanation. `ConnectivityFailure` lives in `ConnectivityState.swift`.

3. **Outage history died with the process.**
   The snapshot kept 60 checks and a one-hour drop list, in memory only.
   *Fixed:* every probe is persisted to `connectivity_checks` and replayed by
   the dashboard, so outages can be reviewed after a relaunch.

4. **There was no way to see any of this.**
   *Fixed:* the dashboard has an **Internet** tab: uptime per range, outage
   count, longest outage, an availability timeline, and an outage list with a
   cause (DNS / Network / Unknown) and a **"tunnel during outages"** count that
   joins the outage windows against real `TUNNEL` rows.

## 8. What to do next

Ranked by expected value, with what would prove each one wrong:

1. **Change the resolver and watch the new timeline.** This sample used one
   public resolver. A single resolver is a single point of failure and a common
   target for ISP interference. Compare it with the router's DNS and a second
   independent resolver for a day. If the "DNS" outage count drops, the trigger
   was the resolver path, not the tunnel.
2. **Check filtering VPNs and content filters.** A content filter that detects
   tunnels can throttle or cut DNS as a policy decision. If outages correlate
   with the filter connecting or disconnecting, that is the trigger — and it is
   a provider policy, not a bug in this app. The new history makes that test
   possible (compare the outage timestamps with the VPN's own log).
3. **Separate "tunnel slow" from "internet down".** A `socks_timeout` burst
   means the SSH tunnel is congested or the remote side is slow; it is not an
   outage. If it becomes frequent, tune the keepalive, use a closer region, or
   cap concurrent tunnel streams.
4. **Do not read the connection feed as "the internet".** Direct failures mean
   *the proxy could not open a new outbound connection*; the tunnel's success
   during the same minute means the line was up.

## 9. Falsification

The conclusion would change if any of these appear in future data:

- DNS error rate rising monotonically with tunnel upload (the current
  correlation is ~0 and slightly negative);
- outages starting **after** a tunnel burst in the same minute with the tunnel
  idle beforehand (current lag 1–10 correlations are negative);
- IP-literal probes failing while the resolver is healthy (that would be
  packet filtering, and the new monitor would label it "Network");
- `networksetup`/system logs showing interface drops at the same timestamps
  (the new persisted history gives exact timestamps to compare).

Until one of those is observed, "heavy SOCKS takes the internet down" is not
supported by 86,314 connections of evidence.
