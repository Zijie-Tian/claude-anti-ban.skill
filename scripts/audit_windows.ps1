<#
.SYNOPSIS
  Read-only ban-risk audit of a Windows machine. Prints every observable identity signal and
  a PASS/FAIL verdict against the expected (proxy-region) identity. Changes nothing.

.DESCRIPTION
  Checks the consistency rule:
      IP region == OS timezone == browser timezone == browser language region
  plus leak signals (IPv6, DNS) and automation readiness. Pair with fp_check.ps1 for the live
  browser fingerprint (this script reads config; fp_check.ps1 renders the real navigator values).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File audit_windows.ps1 `
    -ExpectTimeZone "Pacific Standard Time" -ExpectGeoId 244 -ExpectLang en-US -ExpectExitIp 203.0.113.10

.NOTES
  Run as a FILE (-File). If delivering to a Parallels guest, see references/remote-execution.md.
#>
[CmdletBinding()]
param(
  [string]$ExpectTimeZone = "Pacific Standard Time",
  [int]$ExpectGeoId       = 244,          # 244 = United States
  [string]$ExpectLang     = "en-US",
  [string]$ExpectExitIp   = "",           # optional; if set, the egress IP must equal it
  [int]$HttpTimeoutSec    = 20
)

$ErrorActionPreference = 'SilentlyContinue'
$pass = 0; $fail = 0
function Check($name, $cond, $got) {
  if ($cond) { $script:pass++; "  [PASS] {0,-26} {1}" -f $name, $got }
  else       { $script:fail++; "  [FAIL] {0,-26} {1}" -f $name, $got }
}
function Info($name, $val) { "  [info] {0,-26} {1}" -f $name, $val }

"=== ACCOUNT BAN-RISK AUDIT (Windows) ==="
"Expected identity: tz='$ExpectTimeZone'  geoid=$ExpectGeoId  lang=$ExpectLang  exitIP=$(if($ExpectExitIp){$ExpectExitIp}else{'(any)'})"
""

# ---- Timezone & clock -------------------------------------------------------
"-- Timezone / clock --"
$tz = (tzutil /g)
Check "timezone"           ($tz -eq $ExpectTimeZone) $tz
$off = [TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).ToString()
Info  "utc_offset"         $off
# tzautoupdate Start: 4 = Disabled (good; won't auto-revert to a location-based zone)
$tzauto = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate').Start
Check "auto-timezone OFF"  ($tzauto -eq 4) "Start=$tzauto (4=Disabled)"
Check "time service running" ((Get-Service w32time).Status -eq 'Running') ((Get-Service w32time).Status)
Info  "clock_now"          ((Get-Date).ToString('o'))

# ---- Locale / region --------------------------------------------------------
""
"-- Locale / region --"
$culture = (Get-Culture).Name
Check "regional format"    ($culture -eq $ExpectLang) $culture
Info  "ui culture"         (Get-UICulture).Name
Info  "system locale"      (Get-WinSystemLocale).Name      # needs reboot to change; informational
$geoid = (Get-WinHomeLocation).GeoId
Check "home country (GeoId)" ($geoid -eq $ExpectGeoId) $geoid
$langs = ((Get-WinUserLanguageList).LanguageTag -join ',')
Check "OS language list"   ($langs -like "$ExpectLang*") $langs

# ---- Network: single egress, no leaks --------------------------------------
""
"-- Network --"
$ipv4 = ((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object -Expand IPAddress) -join ',')
Info  "local IPv4"         $ipv4
$v6 = ((Get-NetIPAddress -AddressFamily IPv6 | Where-Object { $_.IPAddress -notlike 'fe80*' -and $_.IPAddress -ne '::1' } | Select-Object -Expand IPAddress) -join ',')
$v6disp = if ([string]::IsNullOrEmpty($v6)) { '(none)' } else { $v6 }
Check "no global IPv6"     ([string]::IsNullOrEmpty($v6)) $v6disp
$dns = ((Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | Select-Object -Expand ServerAddresses) -join ',')
Info  "DNS servers"        $dns

# ---- Egress identity --------------------------------------------------------
""
"-- Egress (through the proxy) --"
$exit4 = (& curl.exe --silent --max-time $HttpTimeoutSec https://api.ipify.org)
if ($ExpectExitIp) { Check "exit IPv4 == proxy" ($exit4 -eq $ExpectExitIp) $exit4 }
else               { Info  "exit IPv4"          $exit4 }
$exit6 = (& curl.exe --silent --max-time 8 https://api6.ipify.org)
$exit6disp = if ([string]::IsNullOrEmpty($exit6)) { '(none)' } else { $exit6 }
Check "no IPv6 egress"     ([string]::IsNullOrEmpty($exit6)) $exit6disp

# ---- Browser (config-level; fp_check.ps1 renders the live values) -----------
""
"-- Browser --"
$default = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice').ProgId
Info  "default browser"    $default
$chromePref = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Preferences"
if (Test-Path $chromePref) {
  $raw = [IO.File]::ReadAllText($chromePref)
  $acc = 'ABSENT (derives from OS display language = risky)'
  if ($raw -match '"accept_languages":"([^"]*)"') { $acc = $Matches[1] }
  Check "Chrome accept_languages" ($acc -like "$ExpectLang*") $acc
} else { Info "Chrome" "not installed / no profile" }
$edgePref = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Preferences"
if (Test-Path $edgePref) {
  $raw = [IO.File]::ReadAllText($edgePref)
  $acc = 'ABSENT'
  if ($raw -match '"accept_languages":"([^"]*)"') { $acc = $Matches[1] }
  Info "Edge accept_languages" $acc
}

# ---- Summary ----------------------------------------------------------------
""
"=== SUMMARY: $pass passed, $fail failed ==="
if ($fail -eq 0) {
  "All config-level checks consistent. Now run fp_check.ps1 to confirm the LIVE browser fingerprint,"
  "then verify on a leak-test page in the real browser."
} else {
  "FIX the [FAIL] items above. The most common offender is Chrome accept_languages (run fix_browser_language.ps1)."
}
"Reminder: navigator.webdriver must be false (fp_check.ps1) and the browser must never be driven by automation."
exit $fail
