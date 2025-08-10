import pandas as pd
import numpy as np
from ta.trend import ema_indicator
from ta.volatility import AverageTrueRange

def bars_to_df(bars):
    # ib_insync -> pandas
    df = pd.DataFrame([{
        "date": b.date,
        "open": b.open,
        "high": b.high,
        "low": b.low,
        "close": b.close,
        "volume": b.volume
    } for b in bars])
    df.set_index(pd.to_datetime(df["date"]), inplace=True)
    df.drop(columns=["date"], inplace=True)
    return df

def compute_indicators(df, ema_fast=50, ema_slow=200, atr_period=14):
    df = df.copy()
    df["ema_fast"] = ema_indicator(df["close"], window=ema_fast, fillna=False)
    df["ema_slow"] = ema_indicator(df["close"], window=ema_slow, fillna=False)
    atr = AverageTrueRange(df["high"], df["low"], df["close"], window=atr_period, fillna=False)
    df["atr"] = atr.average_true_range()
    return df

def simple_trend_signal(df):
    """
    Sygnał demo (long):
    - close > ema_fast > ema_slow
    - ostatnia świeca zamknięta powyżej ema_fast
    """
    last = df.iloc[-1]
    if last["close"] > last["ema_fast"] > last["ema_slow"]:
        # entry = close; SL = 1.25*ATR; TP1/TP2 = 1x/2x ATR
        atr = last["atr"]
        entry = float(last["close"])
        sl = entry - 1.25 * float(atr)
        tp1 = entry + 1.0 * float(atr)
        tp2 = entry + 2.0 * float(atr)
        return {
            "side": "BUY",
            "entry": round(entry, 5),
            "sl": round(sl, 5),
            "tp1": round(tp1, 5),
            "tp2": round(tp2, 5),
            "atr": float(atr)
        }
    return None
