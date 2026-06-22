# Parallels VM: host-isolation hardening & platform limits

Notes for when the proxied machine is a Parallels Desktop VM on a Mac. These came from a real setup
and matter both for keeping the VM self-contained and for knowing what simply *cannot* work.

## Force the guest to use ONLY its own software (not the host's apps)

By default Parallels **shares applications both ways**: Mac apps appear in the Windows Start menu
(e.g. an entry literally named "Claude (Mac)", plus URL-handler entries like "Claude Code URL Handler
(Mac)") and Windows apps appear on the Mac. That blurs the isolation boundary — a click or a
`claude://`-style URL in the guest can launch the **host's** copy of the app, which defeats the point
of a contained, separately-proxied VM (the host's app has the host's identity/network).

Turn sharing off (host VM can stay running; takes full effect after the guest restarts):

```bash
prlctl set "<vm>" --sh-app-host-to-guest off   # stop HOST apps appearing/launching in the guest  <-- the key one
prlctl set "<vm>" --sh-app-guest-to-host off    # stop GUEST apps appearing on the host (symmetry)
```

Verify from inside the guest that the host's entries are gone (PowerShell) — only the guest's own copy
should remain:

```powershell
(Get-StartApps | Where-Object {$_.Name -match 'YourAppName'}).Name
# e.g. should print "Claude" (the guest's own), NOT "Claude (Mac)"
```

For a fully sealed sandbox (also cuts clipboard, drag-and-drop, shared folders, shared user profile):

```bash
prlctl set "<vm>" --isolate-vm on
```

Use the targeted `--sh-app-*` toggles if you still want clipboard/folder convenience; use
`--isolate-vm on` if you want maximum isolation.

## Limitation: Claude's Cowork / "workspace" CANNOT run in a Parallels VM on Apple Silicon

Claude Desktop's **Cowork / "workspace"** sandbox boots a **Hyper-V micro-VM** — the app ships a
`smol-bin.arm64.vhdx` (a Hyper-V virtual disk) and references the **Windows Hypervisor Platform
(WHPX)** and Hyper-V. Running a hypervisor *inside* a guest requires **nested virtualization**, and:

> **Parallels Desktop's nested virtualization is Intel-only.** Per the current Parallels Developer
> Guide: *"This functionality is only available on Intel Macs, provided that the host virtual machine
> is configured to use the Parallels Hypervisor."* It is **not available on Apple Silicon (M1/M2/M3/M4).**

So on an Apple Silicon Mac, Cowork keeps showing *"Virtualization is not available — enable
virtualization in your computer's BIOS/UEFI settings, then restart"* no matter what you change inside
the guest. Specifically:

- **Windows 11 Pro is necessary but NOT sufficient.** Cowork does need Pro (Home's Hyper-V is
  incomplete), but the real blocker is the Mac/Parallels layer, not the Windows edition.
- The Parallels **`Nested virtualization` toggle** (`<VirtualizedHV>` in the VM's `config.pvs`) is a
  **legacy Intel field that is inert on ARM** — setting it to `1` makes `prlctl list --info` report
  "Nested virtualization: on", but it does nothing. Tell-tale: the ARM VM's CPU line still says
  "VT-x" (an Intel concept). `prlctl set` has no nested-virt flag; it's a GUI checkbox / config value —
  moot here either way.

### What works instead on Apple Silicon (in order of preference)

1. **Use Claude Code (CLI) inside the VM.** It does not need Hyper-V / Cowork's micro-VM, so it runs in
   the fully isolated + proxied + region-consistent VM this skill builds, with everything intact.
2. **Run Cowork on the Mac host.** The Mac is the hypervisor host (Apple Virtualization framework), so
   Cowork works there; you then proxy + region-align the Mac instead of the VM.
3. **Run it on a real Linux box** (bare metal, or a cloud instance that exposes nested KVM) where
   hardware virtualization is genuinely available; proxy/localize that box.

### Sources
- Parallels Developer Guide — *Nested Virtualization Support* (Intel Macs only):
  https://docs.parallels.com/parallels-desktop-developers-guide/software-development-specific-functions-of-parallels-desktop/nested-virtualization-support
- Parallels KB 116239 — *Nested Hyper-V support*: https://kb.parallels.com/en/116239
- Parallels KB 129497 — *Limitations of Windows 11 on Apple silicon*: https://kb.parallels.com/129497
- Claude Code issue #29532 — Cowork "Virtualization is not available": https://github.com/anthropics/claude-code/issues/29532
