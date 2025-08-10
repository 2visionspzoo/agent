# ibkr_adapter.py
import os, logging
from typing import Dict, Any
from ib_insync import IB, util, Contract

log = logging.getLogger("ibkr")

def connect_ib() -> IB:
    host = os.getenv("IBKR_HOST", "127.0.0.1")
    port = int(os.getenv("IBKR_PORT", "4003"))
    client_id = int(os.getenv("IBKR_CLIENT_ID", "1"))
    util.startLoop()
    ib = IB()
    ib.connect(host, port, clientId=client_id, timeout=60)
    t = ib.reqCurrentTime()
    log.info(f"Connected to IB at {host}:{port} (clientId={client_id}), serverTime={t}")
    return ib

def _normalize_mapping(m: Dict[str, Any]) -> Dict[str, Any]:
    d = dict(m)
    sec = (d.get("secType") or "").upper()
    d["secType"] = sec
    sym = d.get("symbol")

    # FX: "USDJPY" -> symbol=USD, currency=JPY, exchange=IDEALPRO
    if sec == "CASH" and sym and len(sym) >= 6 and sym[:3].isalpha() and sym[-3:].isalpha():
        d["symbol"] = sym[:3].upper()
        d["currency"] = sym[-3:].upper()
        d["exchange"] = d.get("exchange") or "IDEALPRO"

    # Metale spot: "XAUUSD" -> XAU / USD
    if sec == "CMDTY" and sym and len(sym) >= 6:
        base, quote = sym[:3].upper(), sym[-3:].upper()
        if base in {"XAU","XAG","XPT","XPD"} and quote.isalpha():
            d["symbol"] = base
            d["currency"] = quote

    if not d.get("exchange"):
        d["exchange"] = "SMART"
    return d

def contract_from_mapping(m: Dict[str, Any]) -> Contract:
    """
    Zamienia wpis z config/symbols.yaml na obiekt Contract.
    Jeśli dostępny jest conId – używa go w pierwszej kolejności.
    """
    d = _normalize_mapping(m)
    c = Contract()
    conId = d.get("conId")
    if conId not in (None, "", 0):
        try:
            c.conId = int(conId)
        except Exception:
            pass
    c.secType  = d.get("secType")
    c.symbol   = d.get("symbol")
    c.currency = d.get("currency")
    c.exchange = d.get("exchange")
    if c.secType == "FUT" and d.get("lastTradeDateOrContractMonth"):
        c.lastTradeDateOrContractMonth = str(d["lastTradeDateOrContractMonth"])
    return c

def get_bars(ib: IB, contract: Contract, duration="30 D", barSize="1 hour", whatToShow="TRADES"):
    # Kwalifikacja kontraktu (ważne przy conId-only)
    try:
        qualified = ib.qualifyContracts(contract)
        if not qualified:
            log.warning("qualifyContracts() zwróciło pustą listę; kontynuuję z podanym kontraktem.")
    except Exception as e:
        log.warning(f"qualifyContracts() błąd: {e}; kontynuuję z podanym kontraktem.")

    bars = ib.reqHistoricalData(
        contract=contract,
        endDateTime='',
        durationStr=duration,
        barSizeSetting=barSize,
        whatToShow=whatToShow,
        useRTH=False,
        formatDate=1,
        keepUpToDate=False
    )
    if not bars:
        raise RuntimeError("Brak świec. Sprawdź kontrakt/rynek/subskrypcje.")
    return bars
