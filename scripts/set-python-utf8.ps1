<#
.SYNOPSIS
  Make Python use UTF-8 everywhere on this Windows user account (PEP 540 UTF-8 mode).

.DESCRIPTION
  Sets the user environment variable PYTHONUTF8=1. Python then uses UTF-8 for open(), stdin, stdout and stderr
  instead of the legacy code page (cp1252 on most Western systems), which removes UnicodeEncodeError /
  UnicodeDecodeError crashes when scripts print or read accented text, emoji or box-drawing characters.

  Safe to run more than once. New terminals and newly started programs see the change; programs already running
  keep their old environment until restarted.

.PARAMETER Undo
  Remove the variable again (restores the Windows default behaviour).

.EXAMPLE
  .\set-python-utf8.ps1
.EXAMPLE
  .\set-python-utf8.ps1 -Undo
#>
[CmdletBinding()]
param([switch]$Undo)

$name = 'PYTHONUTF8'
$current = [Environment]::GetEnvironmentVariable($name, 'User')

if ($Undo) {
    if ($null -eq $current) { Write-Output "$name is not set; nothing to undo."; exit 0 }
    [Environment]::SetEnvironmentVariable($name, $null, 'User')
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    Write-Output "Removed $name from the user environment. Open a new terminal for it to take effect."
    exit 0
}

if ($current -eq '1') {
    Write-Output "$name=1 is already set for this user."
} else {
    [Environment]::SetEnvironmentVariable($name, '1', 'User')
    Write-Output "Set $name=1 for this user (was: $(if ($null -eq $current) { 'not set' } else { $current }))."
}
$env:PYTHONUTF8 = '1'

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    $check = & $python.Source -c "import sys, locale; print(sys.flags.utf8_mode, sys.stdout.encoding, locale.getpreferredencoding(False))"
    Write-Output "Check in this terminal (utf8_mode, stdout, default file encoding): $check"
} else {
    Write-Output "Python not found on PATH; the variable is set and will apply once Python is installed."
}
Write-Output "Open a new terminal (and restart running editors or agents) for the change to reach them."
