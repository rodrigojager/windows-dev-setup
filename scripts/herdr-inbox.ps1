<#
.SYNOPSIS
  Inbox between AI agents running in herdr panes: delegate a task and get woken up when it is done, without polling.

.DESCRIPTION
  Polling another agent ("herdr agent wait" with a timeout, or repeated reads) makes the waiting agent re-read its
  whole conversation on every check, which is where the tokens go. With this inbox the requester delegates and then
  simply ends its turn; when the worker finishes its turn, a Stop hook in the worker prompts the requester, which
  wakes up after delivery. A crash after delivery but before clearing state can cause a retry.

  Actions:
    delegate  Send a task to another pane and remember who to notify.
              herdr-inbox.ps1 delegate -To w4:p3 -Message "Fix the failing test in src/x.ts"
              (-ReplyTo defaults to the current pane, $env:HERDR_PANE_ID)
    notify    Stop hook body: verify the delegation ID in the hook transcript, then notify its requester.
    pending   List pending delegations.
    version   Print the installed script version.
    install   Copy this script to ~/.agents/bin and register the Stop hook for Claude Code and Codex
              (Codex asks you to trust new hooks once, in /hooks).
    uninstall Remove the Stop hooks (the copied script stays; delete it by hand if wanted).

  State lives in ~/.agents/herdr-inbox/<pane>.json. -InboxDirectory selects an isolated state directory.
  New delegations carry an ID in the user prompt. notify verifies a session-bound Claude Code/Codex
  transcript, or delegation IDs obtained by the OpenCode plugin from its session API.
  Inherited HERDR_PANE_ID is never used to identify the worker.
  Legacy markers and hooks without verified identity data are retained with a diagnostic, never guessed.
  Pass -ReplyTo explicitly when the requester also runs through a daemon with inherited pane variables.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)] [ValidateSet('delegate', 'notify', 'pending', 'version', 'install', 'uninstall')] [string]$Action,
    [string]$To,
    [string]$Message,
    [string]$ReplyTo = $env:HERDR_PANE_ID,
    [string]$InboxDirectory
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.2.0'
$Home_ = [Environment]::GetFolderPath('UserProfile')
$Inbox = if ($InboxDirectory) { [IO.Path]::GetFullPath($InboxDirectory) } else { Join-Path $Home_ '.agents/herdr-inbox' }
$Herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
$Installed = Join-Path $Home_ '.agents/bin/herdr-inbox.ps1'
$HookCommand = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$Installed`" notify"

function Get-MarkerPath([string]$pane) { Join-Path $Inbox (($pane -replace '[^A-Za-z0-9_-]', '_') + '.json') }

function Write-Diagnostic([string]$message) {
    [Console]::Error.WriteLine("herdr-inbox: $message")
}

function Lock-Marker([string]$path) {
    # Keep the lock file: unlinking it would allow two processes to lock different file objects.
    [IO.File]::Open("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Send-Prompt([string]$pane, [string]$text) {
    $global:LASTEXITCODE = 0
    & $Herdr agent prompt $pane $text | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Herdr delivery failed.' }
}

function Get-TranscriptIds([string]$path, [string]$session) {
    $ids = [Collections.Generic.HashSet[string]]::new()
    $codexSession = $null
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            # Most transcript lines are large tool results. Parse only metadata and possible IDs.
            if (-not $line.Contains('[herdr-inbox:') -and -not $line.Contains('"session_meta"')) { continue }
            $record = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop
            if ($record.type -eq 'session_meta') {
                $codexSession = if ($record.payload.session_id) { $record.payload.session_id } else { $record.payload.id }
                if ($codexSession -cne $session) { throw 'Transcript session mismatch.' }
                continue
            }
            $content = $null
            if ($record.type -eq 'response_item' -and $record.payload.type -eq 'message' -and
                $record.payload.role -eq 'user' -and $codexSession -ceq $session) {
                $content = $record.payload.content
            } elseif ($record.type -eq 'user' -and $record.message.role -eq 'user' -and
                $record.sessionId -ceq $session) {
                $content = $record.message.content
            }
            foreach ($part in @($content)) {
                $text = if ($part -is [string]) { $part } elseif (
                    $part -is [Collections.IDictionary] -and $part.type -in @('text', 'input_text')
                ) { $part.text } else { $null }
                if ($text -isnot [string]) { continue }
                foreach ($match in [regex]::Matches($text, '(?m)^\[herdr-inbox:([0-9a-f]{32})\]\r?$')) {
                    [void]$ids.Add($match.Groups[1].Value)
                }
            }
        }
    } finally { $reader.Dispose() }
    return ,$ids
}

switch ($Action) {
    'version' { Write-Output $ScriptVersion }
    'delegate' {
        if (-not $To -or -not $Message) { throw 'delegate needs -To <pane> and -Message <text>' }
        if (-not $ReplyTo) { throw 'Pass -ReplyTo <pane> (where to send the notification).' }
        New-Item -ItemType Directory -Force $Inbox | Out-Null
        $marker = Get-MarkerPath $To
        $lock = Lock-Marker $marker
        try {
            if (Test-Path -LiteralPath $marker) { throw 'This pane already has a pending delegation; inspect pending first.' }
            $id = [guid]::NewGuid().ToString('N')
            @{ version = 2; id = $id; to = $To; replyTo = $ReplyTo; created = (Get-Date).ToString('o') } |
                ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding utf8
            $nl = [Environment]::NewLine
            $text = $Message + "$nl$nl[herdr-inbox:$id]$nl(When you finish, end your turn normally: pane $ReplyTo is notified automatically. Put the result in your final message or in a file you name there.)"
            # An interrupted CLI may already have submitted the prompt; retain its marker on failure.
            Send-Prompt $To $text
        } finally { $lock.Dispose() }
        Write-Output "delegated to $To; $ReplyTo will be prompted when it finishes. End your turn now instead of waiting."
    }
    'notify' {
        # Never block the agent's stop. Retain the marker and report a sanitized reason on uncertainty.
        $stage = 'invalid hook JSON'
        try {
            $raw = [Console]::In.ReadToEnd()
            $payload = if ($raw.Trim()) { $raw | ConvertFrom-Json -AsHashtable } else { @{} }
            if ($payload.agent_id) { exit 0 }
            if (-not (Test-Path -LiteralPath $Inbox)) { exit 0 }
            $files = @(Get-ChildItem -LiteralPath $Inbox -Filter *.json -File)
            if (-not $files.Count) { exit 0 }
            $stage = 'hook lacks session_id or transcript_path; pending delegations retained'
            if ($payload.session_id -isnot [string] -or -not $payload.session_id) { throw 'Missing session.' }
            if ($payload.source -ceq 'opencode') {
                # The trusted local plugin checks the root session and message ownership through its SDK.
                $stage = 'invalid OpenCode identity payload; pending delegations retained'
                if ($payload.delegation_ids -isnot [array]) { throw 'Missing delegation IDs.' }
                $ids = [Collections.Generic.HashSet[string]]::new()
                foreach ($id in $payload.delegation_ids) {
                    if ($id -isnot [string] -or $id -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid delegation ID.' }
                    [void]$ids.Add($id)
                }
            } else {
                if ($payload.transcript_path -isnot [string] -or -not $payload.transcript_path) { throw 'Missing transcript.' }
                $stage = 'transcript unreadable, malformed, or session mismatch; pending delegations retained'
                $ids = Get-TranscriptIds $payload.transcript_path $payload.session_id
            }
            $candidates = @()
            foreach ($file in $files) {
                $stage = 'invalid pending marker; pending delegations retained'
                try {
                    $m = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
                } catch {
                    Write-Diagnostic 'unreadable or malformed marker retained'
                    continue
                }
                if ($m.version -ne 2 -or $m.id -isnot [string] -or $m.id -cnotmatch '^[0-9a-f]{32}$') {
                    Write-Diagnostic 'legacy or invalid marker retained; it has no verified delegation ID'
                    continue
                }
                if ($ids.Contains($m.id)) { $candidates += @{ file = $file.FullName; id = $m.id } }
            }
            if (-not $candidates.Count) {
                Write-Diagnostic 'no pending delegation matched this transcript; markers retained'
                exit 0
            }
            $stage = 'multiple pending delegations matched; refusing ambiguous notification'
            if ($candidates.Count -ne 1) { throw 'Ambiguous delegation.' }
            $candidate = $candidates[0]
            $stage = 'delegation busy; another invocation may be delivering it'
            $lock = Lock-Marker $candidate.file
            try {
                if (-not (Test-Path -LiteralPath $candidate.file)) { exit 0 }
                $stage = 'marker changed or has invalid routing fields; pending delegation retained'
                $m = Get-Content -LiteralPath $candidate.file -Raw | ConvertFrom-Json -AsHashtable
                if ($m.version -ne 2 -or $m.id -cne $candidate.id -or
                    $m.to -isnot [string] -or -not $m.to -or
                    $m.replyTo -isnot [string] -or -not $m.replyTo -or
                    (Get-MarkerPath $m.to) -ne $candidate.file) { throw 'Invalid routing.' }
                $note = "inbox: the agent in pane $($m.to) finished the task you delegated. Read its answer with: herdr agent read $($m.to) --source recent-unwrapped --lines 120"
                $stage = 'Herdr delivery failed; pending delegation retained for retry'
                Send-Prompt $m.replyTo $note
                $stage = 'notification delivered but marker could not be cleared; retry may duplicate it'
                Remove-Item -LiteralPath $candidate.file -Force
            } finally { $lock.Dispose() }
        } catch { Write-Diagnostic $stage }
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
