# claude-anti-ban

A [Claude Code](https://docs.claude.com/en/docs/claude-code) **skill** for configuring and auditing a
machine (typically a VM or remote box behind a proxy/VPN) so that its *observable identity is
self-consistent* and it *leaks nothing about its real location*.

The goal is honest consistency, not evasion: a real person in California has a California IP, a Pacific
clock, and an `en-US` browser. Anti-abuse systems flag sessions whose layers **contradict each other**
(the classic: a US exit IP with a China timezone and a Chinese browser language) and sessions that **leak
the real IP** (WebRTC / IPv6 / DNS) or **declare automation** (`navigator.webdriver`). This skill makes
every layer agree with the proxy's exit region, removes the leak paths, and then **audits** for anything
left over.

## What it aligns / checks

| Signal | Aligned to |
|---|---|
| Exit IP geolocation | the proxy node |
| OS timezone + browser `Intl` timezone | the exit region |
| Browser language (`navigator.language` / `Accept-Language`) | the exit region — **set in the browser, not the OS** |
| OS locale / region / country / clock | the exit region |
| WebRTC / IPv6 / DNS leaks | none (forced through the proxy) |
| `navigator.webdriver` / headless UA | clean (no automation) |

The most commonly-missed trap: **the browser language does not follow the OS language.** You can set
Windows to English and the browser still sends `Accept-Language: zh-CN`. This skill fixes that explicitly.

## Layout

```
claude-anti-ban/
├── SKILL.md                       # the model + a 4-phase workflow + pass criteria + honest caveats
├── scripts/
│   ├── audit_windows.ps1          # read-only ban-risk audit -> PASS/FAIL per signal
│   ├── fp_check.ps1               # live headless-browser fingerprint (navigator.language / tz / webdriver)
│   ├── set_locale.ps1             # align OS timezone/locale/region/language to a target region
│   ├── fix_browser_language.ps1   # lock Chrome/Edge accept_languages (the missed step)
│   └── gateway_audit.sh           # audit a Linux proxy gateway + fail-closed kill-switch test
└── references/
    ├── ban-signals.md             # full signal checklist (severity, detection, fix) + region lookup table
    ├── proxy-gateway.md           # a fail-closed TPROXY gateway (xray + nftables) that can't leak
    └── remote-execution.md        # gotchas when driving a guest VM remotely (Parallels/prlctl/PowerShell)
```

## Install

Drop the folder into your Claude Code skills directory:

```bash
git clone https://github.com/Zijie-Tian/claude-anti-ban.git ~/.claude/skills/claude-anti-ban
```

Claude Code will pick it up automatically. Then just describe the task — e.g. *"audit my Windows VM behind
a US proxy for anything that could get my account banned"* — and the skill triggers.

## Quick use (PowerShell on Windows)

```powershell
# 1. align the OS to the exit region (admin needed for timezone/locale; reboot to finish)
powershell -ExecutionPolicy Bypass -File scripts/set_locale.ps1 -TimeZoneId "Pacific Standard Time" -GeoId 244 -Culture en-US -LanguageList en-US

# 2. lock the browser language (the step people forget)
powershell -ExecutionPolicy Bypass -File scripts/fix_browser_language.ps1 -AcceptLanguages "en-US,en"

# 3. audit + verify the live fingerprint
powershell -ExecutionPolicy Bypass -File scripts/audit_windows.ps1 -ExpectExitIp 203.0.113.10
powershell -ExecutionPolicy Bypass -File scripts/fp_check.ps1 -ExpectTimeZone America/Los_Angeles -ExpectLang en-US
```

Scripts are parameterized; defaults target **US / Pacific**. For other regions change
`-TimeZoneId / -GeoId / -Culture / -LanguageList` (see the lookup table in `references/ban-signals.md`).

> Example commands use the documentation IP `203.0.113.10` (RFC 5737). Substitute your node's real exit IP.

## Validated

Every script was run end-to-end against a real Parallels Windows VM behind a Linux TPROXY gateway:
Windows audit **10/10**, live browser fingerprint **4/4**, gateway audit **10/10**. The audit even caught a
real drift (regional format silently reset by a display-language reboot), which is exactly its job.

## Scope & intent

This is about the **regional/identity consistency and leak-hygiene of a legitimately proxied machine** —
useful for privacy, for running a service in the region you actually pay a proxy to exit from, and for not
tripping naive "your IP and your timezone disagree" heuristics. It is **not** a tool for fraud,
multi-accounting, or bypassing a service's security controls, and it offers **no guarantee** against bans:
account standing also depends on registration, payment, and human-like usage, which are out of scope here.
Use it on machines and accounts you own, in line with the terms of the services you use.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
