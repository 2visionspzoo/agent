from agent.conid_sync import ensure_conids

import os, time, logging, yaml
from ibkr_adapter import connect_ib, contract_from_mapping, get_bars
from ta_engine import bars_to_df, compute_indicators, simple_trend_signal
from notifier_telegram import send_text, send_signal_card

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("app")

def load_symbols():
    with open("config/symbols.yaml", "r", encoding="utf-8") as f:
        return yaml.safe_load(f)

def run_once():
    ib = connect_ib()
    symbols = load_symbols()

    # Na pierwszy test weźmy USDJPY (najpewniejszy mapping)
    sym = "USDJPY"
    m = symbols[sym]
    c = contract_from_mapping(ib, m["kind"], m["symbol"])
    bars = get_bars(ib, c, duration=m["duration"], barSize=m["barSize"], whatToShow=m["whatToShow"])

    df = bars_to_df(bars)
    df = compute_indicators(df)
    sig = simple_trend_signal(df)

    if sig:
        send_signal_card(sym, sig)
        log.info(f"Wysłano sygnał dla {sym}: {sig}")
    else:
        send_text(f"{sym}: brak sygnału (warunki nie spełnione).")
        log.info("Brak sygnału")

    ib.disconnect()

if __name__ == "__main__":
    send_text("✅ Agent: start aplikacji (test USDJPY)")
    while True:
        try:
            run_once()
        except Exception as e:
            import traceback
            tb = traceback.format_exc(limit=3)
            send_text(f"❌ Błąd run_once: {type(e).__name__}: {e}\n{tb}")
        # odpalaj co 15 minut
        time.sleep(900)
