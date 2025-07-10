# signal_processor.py

import logging
from signal_parser import parse_signal
from queue_manager import add_signal_to_queue

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

def process_signal(text: str):
    """
    1) parse_signal: kinyeri a paramétereket
    2) lot méret számítása
    3) queue-ba helyezés
    """
    parsed = parse_signal(text)
    if not parsed:
        logging.warning(f"⚠️ Érvénytelen signal formátum: {text}")
        return

    # Kinyerjük az adatokat
    signal_type = parsed["signal_type"]
    symbol = parsed["symbol"]
    entry_price = parsed["entry"]
    take_profits = parsed["take_profits"]
    stop_loss = parsed["stop_loss"]

    # Végleges signal_data
    signal_data = {
        "signal_type": signal_type,
        "symbol": symbol,
        "entry": entry_price,
        "take_profits": take_profits,
        "stop_loss": stop_loss,
    }

    # Várólistához adás
    add_signal_to_queue(signal_data)
    logging.info(f"✅ Signal feldolgozva és queue-ba helyezve: {signal_data}")
