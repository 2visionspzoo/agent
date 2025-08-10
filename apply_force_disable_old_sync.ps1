# --- apply_force_disable_old_sync.ps1 ---
$ErrorActionPreference = "Stop"
$P = "C:\agent"
if (!(Test-Path $P)) { throw "Nie znaleziono katalogu $P" }
Set-Location $P

# 0) Backup
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
foreach ($f in @(".env","app\main.py","app\prestart.py","agent\conid_sync.py","requirements.txt","sitecustomize.py","Dockerfile","docker-compose.yml")) {
  $full = Join-Path $P $f; if (Test-Path $full) { Copy-Item $full "$full.bak_$stamp" -Force }
}

# 1) .env – twarde rozdzielenie ID + blokada starego hooka
$envPath = Join-Path $P ".env"
if (!(Test-Path $envPath)) { New-Item -Type File $envPath | Out-Null }
$envText = Get-Content $envPath -Raw -Encoding UTF8
function Set-Env([string]$k,[string]$v){
  if ($script:envText -match ("(?m)^"+[regex]::Escape($k)+"=")) {
    $script:envText = $script:envText -replace ("(?m)^"+[regex]::Escape($k)+"=.*$"), ($k+"="+$v)
  } else {
    if ($script:envText.Length -gt 0 -and -not $script:envText.EndsWith("`n")){ $script:envText += "`n" }
    $script:envText += ($k+"="+$v+"`n")
  }
}
Set-Env "IBKR_HOST" "host.docker.internal"
Set-Env "IBKR_PORT" "4003"
Set-Env "IBKR_CLIENT_ID" "801"
Set-Env "IBKR_CLIENT_ID_SYNC" "802"
Set-Env "DISABLE_CONID_SYNC" "1"        # stary hook w main.py (jeśli istnieje) ma być ignorowany
Set-Env "FORCE_DISABLE_CONID_SYNC" "1"  # sitecustomize nadpisze ensure_conids na no-op
Set-Env "PRESTART_SYNC_DONE" "0"
Set-Content -Path $envPath -Encoding UTF8 -Value ($envText.Trim()+"`n")

# 2) sitecustomize.py – globalny no-op dla starego ensure_conids (ładowany automatycznie przez Pythona)
$sitePath = Join-Path $P "sitecustomize.py"
@'
import os
if os.getenv("FORCE_DISABLE_CONID_SYNC","0") == "1":
    try:
        import agent.conid_sync as _cs
        def _noop(*a, **k):
            raise RuntimeError("conId sync disabled by sitecustomize")
        _cs.ensure_conids = _noop
    except Exception:
        pass
'@ | Set-Content -Encoding UTF8 $sitePath

# 3) app\prestart.py – właściwy sync (oddzielny clientId) + krótka pauza
$prePath = Join-Path $P "app\prestart.py"
@'
import os, time, logging
from agent.conid_sync import ensure_conids
log = logging.getLogger("app")
if os.getenv("PRESTART_SYNC_DONE", "0") != "1":
    try:
        ensure_conids(
            path="config/symbols.yaml",
            host=os.getenv("IBKR_HOST", "host.docker.internal"),
            port=int(os.getenv("IBKR_PORT", "4003")),
            client_id=int(os.getenv("IBKR_CLIENT_ID_SYNC", "802")),
            save_in_place=True
        )
        log.info("prestart conId sync: OK")
    except Exception as e:
        log.warning(f"prestart conId sync skipped: {e}")
    finally:
        os.environ["PRESTART_SYNC_DONE"] = "1"
        time.sleep(1.5)  # daj IB chwilę by zamknął sesję synca
'@ | Set-Content -Encoding UTF8 $prePath

# 4) Inject 'import app.prestart' na samą górę app\main.py (nie ruszamy reszty kodu)
$mainPath = Join-Path $P "app\main.py"
if (!(Test-Path $mainPath)) { throw "Nie znaleziono $mainPath" }
$main = Get-Content $mainPath -Raw -Encoding UTF8
if ($main -notmatch '(?m)^\s*import\s+app\.prestart\b') {
  $main = "import app.prestart`r`n" + $main
}
# usuń ewentualny bezpośredni import ensure_conids (niepotrzebny po sitecustomize)
$main = [regex]::Replace($main, '(?m)^\s*from\s+agent\.conid_sync\s+import\s+ensure_conids\s*\r?\n', '')
Set-Content -Path $mainPath -Encoding UTF8 -Value $main

# 5) agent\conid_sync.py – wersja bezpieczna (jeśli już masz – nadpisz)
$syncPath = Join-Path $P "agent\conid_sync.py"
@'
import threading, datetime as dt
from typing import Dict, Any, List, Optional
from ruamel.yaml import YAML
from ibapi.wrapper import EWrapper
from ibapi.client import EClient
from ibapi.contract import Contract, ContractDetails
from pathlib import Path

yaml = YAML(); yaml.preserve_quotes = True

OVERRIDES = {
    "US100":   {"secType": "CFD", "exchange": "SMART", "currency": "USD"},
    "OIL.WTI": {"secType": "CFD", "exchange": "SMART", "currency": "USD"},
}

def normalize_entry(key: str, d: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(d or {})
    if key in OVERRIDES: out.update({k:v for k,v in OVERRIDES[key].items() if v})
    out["secType"] = (out.get("secType") or "").upper()
    if out.get("symbol") is not None: out["symbol"] = str(out.get("symbol") or "").upper()
    if not out.get("exchange"): out["exchange"] = "SMART"
    if out["secType"] == "CASH":
        sym = out.get("symbol") or ""; cur = (out.get("currency") or "").upper()
        if len(sym) >= 6 and sym[:3].isalpha() and sym[-3:].isalpha():
            out["symbol"], out["currency"] = sym[:3], sym[-3:]
        elif len(sym) == 3 and cur:
            out["symbol"], out["currency"] = sym[:3], cur
        if not out.get("exchange"): out["exchange"] = "IDEALPRO"
    if out["secType"] == "CMDTY":
        sym = out.get("symbol") or ""
        if len(sym) >= 6 and sym[:3].isalpha() and sym[-3:].isalpha():
            base, quote = sym[:3], sym[-3:]
            if base in {"XAU","XAG","XPT","XPD"}:
                out["symbol"], out["currency"] = base, quote
    return out

def to_contract(key: str, d: Dict[str, Any]) -> Contract:
    nd = normalize_entry(key, d)
    if not nd.get("secType"):  raise ValueError(f"{key}: missing secType")
    if not nd.get("symbol"):   raise ValueError(f"{key}: missing symbol")
    if nd["secType"] in ("CASH","CMDTY","CFD") and not nd.get("currency"):
        raise ValueError(f"{key}: missing currency for {nd['secType']}")
    c = Contract()
    if nd.get("conId"):
        try: c.conId = int(nd["conId"])
        except: pass
    c.secType  = nd.get("secType")
    c.symbol   = nd.get("symbol")
    c.exchange = nd.get("exchange")
    c.currency = nd.get("currency")
    if c.secType == "FUT" and nd.get("lastTradeDateOrContractMonth"):
        c.lastTradeDateOrContractMonth = str(nd["lastTradeDateOrContractMonth"])
    return c

def score_candidate(want: Dict[str, Any], cd: ContractDetails) -> int:
    sec = (want.get("secType") or "").upper()
    exch = (want.get("exchange") or "").upper()
    cur = (want.get("currency") or "").upper()
    sym = (want.get("symbol") or "").upper()
    s = 0
    if (cd.contract.secType or "").upper() == sec: s += 10
    if cur and (cd.contract.currency or "").upper() == cur: s += 5
    if exch and (cd.contract.exchange or "").upper() == exch: s += 4
    if sym and (cd.contract.symbol or "").upper() == sym: s += 4
    if sec == "FUT":
        ltd = cd.contract.lastTradeDateOrContractMonth or ""
        try:
            dt_obj = dt.datetime.strptime(ltd, "%Y%m%d") if len(ltd)==8 else (
                     dt.datetime.strptime(ltd, "%Y%m") if len(ltd)==6 else None)
            if dt_obj:
                days = (dt_obj - dt.datetime.utcnow()).days
                if days >= 0: s += max(0, 100 - min(days, 100))
        except: pass
    return s

def pick_best(want: Dict[str, Any], cds: List[ContractDetails]) -> Optional[ContractDetails]:
    if not cds: return None
    cds.sort(key=lambda cd: score_candidate(want, cd), reverse=True)
    return cds[0]

class _Resolver(EWrapper, EClient):
    def __init__(self):
        EClient.__init__(self, self)
        self._next_ready = threading.Event()
        self._next_id = None
        self._lock = threading.Lock()
        self._done = {}
        self._res = {}
        self.errors: List[str] = []

    def nextValidId(self, orderId:int):
        self._next_id = orderId; self._next_ready.set()

    def error(self, reqId, code, msg, *_):
        print("IB error:", reqId, code, msg)
        if code in (200,201): self.errors.append(f"[{reqId}] {code} {msg}")

    def contractDetails(self, reqId:int, cd:ContractDetails):
        with self._lock:
            self._res.setdefault(reqId, []).append(cd)

    def contractDetailsEnd(self, reqId:int):
        with self._lock:
            evt = self._done.get(reqId)
            if evt: evt.set()

    def _get_req_id(self) -> int:
        if not self._next_ready.wait(30): raise RuntimeError("Brak nextValidId z TWS/Gateway (30s).")
        with self._lock:
            rid = self._next_id; self._next_id += 1; return rid

    def resolve(self, key: str, item: Dict[str, Any], timeout=20) -> Optional[ContractDetails]:
        c = to_contract(key, item)
        reqId = self._get_req_id()
        evt = threading.Event()
        with self._lock:
            self._done[reqId] = evt; self._res[reqId] = []
        self.reqContractDetails(reqId, c)
        if not evt.wait(timeout): return None
        return pick_best(normalize_entry(key, item), self._res.get(reqId, []))

def ensure_conids(path="config/symbols.yaml", host="127.0.0.1", port=4003, client_id=802, save_in_place=True) -> bool:
    fp = Path(path)
    data = yaml.load(fp.read_text(encoding="utf-8"))

    app = _Resolver()
    app.connect(host, port, client_id)
    t = threading.Thread(target=app.run, daemon=True); t.start()
    if not app._next_ready.wait(30): raise RuntimeError("Nie połączono z IB Gateway/TWS (brak nextValidId).")

    changed = False
    for key, val in data.items():
        if not isinstance(val, dict): continue
        try: _ = to_contract(key, val)
        except Exception as ve: print(f"[{key}] Pomijam: {ve}"); continue

        need_lookup = not val.get("conId")
        if val.get("conId"):
            cd = app.resolve(key, val, timeout=12)
            if not cd or int(cd.contract.conId) != int(val["conId"]): need_lookup = True

        if need_lookup:
            cd = app.resolve(key, val, timeout=20)
            if not cd:
                print(f"[{key}] Nie znaleziono kontraktu ({val.get('secType')} {val.get('symbol')})."); continue
            val["conId"]    = int(cd.contract.conId)
            val["symbol"]   = cd.contract.symbol
            val["exchange"] = cd.contract.exchange
            val["currency"] = cd.contract.currency
            if cd.contract.secType == "FUT":
                val["lastTradeDateOrContractMonth"] = cd.contract.lastTradeDateOrContractMonth
            changed = True
            print(f"[{key}] conId={val['conId']} | {cd.contract.secType} {val['symbol']}.{val['currency']} @ {val['exchange']}")

    try: app.disconnect()
    except: pass

    if changed and save_in_place:
        with open(fp, "w", encoding="utf-8") as f: yaml.dump(data, f)
        print(f"✓ Zaktualizowano {fp}")
    elif not changed:
        print("Brak zmian w symbolach (conId aktualne).")
    return changed

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="path", default="config/symbols.yaml")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4003)
    ap.add_argument("--client", type:int, default=802)
    args = ap.parse_args()
    ensure_conids(args.path, args.host, args.port, args.client, save_in_place=True)
'@ | Set-Content -Encoding UTF8 $syncPath

# 6) requirements.txt – dopisz paczki
$reqPath = Join-Path $P "requirements.txt"
if (Test-Path $reqPath) { $req = Get-Content $reqPath -Raw -Encoding UTF8 } else { $req = "" }
if ($req -notmatch '(?m)^\s*ibapi\b')        { $req += "`nibapi==9.81.1.post1" }
if ($req -notmatch '(?m)^\s*ruamel\.yaml\b') { $req += "`nruamel.yaml==0.18.14" }
if ($req -notmatch '(?m)^\s*ib_insync\b')    { $req += "`nib_insync==0.9.86" }
Set-Content -Path $reqPath -Encoding UTF8 -Value ($req.Trim()+"`n")

# 7) Build & run
docker compose build app
docker compose up -d
docker compose logs -f app
