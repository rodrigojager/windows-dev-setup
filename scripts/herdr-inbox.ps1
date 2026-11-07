<#
.SYNOPSIS
  Inbox between AI agents running in herdr panes: delegate a task and get woken up when it is done, without polling.

.DESCRIPTION
  Polling another agent ("herdr agent wait" with a timeout, or repeated reads) makes the waiting agent re-read its
  whole conversation on every check, which is where the tokens go. With this inbox the requester delegates and then
  simply ends its turn; when the worker finishes its turn, a Stop hook in the worker prompts the requester, which
  wakes up exactly once.

  Actions:
    delegate  Send a task to another pane and remember who to notify.
              herdr-inbox.ps1 delegate -To w4:p3 -Message "Fix the failing test in src/x.ts"
              (-ReplyTo defaults to the current pane, $env:HERDR_PANE_ID)
    notify    Stop hook body: if the current pane has a pending delegation, prompt the requester and clear it.
    pending   List pending delegations.
    install   Copy this script to ~/.agents/bin and register the Stop hook for Claude Code and Codex
              (Codex asks you to trust new hooks once, in /hooks).
    uninstall Remove the Stop hooks (the copied script stays; delete it by hand if wanted).

  State lives in ~/.agents/herdr-inbox/<pane>.json. Only the inbox's own files are touched.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)] [ValidateSet('delegate', 'notify', 'pending', 'install', 'uninstall')] [string]$Action,
    [string]$To,
    [string]$Message,
    [string]$ReplyTo = $env:HERDR_PANE_ID
)

$ErrorActionPreference = 'Stop'
$Home_ = [Environment]::GetFolderPath('UserProfile')
$Inbox = Join-Path $Home_ '.agents/herdr-inbox'
$Herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
$Installed = Join-Path $Home_ '.agents/bin/herdr-inbox.ps1'
$HookCommand = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$Installed`" notify"

function Get-MarkerPath([string]$pane) { Join-Path $Inbox (($pane -replace '[^A-Za-z0-9_-]', '_') + '.json') }

switch ($Action) {
    'delegate' {
        if (-not $To -or -not $Message) { throw 'delegate needs -To <pane> and -Message <text>' }
        if (-not $ReplyTo) { throw 'Not inside a herdr pane: pass -ReplyTo <pane> (where to send the notification).' }
        New-Item -ItemType Directory -Force $Inbox | Out-Null
        $marker = Get-MarkerPath $To
        @{ to = $To; replyTo = $ReplyTo; created = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $marker -Encoding utf8
        $text = $Message + "`n`n(When you finish, end your turn normally: pane $ReplyTo is notified automatically. Put the result in your final message or in a file you name there.)"
        & $Herdr agent prompt $To $text
        if ($LASTEXITCODE -ne 0) { Remove-Item $marker -Force; throw "herdr agent prompt failed for $To (exit $LASTEXITCODE)" }
        Write-Output "delegated to $To; $ReplyTo will be prompted when it finishes. End your turn now instead of waiting."
    }
    'notify' {
        # Stop hook: never fail the agent's stop.
        try {
            $raw = [Console]::In.ReadToEnd()
            $payload = if ($raw.Trim()) { $raw | ConvertFrom-Json } else { $null }
            if ($payload -and $payload.PSObject.Properties.Name -contains 'agent_id' -and $payload.agent_id) { exit 0 }  # a subagent stopped, not the pane's agent
            $me = $env:HERDR_PANE_ID
            if (-not $me) { exit 0 }
            $marker = Get-MarkerPath $me
            if (-not (Test-Path $marker)) { exit 0 }
            $m = Get-Content $marker -Raw | ConvertFrom-Json
            $note = "inbox: the agent in pane $me finished the task you delegated. Read its answer with: herdr agent read $me --source recent-unwrapped --lines 120"
            & $Herdr agent prompt $m.replyTo $note *> $null
            if ($LASTEXITCODE -eq 0) { Remove-Item $marker -Force }  # on failure keep it: the next stop retries
        } catch { }
        exit 0
    }
    'pending' {
        if (-not (Test-Path $Inbox)) { Write-Output 'no pending delegations'; break }
        $items = Get-ChildItem $Inbox -Filter *.json
        if (-not $items) { Write-Output 'no pending delegations'; break }
        $items | ForEach-Object { $m = Get-Content $_.FullName -Raw | ConvertFrom-Json; "{0} -> notify {1} (since {2})" -f $m.to, $m.replyTo, $m.created }
    }
    'install' {
        New-Item -ItemType Directory -Force (Split-Path $Installed) | Out-Null
        if ($PSCommandPath -ne $Installed) { Copy-Item $PSCommandPath $Installed -Force }
        # Claude Code: ~/.claude/settings.json, hooks.Stop
        $claude = Join-Path $Home_ '.claude/settings.json'
        if (Test-Path $claude) {
            $s = Get-Content $claude -Raw | ConvertFrom-Json -AsHashtable
            if (-not $s.hooks) { $s.hooks = @{} }
            if (-not $s.hooks.Stop) { $s.hooks.Stop = @() }
            if (-not ($s.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -eq $HookCommand })) {
                $s.hooks.Stop = @($s.hooks.Stop) + @(@{ hooks = @(@{ type = 'command'; command = $HookCommand; timeout = 15 }) })
                $s | ConvertTo-Json -Depth 64 | Set-Content $claude -Encoding utf8
                Write-Output "Claude Code: Stop hook added to $claude"
            } else { Write-Output 'Claude Code: Stop hook already present' }
        }
        # Codex: ~/.codex/hooks.json, hooks.Stop
        $codex = Join-Path $Home_ '.codex/hooks.json'
        if (Test-Path (Split-Path $codex)) {
            $h = if (Test-Path $codex) { Get-Content $codex -Raw | ConvertFrom-Json -AsHashtable } else { @{ hooks = @{} } }
            if (-not $h.hooks) { $h.hooks = @{} }
            if (-not $h.hooks.Stop) { $h.hooks.Stop = @() }
            if (-not ($h.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -eq $HookCommand })) {
                $h.hooks.Stop = @($h.hooks.Stop) + @(@{ hooks = @(@{ type = 'command'; command = $HookCommand; timeout = 15 }) })
                $h | ConvertTo-Json -Depth 64 | Set-Content $codex -Encoding utf8
                Write-Output "Codex: Stop hook added to $codex (open Codex and approve it in /hooks once)"
            } else { Write-Output 'Codex: Stop hook already present' }
        }
    }
    'uninstall' {
        foreach ($f in @((Join-Path $Home_ '.claude/settings.json'), (Join-Path $Home_ '.codex/hooks.json'))) {
            if (-not (Test-Path $f)) { continue }
            $j = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable
            if (-not $j.hooks -or -not $j.hooks.Stop) { continue }
            $kept = @($j.hooks.Stop | Where-Object { -not ($_.hooks | Where-Object { $_.command -eq $HookCommand }) })
            if ($kept.Count -eq @($j.hooks.Stop).Count) { continue }
            if ($kept.Count) { $j.hooks.Stop = $kept } else { $j.hooks.Remove('Stop') }
            $j | ConvertTo-Json -Depth 64 | Set-Content $f -Encoding utf8
            Write-Output "removed the Stop hook from $f"
        }
    }
}
