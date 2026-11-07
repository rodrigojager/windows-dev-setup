# windows-dev-setup

Small, idempotent fixes for a Windows development machine. Each script can be run more than once and has an
`-Undo` switch.

| Script | What it fixes |
|---|---|
| `scripts/set-python-utf8.ps1` | Python crashing with `UnicodeEncodeError: 'charmap' codec…` / `UnicodeDecodeError` on accented text, emoji or box characters, because Windows Python defaults to the legacy code page (cp1252). Sets `PYTHONUTF8=1` for the current user, so Python uses UTF-8 for files and console I/O. |
| `scripts/setup-browser-mcp.ps1` | AI agents (Codex, OpenCode, optionally Claude Code) driving your own logged-in Chrome: Playwright MCP in extension mode (no approval prompt once its token is saved) plus Chrome DevTools MCP with `--autoConnect`. `-Agents codex,opencode,claude`, `-Undo`. |
| `scripts/herdr-inbox.ps1` | Agents in [herdr](https://herdr.dev) panes delegating to each other without polling: `delegate` sends a task and the requester ends its turn; a Stop hook in the worker prompts the requester once when it finishes. `install` registers the hook for Claude Code and Codex; `pending`, `uninstall`. |

## Use

```powershell
git clone <this repository>
cd windows-dev-setup
powershell -ExecutionPolicy Bypass -File .\scripts\set-python-utf8.ps1        # apply
powershell -ExecutionPolicy Bypass -File .\scripts\set-python-utf8.ps1 -Undo  # revert

pwsh -File .\scripts\setup-browser-mcp.ps1        # browser MCP servers for Codex and OpenCode
pwsh -File .\scripts\herdr-inbox.ps1 install      # agent inbox hooks (approve the Codex hook in /hooks once)
pwsh -File ~\.agents\bin\herdr-inbox.ps1 delegate -To <pane> -ReplyTo <requester-pane> -Message "<task>"   # from inside a herdr pane
```

`setup-browser-mcp.ps1` needs one manual step for prompt-free use: install "Playwright Extension" from the Chrome
Web Store and save its `PLAYWRIGHT_MCP_EXTENSION_TOKEN` alone in `~/.agents/secrets/playwright-token.txt` (the
token never goes into this repository), then run the script again. Chrome DevTools MCP needs remote debugging
enabled at `chrome://inspect/#remote-debugging` in each Chrome session where you want it.

The Playwright extension mode brings the controlled tab and window to the front (the `--background` option is
added automatically once the published `@playwright/mcp` supports it). Use it when you are present and the browser
may take focus; for unattended work, use a headless browser through a script instead (no focus, no logged-in
sessions).

Open a new terminal afterwards; programs that were already running (editors, AI coding agents) need a restart to
see the new environment.

## Side effects to know

- `PYTHONUTF8=1` changes the default encoding of `open()` without an explicit `encoding=` from cp1252 to UTF-8.
  A rare old script that reads or writes cp1252 files without saying so may need `encoding="cp1252"`.
- Only Python is affected; other programs ignore the variable.

## License

MIT

## Inbox identity and recovery

Inbox version: 1.1.0 (check with the script's version action).

Each new delegation stores a random ID and includes it in the worker's user prompt. The Stop hook matches that
ID in the transcript supplied by the hook, with the matching session ID (Claude Code and Codex JSONL formats).
It does not identify the worker using inherited HERDR_PANE_ID, focus, working directory, or a live pane lookup.
Pass -ReplyTo explicitly if the requester runs in a daemon: its environment may also contain an older pane ID.

The hook retains pending state and writes a short stderr diagnostic if identity cannot be verified, delivery
fails, or more than one pending delegation matches. Concurrent invocations are serialized per marker. After
successful delivery the marker is cleared; a crash after submission but before clearing can still cause a retry.
A new delegation cannot overwrite a pending one.

Markers created by the older script have no delegation ID and are deliberately not delivered automatically.
Inspect pending and resolve those old tasks manually. Do not resend already completed tasks just to migrate
their markers. If a compacted transcript no longer contains the original delegation prompt, the hook likewise
keeps the pending marker rather than guessing.

The existing OpenCode plugin supplies an empty payload, without a transcript or session ID. It cannot use
this verification path and will receive a diagnostic instead of an unverified notification; that plugin needs
a separate integration change. This script registers Stop hooks only for Claude Code and Codex.

For an isolated regression run (Python 3 and PowerShell 7, no live Herdr or panes):

    python -m unittest discover -s tests -p "test_herdr_inbox.py" -v

Tests set HERDR_BIN_PATH to a fake transport and pass -InboxDirectory pointing to disposable state. They
never run install, read the real inbox, or contact a pane.
