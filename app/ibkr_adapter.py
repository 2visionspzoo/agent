# ibkr_adapter.py
import os, logging
from ib_insync import IB, util, Contract

log = logging.getLogger("ibkr")

def connect_ib():
    host = os.getenv("IBKR_HOST", "127.0.0.1")
    port = int(os.getenv("IBKR_PORT", "4003"))
    client_id = int(os.getenv("IBKR_CLIENT_ID", "1"))

    util.startLoop()
    ib = IB()
    ib.connect(host, port, clientId=client_id, timeout=60)
    t = ib.reqCurrentTime()
    log.info(f"Connected to IB at {host}:{port} (clientId={client_id}), serverTime={t}")
    return ib

def contract_from_cfg(ib: IB, cfg: dict) -> Contract:
    """
    Preferuj conId. W przeciwnym wypadku budujemy Contract z pól:
    secType, symbol, exchange, currency, lastTradeDateOrContractMonth (dla FUT), itd.
    """
    if cfg.get("conId"):
        c = Contract(conId=int(cfg["conId"]), exchange=cfg.get("exchange","SMART"))
    else:
        c = Contract(
            secType=cfg.get("secType","CASH"),
            symbol=cfg["symbol"],
            exchange=cfg.get("exchange","SMART"),
            currency=cfg.get("currency","USD"),
            lastTradeDateOrContractMonth=cfg.get("lastTradeDateOrContractMonth")
        )
    cds = ib.qualifyContracts(c)
    if not cds:
        raise RuntimeError(f"Nie znaleziono/zakwalifikowano kontraktu dla {cfg}")
    return cds[0]

def get_bars(ib: IB, contract: Contract, duration="30 D", barSize="1 hour", whatToShow="TRADES"):
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
