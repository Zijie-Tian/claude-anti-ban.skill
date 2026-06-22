# Driving a guest VM remotely (Parallels `prlctl`) — gotchas & reliable patterns

When you can't run scripts *on* the target but drive it from the hypervisor host (e.g. a Parallels VM on a
Mac, reached over SSH), the delivery layer has sharp edges. These cost real debugging time; use the patterns
below from the start.

## Reaching the guest

- `prlctl` is usually not on a non-interactive SSH PATH. Use the full path:
  `/usr/local/bin/prlctl` or `/Applications/Parallels Desktop.app/Contents/MacOS/prlctl`.
- No guest password needed (Parallels Tools):
  - **Linux guest:** `prlctl exec "<vm>" --current-user <cmd>` (as the user) or `--user root <cmd>`.
  - **Windows guest:** `prlctl exec "<vm>" --current-user <cmd>` runs as the **logged-in user (non-elevated)**.
    **Omit `--current-user`** and the command runs as **`nt authority\system` (elevated)** — this is how you
    set the timezone / system locale / time service without a UAC prompt. (Per-user settings like
    `Set-Culture`/language must still run `--current-user` so they land in the user's hive.)

## `prlctl exec` silently drops some arguments

A standalone `-d` is eaten (e.g. `base64 -d` runs as `base64` = encode), and bare numeric args have been
seen dropped (`sleep 15` → `sleep`). Don't pass fragile flags through `prlctl exec`'s own argv. Instead:

- **Write files into the guest via stdin**, not flags: pipe content to `... bash -lc "cat > /path"`
  (Linux) — `prlctl exec` forwards stdin to the guest. Verified reliable. Then run the file.
- Put multi-step logic in a **script file** and run the file; flags *inside* the file are safe (they don't
  go through `prlctl`'s argv).

## The host shell is zsh

`echo ===LABEL===` fails on the host (zsh `=`-expansion treats `===…` as a command). Use plain labels
(`echo STEP_A`) at the host/zsh level. Inside a guest `bash -lc "…"` it's bash, so `=` is fine there.

## Windows PowerShell over `prlctl`

- Run a script via stdin: `prlctl exec "<vm>" [--current-user] powershell -NoProfile -Command -`
  and feed the script on stdin (a heredoc). This avoids quoting hell — `$`, quotes, `()` all pass literally.
- **`powershell -Command -` breaks on multi-line `if(){ … }` blocks** delivered this way — the script
  silently stops partway (you'll see only the output before the block). Keep logic on **single lines**
  (inline `if(){}else{}` on one line is fine), OR — far better — deliver a **`.ps1` file and run it with
  `-File`**, where normal multi-line PowerShell works. The skill's scripts are written to be run with
  `-File` for exactly this reason.
- **`ConvertFrom-Json` on a real Chrome `Preferences`** (deeply nested) can crash PS 5.1 (uncatchable stack
  overflow). Edit such files with a **targeted regex**, not JSON round-trip.
- Write files **UTF-8 without BOM**:
  `[IO.File]::WriteAllText($p,$s,(New-Object System.Text.UTF8Encoding $false))`. A BOM makes Chrome treat
  `Preferences` as corrupt.

## Editing a running browser's profile = corruption

If you force-kill the browser and read/write `Preferences` during its shutdown write, you can truncate it
to 0 bytes. Always: kill → wait → **confirm zero processes** → then edit. Chrome self-heals a corrupt
`Preferences` (renames it `Preferences.bad`, rebuilds defaults) so user *data* survives (bookmarks,
passwords, cookies, history, extensions are separate files), but regular settings reset — tell the user.
`fix_browser_language.ps1` already does the confirm-closed dance.

## Headless browser checks hang on the real profile

Headless Chrome pointed at the live `--user-data-dir` hangs loading extensions. For a fingerprint read,
use a **throwaway `--user-data-dir`** seeded with the target `accept_languages`, plus
`--disable-extensions`. The OS timezone shows through regardless of profile. `fp_check.ps1` does this.

## "Direct" is blocked in proxy-only networks — test through the proxy

In environments where the host itself only reaches the internet via a proxy, a "direct" egress test
(`curl https://1.1.1.1`) will always time out — that's expected, not a fault. Validate egress **through the
proxy** (the gateway's own `curl ipify` returns the node IP), not by hitting an arbitrary direct address.

## Output got truncated?

`prlctl exec` can drop trailing output when the guest process exits quickly. If a command's tail is
missing but a write may have happened, **re-read the state** with a separate flat command rather than
assuming success or failure.
