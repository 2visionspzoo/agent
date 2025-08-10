# --- apply_fix2.ps1 (PS 5.1 kompatybilny) ---
$ErrorActionPreference = "Stop"
$P = "C:\agent"
Set-Location $P

# 1) .env – różne clientId dla sync i głównego połączenia
$envPath = Join-Path $P ".env"
if (!(Test-Path $envPath)) { New-Item -Type File $envPath | Out-Null }
$envText = Get-Content $envPath -Raw -Encoding UTF8
function Set-EnvLine([string]$key, [string]$val) {
  if ($script:envText -match ("(?m)^"+[regex]::Escape($key)+"=")) {
    $script:envText = $script:envText -replace ("(?m)^"+[regex]::Escape($key)+"=.*$"), ($key+"="+$val)
  } else {
    if ($script:envText.Length -gt 0 -and -not $script:envText.EndsWith("`n")) { $script:envText += "`n" }
    $script:envText += ($key+"="+$val+"`n")
  }
}
Set-EnvLine "IBKR_HOST" "host.docker.internal"
Set-EnvLine "IBKR_PORT" "4003"
Set-EnvLine "IBKR_CLIENT_ID" "101"
Set-EnvLine "IBKR_CLIENT_ID_SYNC" "12"
Set-Content -Path $envPath -Encoding UTF8 -Value $envText

# 2) Patch: agent\conid_sync.py – pomijamy FX (CASH), żeby nie walić w None
$syncPath = Join-Path $P "agent\conid_sync.py"
if (Test-Path $syncPath) {
  $sync = Get-Content $syncPath -Raw -Encoding UTF8

  # W pętli dopisz pomijanie FX przed resolve:
  if ($sync -notmatch '\[.*\] Pomijam FX') {
    $sync = $sync -replace '(?m)for key, val in data\.items\(\):\s*\r?\n\s*if not isinstance\(val, dict\): continue',
@'
for key, val in data.items():
        if not isinstance(val, dict):
            continue
        # pomijamy FX na tym etapie, żeby nie łapać "Cannot send None to TWS"
        if str(val.get("secType","")).upper() == "CASH":
            print(f"[{key}] Pomijam FX (CASH) na etapie conId sync.")
            continue
'@
    Set-Content -Path $syncPath -Encoding UTF8 -Value $sync
  }
} else {
  Write-Host "Brak pliku $syncPath — pomijam patch na sync." -ForegroundColor Yellow
}

# 3) app\main.py — wymuś poprawny blok ensure_conids z IBKR_CLIENT_ID_SYNC
$mainPath = Join-Path $P "app\main.py"
if (!(Test-Path $mainPath)) { throw "Nie znaleziono $mainPath" }
$main = Get-Content $mainPath -Raw -Encoding UTF8

# a) import
if ($main -notmatch 'from\s+agent\.conid_sync\s+import\s+ensure_conids') {
  $main = $main -replace '(?m)^(\s*from .+ import .+\s*|\s*import .+\s*)+', "$0`r`nfrom agent.conid_sync import ensure_conids`r`n"
}

# b) wstrzyknięcie/aktualizacja bloku try: ensure_conids(...)
$block = @'
# --- conId sync on startup (separate clientId to avoid #326) ---
try:
    ensure_conids(
        path="config/symbols.yaml",
        host=os.getenv("IBKR_HOST", "host.docker.internal"),
        port=int(os.getenv("IBKR_PORT", "4003")),
        client_id=int(os.getenv("IBKR_CLIENT_ID_SYNC", "12")),
        save_in_place=True
    )
    log.info("conId sync: OK")
except Exception as e:
    log.warning(f"conId sync skipped: {e}")
# --- end conId sync ---
'@

if ($main -match '(?s)# --- conId sync on startup.*?end conId sync ---') {
  $main = $main -replace '(?s)# --- conId sync on startup.*?end conId sync ---', $block
} else {
  # dodaj zaraz po utworzeniu loggera, albo na końcu importów jeśli loggera nie ma
  if ($main -match '(?m)^\s*log\s*=\s*logging\.getLogger\(.+\)\s*$') {
    $main = $main -replace '(?m)^\s*log\s*=\s*logging\.getLogger\(.+\)\s*$', "`$0`r`n$block"
  } else {
    $main = $main -replace '(?m)^(\s*from .+\s*|\s*import .+\s*)+', "$0`r`n$block`r`n"
  }
}
Set-Content -Path $mainPath -Encoding UTF8 -Value $main

# 4) Rebuild & run
docker compose build app
docker compose up -d
docker compose logs -f app
