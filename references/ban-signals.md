# Ban-risk signals — full detection checklist

Each signal below: **what it is**, **severity**, **how to check**, **how to fix**. Severity is how
reliably a mismatch/leak gets an account flagged. Work top-down.

The governing rule for the consistency signals:

> **IP region == OS timezone == browser timezone == browser language region.**
> Plus: no real-IP leak, accurate clock, no automation flag.

---

## 1. Automation markers — severity: CRITICAL (instant flag)

- **navigator.webdriver = true** — set when the browser is driven by Selenium/Playwright/CDP or launched
  with `--enable-automation`. It is a self-declaration of "I am a bot."
  - Check: `fp_check.ps1` (reports `navigator.webdriver`), or in console `navigator.webdriver`.
  - Fix: do not automate the account's browser. Use it normally. If a tool launched it with automation
    flags, stop using that tool for this account.
- **Headless / unusual user-agent** — `HeadlessChrome/...` in the UA, or a UA that doesn't match the OS.
  - Check: `navigator.userAgent`.
  - Fix: use the real, non-headless browser.

## 2. Real-IP leaks — severity: CRITICAL (defeats the proxy)

- **WebRTC (STUN)** — JS can open a peer connection; the STUN reflexive candidate reveals the public IP.
  - Safe-by-construction if the machine has *no* direct path (everything, incl. UDP, is forced through the
    gateway) — then STUN sees the node IP, consistent. Local host candidates are private IPs (harmless;
    modern Chrome also mDNS-obfuscates them).
  - Check: a WebRTC leak-test page; confirm it shows the node IP, not the real one.
  - Fix: force UDP through the proxy (the TPROXY gateway does this), or disable WebRTC.
- **IPv6** — many proxies are IPv4-only; if the OS has working IPv6 it bypasses the proxy entirely.
  - Check: `curl https://api6.ipify.org` (should be empty/fail); `audit_windows.ps1` "no IPv6 egress".
  - Fix: disable IPv6 on the client NIC and/or block it at the gateway. The gateway in
    `proxy-gateway.md` hands out IPv4-only DHCP and drops forwarded IPv6.
- **DNS leak** — DNS queries going to the local ISP resolver reveal activity/region.
  - Check: a DNS-leak test page.
  - Fix: send DNS through the proxy (TPROXY catches UDP 53). Note: using a public resolver (1.1.1.1) *through
    the proxy* is fine — the leak-test will show the resolver's egress (e.g. Cloudflare), not your real IP.
    That is expected and not a deanonymization.

## 3. Timezone vs IP — severity: HIGH

- The browser's `Intl` timezone follows the **OS timezone**. A US IP with an Asia timezone is a glaring
  mismatch.
  - Check: `tzutil /g` (OS); `fp_check.ps1` (browser `Intl` timezone); they must agree and match the IP region.
  - Fix: `set_locale.ps1 -TimeZoneId "<id>"` (needs admin). Also **disable auto-timezone** so location
    services can't move it (the script sets `tzautoupdate` Start=4). Reboot or restart the browser — running
    apps cache the timezone at launch.

## 4. Browser language vs IP — severity: HIGH (most commonly missed)

- `navigator.language` / `navigator.languages` / the `Accept-Language` header come from the **browser's own**
  `intl.accept_languages`, **not** the OS language. Fixing the OS to en-US does NOT change this — the browser
  keeps sending its installed language until you set it explicitly.
  - Check: `fp_check.ps1`; or read `intl.accept_languages` from the browser `Preferences` file
    (`audit_windows.ps1` does this).
  - Fix: `fix_browser_language.ps1 -AcceptLanguages "en-US,en"`. Must be done with the browser closed.

## 5. OS locale / region / country — severity: MEDIUM

- Regional format (date/number/currency), home country (GeoID), language list. Rarely web-visible on their
  own but they round out a consistent machine and feed defaults (a fresh browser profile derives its language
  from the OS display language).
  - Check: `Get-Culture`, `Get-WinHomeLocation`, `Get-WinUserLanguageList`, `Get-WinSystemLocale`.
  - Fix: `set_locale.ps1`. System locale + display language need a reboot.

## 6. Clock accuracy — severity: MEDIUM

- A wrong clock breaks TLS/auth and is itself a risk signal.
  - Check: `Get-Date` vs real time; `w32time` running.
  - Fix: `set_locale.ps1` starts and resyncs the time service (admin).

## 7. Lower-risk / informational

- **VM artifacts** (hypervisor hardware strings) — most services don't deep-VM-detect; low priority.
- **Canvas / WebGL / fonts** — a fingerprint, but not region-inconsistent; installed CJK fonts are common
  worldwide. Generally not worth altering.
- **Computer name** — a neutral name (e.g. `PD04`) is fine; a name in the wrong language is a faint signal.

---

## Region → settings lookup

| Region | tzutil ID | UTC offset | GeoID | language |
|---|---|---|---|---|
| US Pacific (CA/WA) | `Pacific Standard Time` | −8/−7 | 244 | en-US |
| US Eastern (NY) | `Eastern Standard Time` | −5/−4 | 244 | en-US |
| US Central | `Central Standard Time` | −6/−5 | 244 | en-US |
| UK | `GMT Standard Time` | 0/+1 | 242 | en-GB |
| Germany | `W. Europe Standard Time` | +1/+2 | 94 | de-DE |
| Japan | `Tokyo Standard Time` | +9 | 122 | ja-JP |
| Singapore | `Singapore Standard Time` | +8 | 215 | en-SG |

Windows timezone IDs cover DST automatically (e.g. `Pacific Standard Time` is PST in winter, PDT in summer).
Look up the exit IP's city on the leak-test page to pick the right row. Full GeoID list:
`Get-WinHomeLocation` docs / `[System.Globalization.RegionInfo]`.
