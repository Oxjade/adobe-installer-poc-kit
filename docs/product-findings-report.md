# Security Assessment — Adobe Acrobat DC 26.003.22110 (Installed Product)

**Scope:** installed product payload shipped by `AcroRdrDCx642600322110_en_US.exe`
**Base payload:** Acrobat **21.001.20135** (2021) + **CEF/Chromium 101**
**Patch:** `AcroRdrDCx64Upd2600322110.msp` — 729 MB delta patch to **26.003.22110**
**Installer findings:** see the separate installer report (14 active findings)

> **Critical caveat:** the `Core.cab`/`AcroPro.msi` base is **21.001.20135**, and the
> MSP applies **delta patches** (`PA19`) to reach 26.003. The final 26.003 binaries
> cannot be reconstructed offline; findings below are **static leads on the base**
> and must be confirmed against the **installed 26.003 files** (collector included).

---

## 1. Method

PE inventory (343 PEs), signatures/mitigations, MSI/MSP table analysis,
service/IPC/DLL-load review, registry/update-channel mapping, string/URL/secret
mining, and targeted disassembly of the updater, ARM service, brokers, native
messaging host, and installer custom actions.

---

## 2. Findings (leads)

| ID | Title | Potential severity | Status |
|---|---|---|---|
| **P6** | MSI SecureCustomProperties → HKCR COM/preview/shell/broker path injection | **Critical/High** | Static lead; needs dynamic |
| **P7** | Update-URL property injection (`ManifestURL*`, `WebRcscManifestURL*`, `ARM_Update*`) → HKLM ARM | **High** | Static lead |
| **P9** | UWP/AppX sideload properties (`SIDELOADING_PREF`, `UWP_APP_*`) → elevated AppX install | **High/Medium** | Static lead |
| **P2** | `WebMsiPath` consumed by SYSTEM updater (`adobearm`) `/ArmUpdate /EXE|/MSI|/7Z` | **High/Critical** | Static lead |
| **P1** | SYSTEM updater uses predictable `C:\Windows\Temp\ArmUI.ini` | **High** | Static lead |
| **P10** | IE ElevationPolicy for `AdobeARM.exe` (low-integrity IE → updater) | **Medium/High** | Static lead |
| **P8** | Fixed named pipes (`32B6B37A`, `AIPC_SRV`, `adobe_crclient_`) | **Medium/High** | Static lead |
| **P3** | `armsvc` (LocalSystem) can create services / launch processes | **Medium/High** | Static lead |
| **P4** | Chrome native-messaging host + manifest (HKLM), HKCU override risk | **Medium** | Static lead |
| **P5** | Predictable `C:\temp\*Data.txt` paths in `Acrobat.dll` | **Low/Medium** | Static lead |
| **P11** | `HKCU\...\Adobe Synchronizer\...\CredentialsV4` registry key | **Low** | Static observation |
| **P12** | Permission custom actions (`FixFilePermissions`, `LockFilePermissions`) | Review | No finding yet |
| **P13** | Unsigned media/plugin modules (`Flash.mpp`, `ccme_*`, `*.pmp`, `*.x3d`) | Low/Medium | Review |
| **P14** | Base components are 2021/CEF 101 (patched by MSP) | Info | Collect installed |

---

## 3. High-value details

### P6 — MSI property injection into COM / preview / shell registration (Critical/High lead)

`AcroPro.msi` exposes these in `SecureCustomProperties` and writes them into
**HKCR** (`Root=0`, per-machine → `HKLM\Software\Classes`):

| Property | Registry use |
|---|---|
| `PDF_PREVIEW_HANDERLER_DLL` | `CLSID\{17F2E344-...}\InProcServer32`, `CLSID\{DC6EFB56-...}\InprocServer32`, `TypeLib\{0F6D3808-...}\win32` |
| `PDF_ACROBROKER_PATH` | `CLSID\{BD57A9B2-...}\LocalServer32` = `"[PDF_ACROBROKER_PATH]"` |
| `PDFSHELL_LOCALSERVER_COMMAND` | `CLSID\{D38406DA-...}\LocalServer32`, `CLSID\{98D9A6F1-...}\LocalServer32` |
| `PDF_INPROCSERVER_VIEWERPS` | `CLSID\{12BA069D-...}\InProcServer32` |

If a caller can override these public MSI properties (command line/`/msi` args /
`setup.ini CmdLine`), the **elevated** installer registers an attacker‑chosen DLL
or EXE as a system‑wide COM/preview/shell/broker server. That yields code
execution in Explorer/preview/COM clients and, where a privileged client loads
the server, local privilege escalation.

Chain: ACRO‑03 (setup.ini `CmdLine=`)/ACRO‑04 (`/msi` args) → elevated msiexec
with `PDF_PREVIEW_HANDERLER_DLL=C:\attacker\evil.dll` → HKCR registration.
**Verify:** whether installer custom actions (`SetCustomInstallerProperties`/
`CollectProperties`) overwrite command‑line overrides.

### P7 — Update-URL property injection (High lead)

`ManifestURL`, `ManifestURL2`, `ManifestURL3`, `WebRcscManifestURL*`,
`ARM_Update*`, `ARMOnDemand_Redirection` are public MSI properties written to
`HKLM\SOFTWARE\Adobe\Adobe ARM\...`. Overriding them on an elevated msiexec
command line points the update channel at an attacker URL. The updater imports
`WinVerifyTrust`/`MsiApplyPatch`, so the MSI signature/version checks are the
gate; the lead needs dynamic validation (including local `WebMsiPath`).

### P9 — UWP/AppX sideload property injection (High/Medium lead)

`SIDELOADING_PREF`, `INSTALLUWPAPP`, `UWP_APP_INSTALLER_NAME`,
`UWP_APP_PACKAGE_FULLNAME`, `UWP_APP_HKCU_REGKEY` are in
`SecureCustomProperties`; custom actions `EnableSideloadAppPref` /
`RestoreSideloadAppPref` / `installAppx` act on them. If overridable, the
elevated installer can install an attacker AppX and/or enable sideloading.

### P2 — `WebMsiPath` → SYSTEM updater (High/Critical lead)

`adobearm.exe` reads/writes `WebMsiPath` in **HKCU and HKLM**, logs
“Registered extracted web installer path”, and supports `/ArmUpdate /EXE|/MSI|/7Z`
plus `MsiApplyPatch`. The installer writes an attacker‑controlled `WebMsiPath`
(installer ACRO‑05). If the SYSTEM‑launched updater runs that package without
strict verification, it is SYSTEM code execution / persistent update hijack.

### P1 — `C:\Windows\Temp\ArmUI.ini` (High lead)

`adobearm.exe` (`InitUIStrings`) calls `GetFileAttributesW` on
`C:\Windows\Temp\ArmUI.ini`, uses an existing INI, and falls back to
`%CommonAppData%\Adobe\ARM`. If `C:\Windows\Temp` is user‑writable, a pre‑created
INI may influence the SYSTEM updater (UI/update configuration).

### P10 — IE ElevationPolicy (Medium/High lead)

MSI writes `HKLM\Software\Microsoft\Internet Explorer\Low Rights\ElevationPolicy\
{76E2369A-75BA-41F9-8B9E-16059E5CF9A6}` with `AppPath=[ARM_1.0]`,
`AppName=AdobeARM.exe`. A low‑integrity IE process can launch `AdobeARM.exe` at
medium integrity; combined with `ArmUpdateExe:` style arguments this is a
browser‑to‑updater elevation lead.

### P8 — Named pipes (Medium/High lead)

- `\\.\pipe\32B6B37A-4A7D-4e00-95F2-6F0BF3DE3E00` — created by `adobearm.exe`,
  `Acrobat.dll`, `AdobeCollabSync.exe`; used by the native host. `adobearm` may
  run as SYSTEM.
- `\\.\pipe\AIPC_SRV\...` — `_4bitmapibroker.exe` / `_32bitmapibroker.exe`.
- `\\.\pipe\adobe_crclient_` — `CRWindowsClientService.exe`.

Fixed names + `CreateNamedPipeW` in SYSTEM/medium components require DACL and
message‑protocol review (squatting, impersonation, command injection, info leak).

### P3 — `armsvc` (Medium/High lead)

`AdobeARMservice` = `armsvc.exe`, `SERVICE_WIN32_OWN_PROCESS`, auto‑start,
LocalSystem. Imports `CreateServiceW`, `OpenSCManagerW`, `ShellExecuteExW`,
`WinVerifyTrust`; builds a service command line (`ServiceParameters`,
`ELEVATE_ARM`). Verify the parameter source and ACL on 26.003.

### P4 — Chrome native messaging (Medium lead)

`manifest.json` (`com.adobe.acrobat.chrome_webcapture`, stdio) allows two Chrome
extension IDs, registered under **HKLM**. The host uses `ShellExecute`/
`CreateProcessW`, `GetTempPathW`, App Paths, `[url]`/`[filePath]`. A malicious
extension (or a user‑level HKCU manifest override) could reach it; verify message
validation in the 26.003 host.

### P5 — `C:\temp` data files (Low/Medium)

`Acrobat.dll` references `C:\temp\ReviewData.txt`, `SendAndTrackData.txt`,
`SignatureData.txt`. If `C:\temp` exists and is user‑writable, data leak or
overwrite is possible.

---

## 4. What is needed to confirm (next step)

Run the collector as Administrator on the Windows 11 partition after 26.003 is
installed:

```
powershell -ExecutionPolicy Bypass -File C:\poc-kit\scripts\Collect-Installed.ps1
```

It produces `C:\acrobat-collect.zip` with installed binaries (hashes/versions/
signatures), services, Adobe ARM registry, ACLs for `C:\Windows\Temp`/`C:\temp`/
ARM dirs, any `ArmUI.ini`, and native‑messaging manifests.

Then: confirm P6/P7/P9/P2/P1/P8/P10 on 26.003, build a minimal PoC for the
strongest chain, and report to Adobe PSIRT/bug bounty.

---

## 5. Evidence files

- `re/msi_analysis.txt` — ServiceInstall, Registry, CustomAction, Directory, File
- `re/product_pe_summary.txt` — 343 PEs, mitigations, signatures, versions
- `re/pipe_ipc_scan.txt` — named-pipe usage across the payload
- `re/product_urls.txt` — URL inventory (update/telemetry endpoints)
- `re/armsvc.asm`, `re/nativehost.asm` — targeted disassembly
- `msp/PCW_CAB_ACR.cab` / `re/msp_cab_listing.txt` — delta patch inventory
- `collect/Collect-Installed.ps1` — installed‑product collector
