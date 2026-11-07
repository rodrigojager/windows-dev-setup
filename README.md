# windows-dev-setup

Small, idempotent fixes for a Windows development machine. Each script can be run more than once and has an
`-Undo` switch.

| Script | What it fixes |
|---|---|
| `scripts/set-python-utf8.ps1` | Python crashing with `UnicodeEncodeError: 'charmap' codec…` / `UnicodeDecodeError` on accented text, emoji or box characters, because Windows Python defaults to the legacy code page (cp1252). Sets `PYTHONUTF8=1` for the current user, so Python uses UTF-8 for files and console I/O. |

## Use

```powershell
git clone <this repository>
cd windows-dev-setup
powershell -ExecutionPolicy Bypass -File .\scripts\set-python-utf8.ps1        # apply
powershell -ExecutionPolicy Bypass -File .\scripts\set-python-utf8.ps1 -Undo  # revert
```

Open a new terminal afterwards; programs that were already running (editors, AI coding agents) need a restart to
see the new environment.

## Side effects to know

- `PYTHONUTF8=1` changes the default encoding of `open()` without an explicit `encoding=` from cp1252 to UTF-8.
  A rare old script that reads or writes cp1252 files without saying so may need `encoding="cp1252"`.
- Only Python is affected; other programs ignore the variable.

## License

MIT
