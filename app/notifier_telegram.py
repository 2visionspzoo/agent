import os, requests

BOT = os.getenv("TELEGRAM_BOT_TOKEN")
CHAT = os.getenv("TELEGRAM_CHAT_ID")

def _post(payload: dict):
    if not BOT or not CHAT:
        print("Brak TELEGRAM_BOT_TOKEN/CHAT_ID")
        return
    url = f"https://api.telegram.org/bot{BOT}/sendMessage"
    r = requests.post(url, data=payload, timeout=10)
    if r.status_code >= 300:
        print("Telegram error:", r.status_code, r.text[:300])

def send_text(msg: str):
    # ZWYKŁY TEKST – bez parse_mode (bez HTML/Markdown) -> bezpieczne dla tracebacków
    _post({"chat_id": CHAT, "text": msg, "disable_web_page_preview": True})

def send_html(msg: str):
    # Tekst formatowany HTML – używamy tylko dla czytelnych kart sygnałów
    _post({"chat_id": CHAT, "text": msg, "parse_mode": "HTML", "disable_web_page_preview": True})

def send_signal_card(symbol: str, signal: dict):
    text = (
        f"<b>{symbol}</b> – <b>{signal['side']}</b>\n"
        f"Entry: <code>{signal['entry']}</code>\n"
        f"SL: <code>{signal['sl']}</code>\n"
        f"TP1: <code>{signal['tp1']}</code>  |  TP2: <code>{signal['tp2']}</code>\n"
        f"ATR: <code>{round(signal['atr'],5)}</code>\n"
        f"\nPotwierdź ręcznie w TWS lub przejdziemy do pół-auto po teście."
    )
    send_html(text)
