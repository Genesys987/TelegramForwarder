# -*- coding: utf-8 -*-
"""
queue_manager.py

Feladata:
- A parsed (feldolgozott) signal_data adatait a queue-ba (fájlból) írja (add_signal_to_queue).
- A queue tartalmát pedig (process_signal_queue) átemeli a signals.txt-be, ha az EA éppen nem használja,
  vagyis ha a signals.txt nem létezik.

Változtatások / Refaktorálás:
- Részletes docstringek
- Hibakezelés bővítése
- Extra log beépítése, ha mégis lenne valami furcsa karakter a kiírt sorokban
- Minimális formátum-ellenőrzés a queue-ba íráskor
- Mindkét függvényben robust logolás, traceback, rövid kommentek
"""
import os
import time
import traceback
import json
from config import MT4_QUEUE_FILE_PATH, MT4_SIGNAL_FILE_PATH

def add_signal_to_queue(signal_data: dict) -> bool:
    """
    Feladata, hogy a 'signal_data' dict tartalmából elkészítse azt a sort,
    amit a queue-fájlba (MT4_QUEUE_FILE_PATH) fűz hozzá.
    A paraméterekből létrehoz egy 'message' stringet:
      "{timestamp_utc}|{signal_type}|{symbol}|{entry}|{tp1,tp2,tp3}|{stop_loss}|{lot_size}|GID:{group_id}"

    Kötelező kulcsok a 'signal_data'-ban:
      - timestamp_utc: int (UTC timestamp in milliseconds)
      - signal_type: str (BUY/SELL)
      - symbol: str pl. "XAUUSD"
      - entry: float
      - take_profits: list (>=3 elem), pl. [3219,3217,3215]
      - stop_loss: float
      - lot_size: float
      - group_id: int  (Python generálja)

    Visszatér:
      True, ha sikeres
      False, ha hiba történt vagy hiányos adatok
    """
    try:
        # 1) Alap ellenőrzés
        required_keys = ["timestamp_utc", "signal_type", "symbol", "entry", "take_profits",
                         "stop_loss", "lot_size", "group_id"]
        if not all(key in signal_data for key in required_keys):
            print(f"❌ [QueueAdd] Hiányzó kulcsok. Van: {list(signal_data.keys())}, Kellene: {required_keys}")
            return False

        # 2) TPs ellenőrzés
        tps = signal_data["take_profits"]
        if not isinstance(tps, list) or len(tps) < 3:
            print(f"❌ [QueueAdd] Érvénytelen take_profits: {tps}")
            return False

        # 3) Timestamp ellenőrzés
        timestamp_ms = signal_data["timestamp_utc"]
        if not isinstance(timestamp_ms, int) or timestamp_ms <= 0:
            print(f"❌ [QueueAdd] Érvénytelen timestamp: {timestamp_ms}")
            return False

        # 4) Sor összerakása timestamp-pel kezdve (prefix nélkül)
        tp_str = ",".join(str(tp) for tp in tps)
        message = (f"{timestamp_ms}|{signal_data['signal_type']}|{signal_data['symbol']}|{signal_data['entry']}|"
                   f"{tp_str}|{signal_data['stop_loss']}|{signal_data['lot_size']}|"
                   f"GID:{signal_data['group_id']}\n")

        # 5) I/O művelet: Hozzáfűzés a queue-fájlhoz
        with open(MT4_QUEUE_FILE_PATH, "a", encoding='utf-8') as f:
            f.write(message)

        # Logolás
        print(f"✅ [QueueAdd] Hozzáadva a queue fájlhoz ('{os.path.basename(MT4_QUEUE_FILE_PATH)}'): {message.strip()}")
        return True

    except Exception as e:
        print(f"❌ [QueueAdd] Végzetes hiba: {e}")
        traceback.print_exc()
        return False


def process_signal_queue() -> None:
    """
    Feladata, hogy a queue-fájlból kivesz egy (nem üres) sort,
    és ha a signals.txt nem létezik (vagyis az EA nincs épp busy), akkor
    azt a sort beírja a signals.txt-be, majd kiveszi a queue-fájlból.

    További részletek:
    - Ha a queue üres, vagy nincs érvényes sor, kilép
    - Ha a signals.txt már létezik, nem ír bele semmit (EA még dolgozza fel?), kilép
    - Ha van érvényes sor, beírja a signals.txt-be, a queue-ból pedig törli azt a sort
    """
    try:
        # 1) Gyors ellenőrzés: queue létezik-e, van-e benne tartalom
        if not os.path.exists(MT4_QUEUE_FILE_PATH) or os.path.getsize(MT4_QUEUE_FILE_PATH) == 0:
            return  # Nincs semmi a queue-ban
        # 2) signals.txt létezésének ellenőrzése
        if os.path.exists(MT4_SIGNAL_FILE_PATH):
            # Az EA még valószínűleg nem dolgozta fel az előző jelet
            return

        lines = []
        next_signal = None
        first_valid_line_index = -1

        # 3) Beolvassuk a queue file sorait
        with open(MT4_QUEUE_FILE_PATH, "r", encoding='utf-8') as f:
            lines = f.readlines()
        if not lines:  # semmi nincs benne
            return

        # 4) Megkeressük az első nem üres sort
        for i, line in enumerate(lines):
            line_stripped = line.strip()
            if line_stripped:
                next_signal = line_stripped
                first_valid_line_index = i
                break

        if next_signal is None:
            # minden sor üres, akkor resetelhetjük a file-t
            if all(not line.strip() for line in lines):
                open(MT4_QUEUE_FILE_PATH, 'w', encoding='utf-8').close()
            return

        # 5) Megpróbáljuk írni a signals.txt-be
        # Ha közben a signals.txt létrejött, azaz az EA (vagy más) is...
        # de a fenti if ezt már lekezelte, feltételezzük, hogy most még nincs signals.txt
        try:
            with open(MT4_SIGNAL_FILE_PATH, "w", encoding='utf-8') as f:
                f.write(next_signal)
        except IOError as e:
            print(f"❌ [Queue->EA] Hiba signals.txt írásnál: {e}")
            return

        # 6) Töröljük az első érvényes sort a queue-ból
        try:
            with open(MT4_QUEUE_FILE_PATH, "w", encoding='utf-8') as f:
                if first_valid_line_index + 1 < len(lines):
                    f.writelines(lines[first_valid_line_index + 1:])
            print(f"📤 [Queue->EA] Szignál -> EA fájl ('{os.path.basename(MT4_SIGNAL_FILE_PATH)}'): {next_signal}")
        except IOError as e:
            print(f"❌ [QueueUpdate] Kritikus hiba a queue frissítésnél: {e}")
            return

    except Exception as e:
        print(f"❌ [QueueProc] Általános hiba a queue feldolgozásakor: {e}")
        traceback.print_exc()
