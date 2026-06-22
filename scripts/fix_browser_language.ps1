<#
.SYNOPSIS
  Lock a Chromium browser's web-facing language (navigator.language / navigator.languages /
  Accept-Language) to a target, independent of the OS display language.

.DESCRIPTION
  navigator.language follows the browser's own intl.accept_languages, NOT the OS. On a machine whose
  display language is still (say) Chinese, the browser keeps sending zh-CN even after the OS is set to
  en-US. This sets intl.accept_languages in Preferences and app_locale in Local State explicitly.

  Hard-won safety rules baked in:
    * The browser MUST be fully closed before editing its profile, or it overwrites your change on exit
      AND you can truncate Preferences mid-write (corruption). This script kills it, waits, and CONFIRMS
      zero processes before touching anything; it aborts if it can't.
    * Do NOT use ConvertFrom-Json on a real Preferences file — it is deeply nested and can crash
      Windows PowerShell 5.1. We edit with a targeted regex that preserves the rest of the file.
    * Write UTF-8 WITHOUT BOM — a BOM makes Chrome treat Preferences as corrupt.

  User data (bookmarks, passwords, cookies, history, extensions) lives in SEPARATE files and is NOT
  touched. Only language settings change.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File fix_browser_language.ps1 -AcceptLanguages "en-US,en"

.NOTES
  -KillBrowser:$false makes it refuse to act if the browser is open (safer if the user is mid-session).
#>
[CmdletBinding()]
param(
  [string]$AcceptLanguages = "en-US,en",
  [string]$AppLocale       = "en-US",
  [ValidateSet('chrome','edge','both')] [string]$Browser = 'chrome',
  [bool]$KillBrowser = $true
)

$ErrorActionPreference = 'SilentlyContinue'
$enc = New-Object System.Text.UTF8Encoding $false

function Set-AcceptLanguages([string]$file, [string]$value) {
  # idempotent, structure-preserving injection of intl.accept_languages
  if (-not (Test-Path $file)) { return "  (no Preferences file) $file" }
  $raw = [IO.File]::ReadAllText($file)
  if ($raw.Length -lt 2 -or $raw[0] -ne '{') { $raw = '{}' }   # repair an empty/corrupt file
  if ($raw -match '"accept_languages":"[^"]*"') {
    $new = $raw -replace '"accept_languages":"[^"]*"', ('"accept_languages":"' + $value + '"')
  } elseif ($raw -match '"intl":\{') {
    $new = $raw -replace '"intl":\{', ('"intl":{"accept_languages":"' + $value + '",')
  } elseif ($raw -eq '{}') {
    $new = '{"intl":{"accept_languages":"' + $value + '"}}'
  } else {
    $new = $raw -replace '^\{', ('{"intl":{"accept_languages":"' + $value + '"},')
  }
  [IO.File]::WriteAllText($file, $new, $enc)
  $chk = [IO.File]::ReadAllText($file)
  if ($chk -match '"accept_languages":"([^"]*)"') { "  set accept_languages = $($Matches[1])  ($file)" }
  else { "  FAILED to set accept_languages ($file)" }
}

function Set-AppLocale([string]$localState, [string]$value) {
  if (-not (Test-Path $localState)) { return "  (no Local State) $localState" }
  $raw = [IO.File]::ReadAllText($localState)
  if ($raw.Length -lt 2 -or $raw[0] -ne '{') { return "  (Local State unreadable) $localState" }
  if ($raw -match '"app_locale":"[^"]*"')      { $new = $raw -replace '"app_locale":"[^"]*"', ('"app_locale":"' + $value + '"') }
  elseif ($raw -match '"intl":\{')             { $new = $raw -replace '"intl":\{', ('"intl":{"app_locale":"' + $value + '",') }
  else                                         { $new = $raw -replace '^\{', ('{"intl":{"app_locale":"' + $value + '"},') }
  [IO.File]::WriteAllText($localState, $new, $enc)
  "  set app_locale = $value  ($localState)"
}

function Fix-One([string]$procName, [string]$userData) {
  "== $procName =="
  $running = (Get-Process $procName | Measure-Object).Count
  if ($running -gt 0) {
    if (-not $KillBrowser) { "  ABORT: $procName is running and -KillBrowser:`$false. Close it and re-run."; return }
    "  closing $procName ($running procs) — its tabs restore on next launch"
    Stop-Process -Name $procName -Force; Start-Sleep -Seconds 3; Stop-Process -Name $procName -Force; Start-Sleep -Seconds 2
  }
  $still = (Get-Process $procName | Measure-Object).Count
  if ($still -ne 0) { "  ABORT: $procName still has $still processes; not editing (would corrupt)."; return }
  Set-AppLocale (Join-Path $userData 'Local State') $AppLocale
  Set-AcceptLanguages (Join-Path $userData 'Default\Preferences') $AcceptLanguages
}

if ($Browser -eq 'chrome' -or $Browser -eq 'both') {
  Fix-One 'chrome' "$env:LOCALAPPDATA\Google\Chrome\User Data"
}
if ($Browser -eq 'edge' -or $Browser -eq 'both') {
  Fix-One 'msedge' "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
}

""
"Done. Reopen the browser; verify with fp_check.ps1, then on a leak-test page in the real browser."
"Note: the browser's UI menus may still be in the OS display language — that is cosmetic and NOT visible to websites."
