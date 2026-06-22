<#
.SYNOPSIS
  Align a Windows machine's timezone, locale, region/country, and language to a target region so it
  matches the proxy's exit IP. Defaults to US / Pacific.

.DESCRIPTION
  Per-user settings (culture, GeoID, language list, display-language override) apply without admin but
  take effect for NEW processes / next sign-in. Machine settings (timezone, system locale, time service)
  require ADMIN — the script detects elevation and tells you what to do if it's missing. It also DISABLES
  "set time zone automatically" so location services can't drift the zone back.

  Elevation on a Parallels guest: run `prlctl exec "<vm>" powershell ...` WITHOUT --current-user to run as
  SYSTEM (elevated). See references/remote-execution.md.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File set_locale.ps1 `
    -TimeZoneId "Pacific Standard Time" -GeoId 244 -Culture en-US -LanguageList en-US

.NOTES
  Reboot afterwards: system locale and display language only fully apply after a restart, and running
  apps (browser!) cache timezone+language at launch — restart them or reboot.
#>
[CmdletBinding()]
param(
  [string]$TimeZoneId   = "Pacific Standard Time",   # tzutil ID; covers PST/PDT with DST
  [int]$GeoId           = 244,                        # 244 = United States (Get-WinHomeLocation GeoIDs)
  [string]$Culture      = "en-US",
  [string]$LanguageList = "en-US",
  [string]$NtpPeers     = "time.windows.com,0x9"
)

$ErrorActionPreference = 'Continue'
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
"Elevated: $elevated"

# ---- per-user (no admin needed) --------------------------------------------
try { Set-Culture $Culture;                              "OK  regional format -> $Culture" } catch { "ERR culture: $($_.Exception.Message)" }
try { Set-WinHomeLocation -GeoId $GeoId;                 "OK  home country  -> GeoId $GeoId" } catch { "ERR geoid: $($_.Exception.Message)" }
try { Set-WinUserLanguageList -LanguageList $LanguageList -Force; "OK  language list -> $LanguageList" } catch { "ERR langlist: $($_.Exception.Message)" }
try { Set-WinUILanguageOverride -Language $LanguageList; "OK  display-lang override -> $LanguageList (next sign-in)" } catch { "ERR uioverride: $($_.Exception.Message)" }

# ---- machine settings (need admin) -----------------------------------------
if ($elevated) {
  & tzutil /s $TimeZoneId; "OK  timezone -> $TimeZoneId (now: $(tzutil /g))"
  # disable "set time zone automatically" so it can't revert to a location-derived zone
  Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate' -Name Start -Value 4
  "OK  auto-timezone DISABLED (Start=4)"
  Set-Service -Name w32time -StartupType Automatic; Start-Service -Name w32time
  & w32tm /config /manualpeerlist:$NtpPeers /syncfromflags:manual /update | Out-Null
  & w32tm /resync /force | Out-Null
  "OK  time service started + resynced (status: $((Get-Service w32time).Status))"
  try { Set-WinSystemLocale -SystemLocale $Culture; "OK  system locale -> $Culture (REBOOT to apply)" } catch { "ERR syslocale: $($_.Exception.Message)" }
} else {
  ""
  "!! NOT ELEVATED — skipped timezone / system locale / time service."
  "!! Re-run from an elevated PowerShell (Run as administrator), or on a Parallels guest run via"
  "!!   prlctl exec ""<vm>"" powershell -NoProfile -ExecutionPolicy Bypass -File <thisfile>   (no --current-user => SYSTEM)"
}

""
"Done. REBOOT recommended (system locale + display language need it; the browser caches tz+lang at launch)."
"Then verify with: audit_windows.ps1 and fp_check.ps1"
"NOTE: applying the display-language override + reboot can RESET the regional format (Get-Culture) back to"
"the system default. If audit_windows.ps1 then flags 'regional format', just re-run 'Set-Culture $Culture'"
"(per-user, no admin, no reboot) — verified in practice. The audit is your safety net for this."
