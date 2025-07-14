# main.py

import asyncio
import logging
import time
import threading

from userbot import run_userbot
from queue_manager import process_signal_queue

def queue_loop():
    """
    Folyamatosan figyeli és küldi a signalokat az EA-nak.
    """
    while True:
        process_signal_queue()
        time.sleep(0.5)

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    logging.getLogger('telethon').setLevel(level=logging.WARNING)
    # Indítunk egy szálat a queue figyelésre
    t = threading.Thread(target=queue_loop, daemon=True)
    t.start()

    # Futtatjuk az userbotot
    asyncio.run(run_userbot())

