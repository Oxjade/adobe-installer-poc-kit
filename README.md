# Adobe Acrobat Installer — Authorized PoC Kit

Native-Windows proof-of-concept harness for the findings in `report.md`
(`AcroRdrDCx642600322110_en_US.exe`, Adobe Acrobat Reader DC 26.003.22110).

**Authorized testing only.** Run this on hardware you own, ideally after taking a
snapshot/backup. The tests launch the *real* installer (elevated), which may
change system state. The kit tries to stop it early, and includes cleanup, but
you accept the risk.

---

## Reports

- [Installer assessment (PDF)](docs/Adobe-Acrobat-Installer-Assessment.pdf)
- [Installed-product assessment 26.003 (PDF)](docs/Adobe-Acrobat-Product-2600322110-Assessment.pdf)
- Markdown sources: `docs/findings-report.md`, `docs/product-findings-report.md`
- Rebuild: `python3 tools/md2pdf.py docs/findings-report.md docs/out.pdf "Title"` (needs `markdown` + `weasyprint`)


## Why native Windows

The PoCs need real UAC/integrity levels, the AppInfo elevation path, the SYSTEM
`armsvc`, real `msiexec`/Windows Installer semantics, NTFS hardlinks/reparse
points, and named pipes. Wine cannot provide these. This machine already has a
native Windows 11 Enterprise partition (EFI `Windows Boot Manager`), so the kit
is designed to run **there**, not in a VM/ISO.

---

## What it proves

| Test | Finding | What it does | CONFIRMED means |
|---|---|---|---|
| 01 | ACRO-02 | `Get-AuthenticodeSignature` on SFX + `setup.exe` | **REJECTED** — timestamp present (correction) |
| 02 | ACRO-08 | Parses `DllCharacteristics` | ASLR (`DYNAMIC_BASE`) absent |
| 03 | ACRO-01 | Sets `HKCU\Environment\CommonProgramW6432` to an attacker dir, runs SFX | elevated SFX created the attacker-path tree |
| 04 | ACRO-09 | Tries CLI output-folder switches against the SFX | a switch set `outputFolder_` / redirected `INSTALLPATH` |
| 05 | ACRO-03/14/04 | Feeds `setup.ini` (`msi=`, `CmdLine=`, `PATCH=`) to elevated `setup.exe`; also injects `/msi` property | attacker MSI installed elevated (`C:\poc-marker.txt` written) / injected property seen on msiexec command line |
| 06 | ACRO-10 | Tries pass-to-setup switches; reads AdobeSFX log | a switch set `passToSetup_` |
| 07 | ACRO-05 | Env override + polls HKLM/HKCU `Adobe ARM\1.0\ARM\WebMsiPath` | key set to attacker path |
| 08 | ACRO-06 | Creates `%TEMP%\AdobeSFX.log` hardlink/symlink to a target, runs SFX | target file modified by elevated process |
| 09 | ACRO-07 | Squats named pipe `\\.\pipe\32B6B37A-…`, runs SFX | elevated process connected and data was captured |

**P6 (product, separate):** `scripts/Test-10-MsiProp.ps1` — overrides the installer's
`SecureCustomProperties` (`PDF_PREVIEW_HANDERLER_DLL`, `PDF_ACROBROKER_PATH`,
`PDFSHELL_LOCALSERVER_COMMAND`, `PDF_INPROCSERVER_VIEWERPS`) and checks whether the
elevated MSI registers the attacker COM/preview/shell paths in HKCR. This is heavy:
it extracts the genuine payload and performs an Adobe install, then uninstalls.
Use it only on the authorized machine.

The MSI used by test 05 is **benign**: it installs a tiny `poc.exe` whose only
action is to write `C:\poc-marker.txt` (`PWNED: elevated MSI custom action
executed`) as a deferred, no-impersonate custom action (`Type 3154`). It is
built with `wixl`; source is `payload/poc.c`.

---

## Prerequisites

- Windows 11 Enterprise (the existing native install on this PC).
- PowerShell **as Administrator**.
- The target installer `AcroRdrDCx642600322110_en_US.exe`
  (SHA-256 `a7149f099dba2f868b65c2e4d62149fe411490fbb622192725fcc9ecfaa03852`)
  placed in the kit root, or passed via `-InstallerPath`.
- Network is not required.

### Getting the kit + installer onto Windows

From Kali (this host), the included helper mounts the NTFS volume and copies
both (requires sudo):

```bash
cd /path/to/poc-kit
sudo ./stage-to-windows.sh            # mounts /dev/nvme0n1p5, copies kit + installer
```

Or copy the folder and the installer to a USB drive / share, or push the git
repo/bundle to a remote and clone it on Windows. Do **not** commit the 720 MB
installer to git.

Note: if the Windows volume is BitLocker-encrypted, mount/copy will require the
recovery key. Fast Startup should be disabled before mounting NTFS read/write.

---

## Run

```powershell
# Elevated PowerShell
cd C:\poc-kit
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Run-All.ps1 -InstallerPath C:\poc-kit\AcroRdrDCx642600322110_en_US.exe
```

Useful options:

```powershell
# Fast, no-installer tests only (timestamp, ASLR)
.\scripts\Run-All.ps1 -SkipHeavy

# One finding (supports wildcards)
.\scripts\Run-All.ps1 -Only ACRO-03
.\scripts\Run-All.ps1 -Only 'ACRO-0*'
```

Results are written to `results\report.md` and `results\results.txt`; raw
evidence (process command lines, captured pipe data, staged trees) is in
`results\`.

Afterwards:

```powershell
.\scripts\Cleanup.ps1 -UninstallEvil
```

---

## P6 — MSI property injection (product, separate)

Prerequisites: the installer is in the kit root; run as Administrator; this does
a real (then uninstalled) Acrobat install and can take a long time.

```powershell
cd C:\poc-kit
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Test-10-MsiProp.ps1 -InstallerPath C:\poc-kit\AcroRdrDCx642600322110_en_US.exe
```

It first calls `Extract-Payload.ps1` (redirects `%CommonProgramW6432%`, ACRO‑01)
to obtain `AcroPro.msi`/`Core.cab`, then runs `msiexec` with the attacker
property overrides, checks HKCR `InProcServer32`/`LocalServer32`, activates the
COM CLSID, and looks for `C:\poc-p6-marker.txt`. Results: `P6-REG` and `P6-EXEC`.

## Interpretation

- `CONFIRMED` — the runtime behavior was observed in this environment.
- `UNCONFIRMED` — not observed (timeout, wrong switch spelling, needs ARM mode,
  or a check rejected the input). Inspect the corresponding log; the static
  finding may still stand.
- `REJECTED` — tested and disproven (e.g., ACRO-02 timestamp).
- `ERROR` — the test itself failed (see console).

Known limitations (by design, documented honestly):

- **Acrobat already installed** — if the product is already present, the SFX may report "already installed" and exit before extraction, making ACRO-01/05/06/07 inconclusive. Run on a clean Windows install or uninstall Acrobat first.

- **ACRO-09/10** — the exact internal switch spellings for `outputFolder_` and
  `passToSetup_` are not documented; the tests try likely candidates and fall
  back to `UNCONFIRMED`. Static data flow is in `report.md`.
- **ACRO-05** — the `WebMsiPath` write may occur only in Adobe ARM/xRDC mode; a
  normal launch may not trigger it.
- **ACRO-06** — the log link test runs in an elevated script, so it proves the
  link is followed/overwritten; the cross-user privilege boundary requires a
  standard-user attacker + admin-run installer, which is described in the
  report.
- **ACRO-07** — the fixed pipe may be a fallback sink and may not be used if the
  normal log file opens successfully.
- The installer is large (719 MB); tests 03/04/07/08/09 kill it as soon as the
  condition is observed to avoid a full 1.2 GB extraction/install.

---

## Safety & scope

- Use only on the authorized machine/target.
- Take a Windows restore point or snapshot first.
- The kit changes: `HKCU\Environment\CommonProgramW6432`, `%TEMP%` log/link,
  `HKLM/HKCU\SOFTWARE\Adobe\Adobe ARM\1.0\ARM\WebMsiPath` (restored), and may
  install the benign PoC MSI. `Cleanup.ps1` reverts these.
- Do not redistribute Adobe binaries (`setup.exe`) or the installer.
