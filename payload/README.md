# Payload notes

- `evil.msi` — minimal MSI (wixl 0.106) with a deferred, no-impersonate custom
  action (`Type 3154`, sequence 1501 after `InstallInitialize`) that runs the
  installed `poc.exe`. Benign: writes `C:\poc-marker.txt`.
- `poc.exe` / `poc.c` — tiny Win32 program (mingw-w64) that writes the marker.
  Source is included so you can rebuild it.
- `setup.ini` / `abcpy.ini` — originals extracted from the payload, for
  reference; test 05 generates its own attacker-controlled `setup.ini`.

Verify integrity:

```
sha256sum -c SHA256SUMS.txt      # Linux
Get-FileHash .\* -Algorithm SHA256   # Windows
```

`setup.exe` is **not** bundled; `Extract-Payload.ps1` extracts it (and
`AcroPro.msi`/`Core.cab`) from your installer at runtime.
