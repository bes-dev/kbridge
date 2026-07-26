# Install the kb harness for Claude Code on Windows (per-user, no admin rights needed).
#
# Usage:  powershell -ExecutionPolicy Bypass -File setup.ps1 -VaultPath C:\path\to\vault
#   VaultPath defaults to ~\.obsidian if present, else fails.
#
# Unlike setup.sh this does NOT symlink (symlinks need admin/Developer Mode on Windows):
# it COPIES the skills into ~\.claude\skills\ and records the vault path in the copy.
# Re-run after a git pull to refresh. Local state (vault_path, sync_remote, index_chats)
# is preserved across re-runs. Pi and encrypted sync are not set up here.

param([string]$VaultPath = (Join-Path $HOME '.obsidian'))

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -PathType Container $VaultPath)) {
  throw "Vault path '$VaultPath' is not a directory. Pass it explicitly: setup.ps1 -VaultPath <path>"
}
$VaultPath = (Resolve-Path $VaultPath).Path
if (-not (Test-Path (Join-Path $VaultPath 'AGENTS.md'))) {
  Write-Warning "$VaultPath has no AGENTS.md - is this really a knowledge base vault?"
}

$srcSkills = Join-Path $PSScriptRoot '.claude\skills'
$dstSkills = Join-Path $HOME '.claude\skills'
$localState = 'vault_path', 'sync_remote', 'index_chats'

$installed = @()
foreach ($skill in Get-ChildItem -Directory $srcSkills) {
  $dst = Join-Path $dstSkills $skill.Name
  New-Item -ItemType Directory -Force $dst | Out-Null
  Copy-Item (Join-Path $skill.FullName '*') $dst -Recurse -Force -Exclude $localState
  $installed += $skill.Name
}

# UTF-8 without BOM: the file is read verbatim by every harness.
[IO.File]::WriteAllText((Join-Path $dstSkills 'kb\vault_path'), $VaultPath)

Write-Host ""
Write-Host "Vault:          $VaultPath"
Write-Host "Claude skills:  $($installed -join ', ') (copied to $dstSkills)"
Write-Host ""
Write-Host "Use /kb from any folder in Claude Code (CLI or the Claude desktop app)."
Write-Host "Optional: install Git for Windows (per-user, no admin) to enable kb-sync."
