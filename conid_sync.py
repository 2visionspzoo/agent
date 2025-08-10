# agent/conid_sync.py
import threading, datetime as dt
import time  # DODANO: Dla opóźnienia po disconnect
from typing import Dict, Any, List, Optional
from pathlib import Path

from ruamel.yaml import YAML
from ibapi.wrapper import EWrapper
from ibapi.client import EClient
from ibapi.contract import Contract, ContractDetails

yaml = YAML()
yaml.preserve_quotes = True

# ------ preferencje projektu ------
OVERRIDES = {
    # Wymuś CFD na starcie:
    "US100":   {"secType": "CFD", "exchange": "SMART", "currency": "USD"},
    "OIL.WTI": {"secType": "CFD", "exchange": "SMART", "currency": "USD"},
}

# ------ normalizacja pod IB ------
def normalize_entry(key: str, d: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(d)
    # globalne/wymuszone nadpisania
    if key in OVERRIDES:
        out.update({k: v for k, v in OVERRIDES[key].items() if v})

    # ujednolicenia
    out["secType"] = (out.get("secType") or "").upper()
    if not out.get("exchange"):
        out["exchange"] = "SMART"

    # FX: USDJPY -> symbol=USD, currency=JPY, IDEALPRO
    if out["secType"] == "CASH" and out.get("symbol") and len(out["symbol"]) >= 6:
        s = out["symbol"].upper()
        if s[:3].isalpha() and s[-3:].isalpha():
            out["symbol"] = s[:3]
            out["currency"] = s[-3:]
        out["exchange"] = "IDEALPRO"

    # Metale: XAUUSD/XAGUSD -> XAU/XAG + currency
    if out["secType"] == "CMDTY" and out.get("symbol") and len(out["symbol"]) >= 6:
        s = out["symbol"].upper()
        base, quote = s[:3], s[-3:]
        if base in {"XAU","XAG","XPT","XPD"} and quote.isalpha():
            out["symbol"] = base
            out["currency"] = quote

    return out

def to_contract(key: str, d: Dict[str, Any]) -> Contract:
    d = normalize_entry(key, d)
    c = Contract()
    if d.get("conId"):
        c.conId = int(d["conId"])
    c.secType = d.get("secType")
    c.symbol = d.get("symbol")
    c.exchange = d.get("exchange")
    c.currency = d.get("currency")
    if c.secType == "FUT" and d.get("lastTradeDateOrContractMonth"):
        c.lastTradeDateOrContractMonth = str(d["lastTradeDateOrContractMonth"])
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
    # FUT: preferuj najbliższy w przyszłości
    if sec == "FUT":
        ltd = cd.contract.lastTradeDateOrContractMonth or ""
        try:
            dt_obj = dt.datetime.strptime(ltd, "%Y%m%d") if len(ltd)==8 else (
                     dt.datetime.strptime(ltd, "%Y%m") if len(ltd)==6 else None)
            if dt_obj:
                days = (dt_obj - dt.datetime.utcnow()).days
                if days >= 0:
                    s += max(0, 100 - min(days, 100))
        except Exception:
            pass
    return s

def pick_best(want: Dict[str, Any], cds: List[ContractDetails]) -> Optional[ContractDetails]:
    if not cds: return None
    cds.sort(key=lambda cd: score_candidate(want, cd), reverse=True)
    return cds[0]

# ------ IB wrapper ------
class _Resolver(EWrapper, EClient):
    def __init__(self):
        EClient.__init__(self, self)
        self._next_ready = threading.Event()
        self._next_id = None
        self._lock = threading.Lock()
        self._done = {}
        self._res = {}
        self.errors: List[str] = []

    def nextValidId(self, orderId:int): self._next_id, self._next_ready = orderId, self._next_ready; self._next_ready.set()
    def error(self, reqId, code, msg, *_):
        if code in (200, 201): self.errors.append(f"[{reqId}] {code} {msg}")

    def contractDetails(self, reqId:int, cd:ContractDetails):
        with self._lock:
            self._res.setdefault(reqId, []).append(cd)

    def contractDetailsEnd(self, reqId:int):
        with self._lock:
            if reqId in self._done: self._done[reqId].set()

    def _get_req_id(self) -> int:
        if not self._next_ready.wait(10): raise RuntimeError("Brak nextValidId z TWS/Gateway")
        with self._lock:
            rid = self._next_id
            self._next_id += 1
            return rid

    def resolve(self, key: str, item: Dict[str, Any], timeout=12) -> Optional[ContractDetails]:
        c = to_contract(key, item)
        reqId = self._get_req_id()
        evt = threading.Event()
        with self._lock:
            self._done[reqId] = evt
            self._res[reqId] = []
        self.reqContractDetails(reqId, c)
        if not evt.wait(timeout): return None
        return pick_best(normalize_entry(key, item), self._res.get(reqId, []))

# ------ API: wywołuj przy starcie agenta ------
def ensure_conids(
    path="config/symbols.yaml",
    host="127.0.0.1",
    port=4003,
    client_id=123,
    save_in_place=True,
) -> bool:
    fp = Path(path)
    data = yaml.load(fp.read_text(encoding="utf-8"))

    app = _Resolver()
    app.connect(host, port, client_id)
    t = threading.Thread(target=app.run, daemon=True); t.start()
    if not app._next_ready.wait(10):
        raise RuntimeError("Nie połączono z IB Gateway/TWS (brak nextValidId).")

    changed = False
    for key, val in data.items():
        if not isinstance(val, dict): continue
        # wymuszenia dla US100/OIL.WTI już zastosuje normalize_entry (OVERRIDES)

        # Zawsze WERYFIKUJ już istniejący conId
        need_lookup = False
        if val.get("conId"):
            # Sprawdź czy conId odpowiada parametrom
            cd = app.resolve(key, val, timeout=10)
            if not cd or int(cd.contract.conId) != int(val["conId"]):
                need_lookup = True
        else:
            need_lookup = True

        if need_lookup:
            cd = app.resolve(key, val, timeout=15)
            if not cd:
                print(f"[{key}] Nie znaleziono kontraktu ({val.get('secType')} {val.get('symbol')}).")
                continue
            # Uzupełnij/podmień
            val["conId"] = int(cd.contract.conId)
            val["symbol"] = cd.contract.symbol
            val["exchange"] = cd.contract.exchange
            val["currency"] = cd.contract.currency
            if cd.contract.secType == "FUT":
                val["lastTradeDateOrContractMonth"] = cd.contract.lastTradeDateOrContractMonth
            changed = True
            print(f"[{key}] conId={val['conId']} | {cd.contract.secType} {val['symbol']}.{val['currency']} @ {val['exchange']}")

    try: app.disconnect()
    except: pass
    time.sleep(5)  # DODANO: Opóźnienie, aby serwer IB zwolnił clientId przed kolejnym połączeniem

    if changed and save_in_place:
        with open(fp, "w", encoding="utf-8") as f:
            yaml.dump(data, f)
        print(f"✓ Zaktualizowano {fp}")
    elif not changed:
        print("Brak zmian w symbolach (conId aktualne).")
    return changed

# Prosty CLI: python -m agent.conid_sync --in config/symbols.yaml
if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="path", default="config/symbols.yaml")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4003)
    ap.add_argument("--client", type=int, default=123)
    args = ap.parse_args()
    ensure_conids(args.path, args.host, args.port, args.client, save_in_place=True)