---
name: claude-anti-ban
description: >-
  Configure and audit a machine (especially a VM or remote box behind a proxy/VPN) so its
  observable identity is fully self-consistent and leaks nothing about its real location.
  Aligns exit-IP geolocation, OS timezone, browser timezone, browser language
  (Accept-Language / navigator.language), OS locale/region/country, and clock — and checks for
  real-IP leaks (WebRTC, IPv6, DNS) and automation flags (navigator.webdriver). Use this whenever
  the user wants to run an account (Claude, or any web service) on a proxied/remote machine without
  getting flagged or banned; asks to "make my VM look like it's in <country/region>"; wants to match
  a machine's timezone/language to its proxy IP; asks to check, audit, or harden a machine against
  "ban risk" / fingerprint inconsistency / IP-timezone-language mismatch; or sets up a fail-closed
  proxy gateway so all traffic exits through one IP. Trigger even when the user does not say "ban" —
  e.g. "why does X keep flagging my account", "my VPN exits in the US but my browser is Chinese",
  "verify my proxy setup doesn't leak my real IP", "is my Windows VM safe to run Claude on".
---

# Account Ban-Risk Hardening & Detection

## Why accounts get flagged (read this first)

Anti-abuse systems on Claude and most web services do **not** ban "using a proxy" per se. They flag two things:

1. **Inconsistency** — the machine's observable layers disagree with each other. The textbook red flag is a US exit IP paired with a China timezone and a Chinese browser language. A real person in California has a California IP, a Pacific clock, and an `en-US` browser. When those disagree, the session looks synthetic.
2. **Automation / leakage** — markers that scream "bot" (`navigator.webdriver = true`, a headless user-agent) or that leak the *real* location despite the proxy (WebRTC STUN, IPv6, or DNS escaping the tunnel).

So the job has two halves, and this skill does both:

- **Configure** every observable layer to agree with the proxy's exit location, and force all traffic through the proxy with no leaks.
- **Detect / audit** the machine for any residual mismatch, leak, or automation flag — with repeatable scripts.

This is about *consistency and honesty of a legitimately proxied machine*, not evading security. It does not make a machine "undetectable"; it removes the self-contradictions that get flagged. Behavioural and account-level factors (payment, registration, usage patterns, multi-accounting) are out of scope and matter just as much — say so to the user.

## The signal stack — what an account actually sees

The single most important thing to internalize: **the browser language does NOT follow the OS language automatically.** This is the trap people fall into — they fix the OS to en-US, but the browser keeps sending `Accept-Language: zh-CN`, and the account still looks wrong. Each layer must be set on its own.

| Layer | Who observes it | How it's checked | Where it's actually set |
|---|---|---|---|
| Exit IP geolocation | the service's servers (every request) | `curl https://api.ipify.org` from the machine | the proxy/VPN node |
| Browser timezone | JS `Intl.DateTimeFormat().resolvedOptions().timeZone` | headless browser eval (`fp_check.ps1`) | **OS timezone** (browser follows it) |
| Browser language | JS `navigator.language` / `navigator.languages`, `Accept-Language` header | headless browser eval (`fp_check.ps1`) | **the browser's own setting** (Chrome `intl.accept_languages`), NOT the OS |
| OS timezone | (feeds the browser) | `tzutil /g` | `tzutil /s` (admin) |
| OS locale / region / country | rarely web-visible; consistency | `Get-Culture`, `Get-WinHomeLocation` | `Set-Culture`, `Set-WinHomeLocation` |
| Clock accuracy | TLS, auth tokens, some risk engines | `Get-Date` vs real time | NTP (`w32time`) |
| WebRTC | JS RTCPeerConnection (STUN) | leak-test page | force UDP through proxy, or disable |
| IPv6 | the service's servers | `curl https://api6.ipify.org` (should fail) | disable IPv6 / block at gateway |
| DNS | reveals lookups, sometimes location | DNS-leak test | resolver behind the proxy |
| Automation | JS `navigator.webdriver`, UA string | headless browser eval | don't drive the browser with automation |

`references/ban-signals.md` is the full checklist with severities and per-signal fixes — read it when auditing or when a specific signal is in question.

## The workflow

Work top-down: pin the target identity, force all traffic through the proxy, then make each layer match, then verify. Do not skip the verification phase — most of the value is catching the one layer that silently disagrees (almost always the browser language).

### Phase 0 — Pin the target identity

Everything aligns to the **proxy's exit IP**. Establish, and write down:

- Exit IP and its **city/region** → look it up (the leak-test pages report the city). Example: a node that geolocates to California → **`America/Los_Angeles`**, country **US**, language **`en-US`**. (Command examples below use the placeholder IP `203.0.113.10` — substitute your node's real exit IP.)
- The Windows timezone ID (e.g. `Pacific Standard Time` covers PST/PDT with DST), the GeoID (US = `244`), and the language tag (`en-US`).

`references/ban-signals.md` has a small lookup table of common region → timezone ID / GeoID / language.

### Phase 1 — Force ALL traffic through the proxy, fail-closed

The machine must have **no path to the internet except the proxy**, so nothing — not an app, not UDP, not DNS, not IPv6 — can leak the real IP. The strongest form is a separate gateway the machine is physically routed through, with a kill switch (proxy down ⇒ machine offline, never falls back to direct).

If the user already has working proxying, audit it for leaks (Phase 4) rather than rebuilding. If they need to build it, `references/proxy-gateway.md` documents a battle-tested setup: a Linux gateway VM running xray TPROXY that transparently routes a Windows VM (and itself) through a single VLESS node, with an nftables fail-closed kill switch. Verify it with `scripts/gateway_audit.sh` (which can also run the fail-closed test).

### Phase 2 — Align the OS to the exit region

Run `scripts/set_locale.ps1` (parameters default to US/Pacific):

```powershell
powershell -ExecutionPolicy Bypass -File set_locale.ps1 `
  -TimeZoneId "Pacific Standard Time" -GeoId 244 -Culture en-US -LanguageList en-US
```

It sets timezone (and **disables "set timezone automatically"** so it can't drift back), regional format, GeoID/country, the user language list, system locale, the display-language override, and starts + syncs the time service. Timezone, system locale, and time service need **admin** (the script detects and warns); system locale and display language need a **reboot** to fully apply.

### Phase 3 — Align the browser

This is the step people miss. The browser ships its own language independent of the OS. Run `scripts/fix_browser_language.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File fix_browser_language.ps1 -AcceptLanguages "en-US,en"
```

It closes the browser cleanly (and *confirms* it's closed before editing — editing the profile while the browser runs corrupts it), then sets `intl.accept_languages` in Chrome/Edge `Preferences` and `app_locale` in `Local State`. After this, `navigator.language` / `Accept-Language` are locked to the target regardless of the OS display language.

### Phase 4 — Audit and verify (the payoff)

Run the full read-only audit, then the live browser fingerprint:

```powershell
powershell -ExecutionPolicy Bypass -File audit_windows.ps1 `
  -ExpectTimeZone "Pacific Standard Time" -ExpectGeoId 244 -ExpectLang en-US -ExpectExitIp 203.0.113.10
powershell -ExecutionPolicy Bypass -File fp_check.ps1 -ExpectTimeZone America/Los_Angeles -ExpectLang en-US
```

`audit_windows.ps1` prints every signal with a PASS/FAIL against the expected identity. `fp_check.ps1` launches a headless browser and reports the **actual** `navigator.language`, `navigator.languages`, `Intl` timezone, and `navigator.webdriver` — this is ground truth for "what the website sees." The goal is all-green with this rule holding:

> **IP region == OS timezone == browser timezone == browser language region, and exit_ipv6 is empty, and navigator.webdriver is false.**

Then have the user reopen their real browser and confirm on a leak-test page (`browserleaks.com/ip`, or their preferred one) — the live human check is the final word.

## Running the scripts

- **On the machine itself:** run each `.ps1` directly in PowerShell as described above. The `.sh` runs on the Linux gateway.
- **Driving a guest VM remotely** (e.g. a Parallels VM from the Mac host): the delivery has sharp edges — `prlctl exec` silently drops some args, the remote shell is zsh, and `powershell -Command -` mishandles multi-line blocks. **Read `references/remote-execution.md` before running anything remotely** — it gives the reliable patterns (deliver the `.ps1` via stdin to `cat > file`, run with `-File`; use no-`--current-user` for SYSTEM/admin; etc.). The scripts are written to be run as files precisely to sidestep these.

## Severity — where to spend effort

Not all signals are equal. In rough order of how reliably they get an account flagged:

1. **`navigator.webdriver = true` / headless UA** — near-instant flag. If present, nothing else matters. Never drive the account's browser with Selenium/CDP/`--remote-debugging`; use it normally.
2. **Real-IP leak** (WebRTC / IPv6 / DNS escaping the proxy) — exposes the actual location; defeats the whole point. The fail-closed gateway prevents this structurally.
3. **Timezone vs IP mismatch** — strong, cheap-to-detect signal. Always fix.
4. **Browser language vs IP mismatch** — the most commonly-missed one. Always fix (Phase 3).
5. **OS locale / region / clock** — weaker on their own but cheap to align; they round out consistency.

## Honest caveats — always tell the user

- This removes **technical** red flags (inconsistency, leaks, automation markers). It is **not** a guarantee against bans.
- Account safety also depends on **behaviour and account hygiene** — registration info, payment method, not sharing/multi-opening accounts, human-like usage. State plainly that this skill does not cover those.
- If you had to force-close or edit a browser profile, **tell the user what changed** (e.g. site permissions may reset; bookmarks/passwords/cookies live in separate files and are preserved). Be honest about any disruption.
