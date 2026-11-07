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
pwsh -File ~\.agents\bin\herdr-inbox.ps1 delegate -To <pane> -Message "<task>"   # from inside a herdr pane
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
