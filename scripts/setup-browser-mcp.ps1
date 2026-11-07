<#
.SYNOPSIS
  Let AI coding agents (Codex, OpenCode, optionally Claude Code) drive your own, logged-in Chrome.

.DESCRIPTION
  Registers two MCP servers per agent:
    playwright       Playwright MCP in extension mode: your normal Chrome profile and sessions. With the extension's
                     token it connects without asking each time; --background (when the installed release supports it) keeps
                     your window in front.
    chrome-devtools  Google's Chrome DevTools MCP with --autoConnect (Chrome 144+): debugging, performance, network.
                     Each Chrome session needs remote debugging enabled at chrome://inspect/#remote-debugging and the
                     connection prompt accepted, so agents should prefer playwright for routine browsing.

  One-time manual steps (the script prints them when needed):
    1. Install "Playwright Extension" from the Chrome Web Store (the official Microsoft one).
    2. Open the extension, copy the PLAYWRIGHT_MCP_EXTENSION_TOKEN value and save it, alone, in the token file
       (default: ~/.agents/secrets/playwright-token.txt). The token is never written to this repository.

  Safe to run again (it replaces its own entries). -Undo removes both servers and restores a plain Playwright MCP
  for Codex.

.EXAMPLE
  .\setup-browser-mcp.ps1
.EXAMPLE
  .\setup-browser-mcp.ps1 -Agents codex,opencode,claude
.EXAMPLE
  .\setup-browser-mcp.ps1 -Undo
#>
[CmdletBinding()]
param(
    [string[]]$Agents = @('codex', 'opencode'),
    [string]$TokenFile = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agents/secrets/playwright-token.txt'),
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'
$UserHome = [Environment]::GetFolderPath('UserProfile')
$PlaywrightArgs = @('-y', '@playwright/mcp@latest', '--extension')
# Newer @playwright/mcp releases add --background (keep the browser window behind); add it once `npx @playwright/mcp --help` lists it.
if ((npx -y @playwright/mcp@latest --help 2>&1 | Out-String) -match '--background') { $PlaywrightArgs += '--background' }
$DevtoolsArgs = @('-y', 'chrome-devtools-mcp@latest', '--autoConnect')

$token = $null
if (-not $Undo) {
    if (Test-Path $TokenFile) {
        # Accept the bare token or the whole line copied from the extension (NAME=value, quotes optional).
        $token = ((Get-Content $TokenFile -Raw).Trim() -replace '^\s*PLAYWRIGHT_MCP_EXTENSION_TOKEN\s*[=:]\s*', '').Trim().Trim('"', "'")
    }
    if (-not $token) {
        Write-Warning "No token in $TokenFile. Playwright will be configured without it and will ask you to approve each connection."
        Write-Warning 'To stop the prompts: install "Playwright Extension" from the Chrome Web Store, copy its PLAYWRIGHT_MCP_EXTENSION_TOKEN into that file, run this script again.'
    }
}

function Invoke-Native([string]$exe, [string[]]$arguments) {
    & $exe @arguments 2>&1 | Out-Null
    return $LASTEXITCODE
}

if ($Agents -contains 'codex') {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { Write-Warning 'codex not found; skipping Codex.' }
    else {
        Invoke-Native codex @('mcp', 'remove', 'playwright') | Out-Null
        Invoke-Native codex @('mcp', 'remove', 'chrome-devtools') | Out-Null
        if ($Undo) {
            $rc = Invoke-Native codex @('mcp', 'add', 'playwright', '--', 'npx', '@playwright/mcp@latest')
            Write-Output "Codex: chrome-devtools removed, plain Playwright restored (exit $rc)."
        } else {
            $pw = @('mcp', 'add', 'playwright')
            if ($token) { $pw += @('--env', "PLAYWRIGHT_MCP_EXTENSION_TOKEN=$token") }
            $rc1 = Invoke-Native codex ($pw + @('--', 'npx') + $PlaywrightArgs)
            $rc2 = Invoke-Native codex (@('mcp', 'add', 'chrome-devtools', '--', 'npx') + $DevtoolsArgs)
            Write-Output "Codex: playwright (extension) exit $rc1, chrome-devtools exit $rc2."
        }
    }
}

if ($Agents -contains 'opencode') {
    $oc = Join-Path $UserHome '.config/opencode/opencode.json'
    if (-not (Test-Path $oc)) { Write-Warning "OpenCode config not found at $oc; skipping OpenCode." }
    else {
        $cfg = Get-Content $oc -Raw | ConvertFrom-Json -AsHashtable
        if (-not $cfg.mcp) { $cfg.mcp = [ordered]@{} }
        foreach ($k in 'playwright', 'chrome-devtools') { if ($cfg.mcp.Contains($k)) { $cfg.mcp.Remove($k) } }
        if (-not $Undo) {
            $pwEntry = [ordered]@{ type = 'local'; command = @('npx') + $PlaywrightArgs; enabled = $true }
            if ($token) { $pwEntry.environment = [ordered]@{ PLAYWRIGHT_MCP_EXTENSION_TOKEN = $token } }
            $cfg.mcp['playwright'] = $pwEntry
            $cfg.mcp['chrome-devtools'] = [ordered]@{ type = 'local'; command = @('npx') + $DevtoolsArgs; enabled = $true }
        }
        $cfg | ConvertTo-Json -Depth 64 | Set-Content $oc -Encoding utf8
        Write-Output ("OpenCode: " + $(if ($Undo) { 'both servers removed.' } else { 'playwright (extension) and chrome-devtools set.' }))
    }
}

if ($Agents -contains 'claude') {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Write-Warning 'claude not found; skipping Claude Code.' }
    else {
        Invoke-Native claude @('mcp', 'remove', '-s', 'user', 'playwright') | Out-Null
        Invoke-Native claude @('mcp', 'remove', '-s', 'user', 'chrome-devtools') | Out-Null
        if (-not $Undo) {
            $pw = @('mcp', 'add', '-s', 'user')
            if ($token) { $pw += @('-e', "PLAYWRIGHT_MCP_EXTENSION_TOKEN=$token") }
            $rc1 = Invoke-Native claude ($pw + @('playwright', '--', 'npx') + $PlaywrightArgs)
            $rc2 = Invoke-Native claude (@('mcp', 'add', '-s', 'user', 'chrome-devtools', '--', 'npx') + $DevtoolsArgs)
            Write-Output "Claude Code: playwright exit $rc1, chrome-devtools exit $rc2."
        } else { Write-Output 'Claude Code: both servers removed.' }
    }
}

if (-not $Undo) {
    Write-Output 'Restart the agents to load the servers. For chrome-devtools, enable chrome://inspect/#remote-debugging in Chrome when you want it.'
}
