<#
.SYNOPSIS
  Render the LIVE browser fingerprint a website would see: navigator.language, navigator.languages,
  Intl timezone, and navigator.webdriver. This is ground truth — config files can lie, this can't.

.DESCRIPTION
  Launches a headless Chrome (or Edge) against a tiny local page that prints the values into the DOM,
  and parses them back. Uses a throwaway --user-data-dir seeded with the target accept_languages and
  --disable-extensions, because:
    * a fresh profile derives its language from the OS *display* language (which may still be wrong),
      so to prove the explicit-pref path we seed the temp profile with the target;
    * headless on the REAL profile HANGS while loading extensions — never point it at the live profile.
  Timezone comes from the OS regardless of profile, so it reflects the machine's real timezone.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File fp_check.ps1 -ExpectTimeZone America/Los_Angeles -ExpectLang en-US

.NOTES
  To confirm the user's ACTUAL profile (not a seeded one), the reliable check is: set the real profile
  with fix_browser_language.ps1, then open the real browser and visit a leak-test page. Headless on the
  real profile is intentionally avoided here.
#>
[CmdletBinding()]
param(
  [string]$ExpectTimeZone = "America/Los_Angeles",
  [string]$ExpectLang     = "en-US",
  [string]$AcceptLanguages = "en-US,en",   # seeded into the temp profile to mirror the configured value
  [ValidateSet('chrome','edge')] [string]$Browser = 'chrome'
)

$ErrorActionPreference = 'SilentlyContinue'
$enc = New-Object System.Text.UTF8Encoding $false

# locate the browser binary
$candidates = if ($Browser -eq 'edge') {
  @("$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
} else {
  @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
}
$bin = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bin) { "ERROR: $Browser not found"; exit 2 }

# seed a throwaway profile with the target accept_languages
$prof = Join-Path $env:TEMP ("fpcheck_" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path (Join-Path $prof 'Default') | Out-Null
[IO.File]::WriteAllText((Join-Path $prof 'Default\Preferences'),
  ('{"intl":{"accept_languages":"' + $AcceptLanguages + '"}}'), $enc)

# tiny page that writes the fingerprint into the DOM
$page = Join-Path $env:TEMP 'fpcheck.html'
$html = '<html><body id=r>x</body><script>document.getElementById("r").textContent=' +
        '"FP|"+navigator.language+"|"+navigator.languages.join(",")+"|"+' +
        'Intl.DateTimeFormat().resolvedOptions().timeZone+"|"+navigator.webdriver</script></html>'
[IO.File]::WriteAllText($page, $html, $enc)
$url = 'file:///' + ($page -replace '\\','/')

$out = (& $bin --headless --disable-gpu --no-sandbox --no-first-run --no-default-browser-check `
         --disable-extensions --user-data-dir=$prof --profile-directory=Default `
         --dump-dom $url 2>&1 | Out-String)

Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue
Remove-Item -Force $page -ErrorAction SilentlyContinue

if ($out -notmatch 'FP\|([^|<]*)\|([^|<]*)\|([^|<]*)\|([^<]*)') {
  "ERROR: could not read fingerprint. Raw head:"; ($out.Substring(0, [Math]::Min(300, $out.Length))); exit 2
}
$lang = $Matches[1]; $langs = $Matches[2]; $tz = $Matches[3]; $wd = $Matches[4].Trim()

$pass = 0; $fail = 0
function Check($name, $cond, $got) {
  if ($cond) { $script:pass++; "  [PASS] {0,-22} {1}" -f $name, $got }
  else       { $script:fail++; "  [FAIL] {0,-22} {1}" -f $name, $got }
}

"=== LIVE BROWSER FINGERPRINT ($Browser) ==="
Check "navigator.language"  ($lang -eq $ExpectLang)              $lang
Check "navigator.languages" ($langs -like "$ExpectLang*")        $langs
Check "Intl timezone"       ($tz -eq $ExpectTimeZone)            $tz
Check "navigator.webdriver" ($wd -eq 'false' -or $wd -eq '')     $wd
""
"=== $pass passed, $fail failed ==="
if ($fail -gt 0) { "Mismatch above. For language: run fix_browser_language.ps1. For timezone: run set_locale.ps1 (+reboot)." }
exit $fail
