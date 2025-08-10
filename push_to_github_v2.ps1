# --- push_to_github_v2.ps1 (PS 5.1-safe) ---
$ErrorActionPreference = 'Stop'

# 0) Project path
$ProjectPath = 'C:\agent'
if (!(Test-Path $ProjectPath)) { throw "Folder not found: $ProjectPath" }
Set-Location $ProjectPath

# 1) Git check
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'Git not found. Please install Git for Windows and retry.'
}
Write-Host ("Git: " + (git --version)) -ForegroundColor Cyan

# 2) Basic global config (one-time per machine)
function Ensure-GitConfig {
  param([string]$Key,[string]$Prompt,[string]$Default)
  $val = git config --global $Key 2>$null
  if (-not $val) {
    if ([string]::IsNullOrEmpty($Default)) {
      $inp = Read-Host -Prompt $Prompt
    } else {
      $inp = Read-Host -Prompt ($Prompt + " [" + $Default + "]")
    }
    if ([string]::IsNullOrWhiteSpace($inp)) { $inp = $Default }
    if (-not [string]::IsNullOrWhiteSpace($inp)) {
      git config --global $Key $inp | Out-Null
    }
  }
}
Ensure-GitConfig -Key "user.name"  -Prompt "Git user.name"  -Default "Your Name"
Ensure-GitConfig -Key "user.email" -Prompt "Git user.email" -Default "you@example.com"

# CRLF and credential helper
try { git config --global core.autocrlf true | Out-Null } catch {}
try { git config --global credential.helper manager-core | Out-Null } catch { try { git config --global credential.helper manager | Out-Null } catch {} }

# 3) .gitignore
$gitignorePath = Join-Path $ProjectPath '.gitignore'
$giWanted = @'
# Python / build
__pycache__/
*.py[cod]
*.pyo
*.pyd
*.so
*.egg-info/
.ipynb_checkpoints/
.pytest_cache/
.mypy_cache/
.venv/
venv/
build/
dist/

# Environment & logs
.env
.env.*
*.log

# Editors/OS
.vscode/
.idea/
*.swp
.DS_Store
Thumbs.db

# Project-specific
config/*secret*.*ml
config/*secrets*.*ml
config/*.local.*ml
data/
'@

if (Test-Path $gitignorePath) {
  $existing = Get-Content $gitignorePath -Raw -Encoding UTF8
  $toAdd = @()
  foreach ($line in ($giWanted -split "`r?`n")) {
    if ($line -and ($existing -notmatch [regex]::Escape($line))) { $toAdd += $line }
  }
  if ($toAdd.Count -gt 0) {
    Add-Content -Path $gitignorePath -Encoding UTF8 -Value ("`n" + ($toAdd -join "`n") + "`n")
    Write-Host '.gitignore updated' -ForegroundColor Green
  } else {
    Write-Host '.gitignore already OK' -ForegroundColor DarkGreen
  }
} else {
  Set-Content -Path $gitignorePath -Encoding UTF8 -Value $giWanted
  Write-Host '.gitignore created' -ForegroundColor Green
}

# If .env is tracked, untrack it (safe check without throwing)
$envTracked = $false
$envList = (& git ls-files --cached -- .env) 2>$null
if ($envList) { $envTracked = $true }
if ($envTracked) {
  git rm --cached .env | Out-Null
  Write-Host 'Removed .env from index (left on disk).' -ForegroundColor Yellow
}

# 4) Init repo if needed; ensure main branch
$hasGit = Test-Path (Join-Path $ProjectPath '.git')
if (-not $hasGit) {
  $initOk = $true
  try {
    git init -b main | Out-Null
  } catch {
    $initOk = $false
  }
  if (-not $initOk) {
    git init | Out-Null
    git checkout -b main | Out-Null
  }
  Write-Host 'Initialized Git repo (branch: main)' -ForegroundColor Green
} else {
  $branch = (git rev-parse --abbrev-ref HEAD).Trim()
  if ($branch -ne 'main') {
    try { git checkout main | Out-Null } catch { git checkout -b main | Out-Null }
  }
}

# 5) Remote origin
function Get-RemoteOriginUrl {
  try { return (git remote get-url origin 2>$null).Trim() } catch { return $null }
}
$originUrl = Get-RemoteOriginUrl

if (-not $originUrl) {
  if (Get-Command gh -ErrorAction SilentlyContinue) {
    $repoName = Read-Host -Prompt "GitHub repo name (e.g. agent)"
    if ([string]::IsNullOrWhiteSpace($repoName)) { $repoName = 'agent' }
    $visibility = Read-Host -Prompt "Visibility: private/public [private]"
    if ([string]::IsNullOrWhiteSpace($visibility)) { $visibility = 'private' }
    $visFlag = '--private'
    if ($visibility.ToLower() -eq 'public') { $visFlag = '--public' }
    # Create repo via gh and add as origin
    & gh repo create $repoName $visFlag --source "." --remote "origin" --confirm | Out-Null
    $originUrl = Get-RemoteOriginUrl
    Write-Host ("Created remote origin: " + $originUrl) -ForegroundColor Green
  } else {
    $originUrl = Read-Host -Prompt "Paste GitHub repo URL (HTTPS/SSH), e.g. https://github.com/<user>/<repo>.git"
    if ([string]::IsNullOrWhiteSpace($originUrl)) { throw 'Remote URL not provided.' }
    git remote add origin $originUrl | Out-Null
    Write-Host ("Added remote origin: " + $originUrl) -ForegroundColor Green
  }
} else {
  Write-Host ("Using existing remote origin: " + $originUrl) -ForegroundColor Yellow
}

# 6) Sync: pull (if remote has main), then add/commit/push
$remoteHasMain = $false
try {
  git ls-remote --exit-code --heads origin main | Out-Null
  if ($LASTEXITCODE -eq 0) { $remoteHasMain = $true }
} catch {}

if ($remoteHasMain) {
  try {
    git fetch origin main | Out-Null
    git pull --rebase origin main
  } catch {
    Write-Host 'Pull --rebase skipped or failed (maybe empty remote).' -ForegroundColor DarkYellow
  }
}

git add -A
$changes = git status --porcelain
if ($changes) {
  $msg = "chore: sync local project state " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  git commit -m $msg | Out-Null
  Write-Host ("Commit: " + $msg) -ForegroundColor Green
} else {
  Write-Host 'No local changes to commit.' -ForegroundColor Yellow
}

try {
  git push -u origin main
  Write-Host 'Pushed to origin/main.' -ForegroundColor Green
} catch {
  Write-Host 'Push failed. Check permissions or use a Personal Access Token for HTTPS.' -ForegroundColor Red
  throw
}
# --- end ---
