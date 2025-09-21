# -*- coding: utf-8 -*-
"""
queue_manager.py

Feladata:
- A parsed (feldolgozott) signal_data adatait a queue-ba (fájlból) írja (add_signal_to_queue).
- A queue tartalmát pedig (process_signal_queue) átemeli a signals.txt-be, ha az EA éppen nem használja,
  vagyis ha a signals.txt nem létezik.
"""
import os
import traceback
import logging
from config import MT4_QUEUE_FILE_PATHS, MT4_SIGNAL_FILE_PATHS
from signal_parser import clean_channel_name
from datetime import datetime

logger = logging.getLogger(__name__)

def _write_signal_archive(message: str) -> None:
    """
    Writes the given message to the daily signals archive file.
    """
    current_date = datetime.now().strftime("%Y%m%d")
    archive_path = os.path.join(os.getcwd(), "logs", f"signals_archive_{current_date}.txt")
    try:
        with open(archive_path, "a", encoding='utf-8') as f:
            f.write(message)
    except Exception as e:
        logger.error(f"❌ [QueueAdd] Hiba az archív fájl írásakor ({archive_path}): {e}")

def write_message_to_queue(message: str) -> bool:
    """
    Writes the given message to all MT4 queue files.
    Returns True if all writes succeed, False otherwise.
    """
    _write_signal_archive(message)  # Archive the signal
    for queue_path in MT4_QUEUE_FILE_PATHS:
        try:
            with open(queue_path, "a", encoding='utf-8') as f:
                f.write(message)
            logger.info(f"✅ [QueueAdd] Hozzáadva a queue fájlhoz ('{os.path.basename(queue_path)}'): {message.strip()}")
        except Exception as e:
            logger.error(f"❌ [QueueAdd] Hiba a queue fájl írásakor ({queue_path}): {e}")
            return False
    return True

def add_signal_to_queue(signal_data: dict) -> bool:
    """
    Feladata, hogy a 'signal_data' dict tartalmából elkészítse azt a sort,
    amit a queue-fájlba (MT4_QUEUE_FILE_PATH) fűz hozzá.
    
    Támogatott signal típusok:
    - BUY/SELL: "{timestamp_utc}|{signal_type}|{symbol}|{entry}|{tp1,tp2,tp3}|{stop_loss}|GID:{group_id}|{channel_name}"
    - MODIFY_SL: "{timestamp_utc}|MODIFY|{new_sl}|GID:{group_id}|{channel_name}"
    - MODIFY_TP: "{timestamp_utc}|MODIFY_TP{level}|{new_tp}|GID:{group_id}|{channel_name}"

    Kötelező kulcsok BUY/SELL signalokhoz:
      - timestamp_utc, signal_type, symbol, entry, take_profits, stop_loss, group_id, channel_name

    Kötelező kulcsok MODIFY signalokhoz:
      - timestamp_utc, signal_type, group_id, channel_name
      - new_sl (MODIFY_SL esetén) vagy new_tp + tp_level (MODIFY_TP esetén)

    Visszatér:
      True, ha sikeres
      False, ha hiba történt vagy hiányos adatok
    """
    try:
        # 1) Common validation for all signal types
        common_keys = ["timestamp_utc", "signal_type", "group_id", "channel_name"]
        if not all(key in signal_data for key in common_keys):
            logger.error(f"❌ [QueueAdd] Hiányzó alapvető kulcsok. Van: {list(signal_data.keys())}, Kellene: {common_keys}")
            return False

        # 2) Timestamp ellenőrzés
        timestamp = signal_data["timestamp_utc"]
        if not isinstance(timestamp, int) or timestamp <= 0:
            logger.error(f"❌ [QueueAdd] Érvénytelen timestamp: {timestamp}")
            return False

        signal_type = signal_data["signal_type"].upper()
        raw_channel_name = signal_data.get("channel_name", "UNKNOWN")
        channel_name = clean_channel_name(raw_channel_name)  # Clean to 4-letter format
        
        # 3) Signal type specific processing
        if signal_type in ["BUY", "SELL"]:
            # Traditional trading signal
            trading_keys = ["symbol", "entry", "take_profits", "stop_loss"]
            if not all(key in signal_data for key in trading_keys):
                logger.error(f"❌ [QueueAdd] Hiányzó trading signal kulcsok. Van: {list(signal_data.keys())}, Kellene: {trading_keys}")
                return False

            # TPs ellenőrzés - support any number of TPs (minimum 1)
            tps = signal_data["take_profits"]
            if not isinstance(tps, list) or len(tps) < 1:
                logger.error(f"❌ [QueueAdd] Érvénytelen take_profits: {tps}")
                return False

            # Standard trading signal format
            tp_str = ",".join(str(tp) for tp in tps)
            message = (f"{timestamp}|{signal_type}|{signal_data['symbol']}|{signal_data['entry']}|"
                       f"{tp_str}|{signal_data['stop_loss']}|"
                       f"GID:{signal_data['group_id']}|{channel_name}\n")

        elif signal_type == "MODIFY_SL":
            # SL modification signal
            if "new_sl" not in signal_data:
                logger.error(f"❌ [QueueAdd] Hiányzó new_sl kulcs MODIFY_SL signalhoz")
                return False
            
            # MODIFY signal format: timestamp|MODIFY|new_sl|GID:xxx|channel
            message = (f"{timestamp}|MODIFY|{signal_data['new_sl']}|"
                       f"GID:{signal_data['group_id']}|{channel_name}\n")

        elif signal_type.startswith("MODIFY_TP"):
            # TP modification signal  
            if "new_tp" not in signal_data or "tp_level" not in signal_data:
                logger.error(f"❌ [QueueAdd] Hiányzó new_tp vagy tp_level kulcs MODIFY_TP signalhoz")
                return False
            
            # For now, we'll use the MODIFY format for TP changes too
            # The EA can be enhanced later to handle TP modifications specifically
            message = (f"{timestamp}|MODIFY_TP{signal_data['tp_level']}|{signal_data['new_tp']}|"
                       f"GID:{signal_data['group_id']}|{channel_name}\n")

        else:
            logger.error(f"❌ [QueueAdd] Ismeretlen signal típus: {signal_type}")
            return False

        logger.info(f"🔄 [QueueAdd] {signal_type} signal formázva csatorna névvel '{channel_name}' (eredeti: '{raw_channel_name}'): GID:{signal_data['group_id']}")

        # 4) I/O művelet: Hozzáfűzás az összes queue-fájlhoz
        return write_message_to_queue(message)

    except Exception as e:
        logger.error(f"❌ [QueueAdd] Végzetes hiba: {e}")
        traceback.print_exc()
        return False


def process_signal_queue() -> None:
    """
    Feladata, hogy a queue-fájlokból kivesz egy (nem üres) sort,
    és ha a megfelelő signals.txt nem létezik (vagyis az EA nincs épp busy), akkor
    azt a sort beírja a signals.txt-be, majd kiveszi a queue-fájlból.

    További részletek:
    - Ha egy queue üres, vagy nincs érvényes sor, azzal nem foglalkozik
    - Ha a signals.txt már létezik, nem ír bele semmit (EA még dolgozza fel?), továbblép
    - Ha van érvényes sor, beírja a signals.txt-be, a queue-ból pedig törli azt a sort
    - Minden MT4 queue-t végignéz és feldolgoz
    """
    try:
        # Végigmegyünk minden MT4 queue-n és megfelelő signal fájlon
        for i, (queue_path, signal_path) in enumerate(zip(MT4_QUEUE_FILE_PATHS, MT4_SIGNAL_FILE_PATHS)):
            try:
                # 1) Gyors ellenőrzés: queue létezik-e, van-e benne tartalom
                if not os.path.exists(queue_path) or os.path.getsize(queue_path) == 0:
                    continue  # Nincs semmi ebben a queue-ban, következő
                    
                # 2) signals.txt létezésének ellenőrzése
                if os.path.exists(signal_path):
                    # Az EA még valószínűleg nem dolgozta fel az előző jelet, következő
                    continue

                lines = []
                next_signal = None
                first_valid_line_index = -1

                # 3) Beolvassuk a queue file sorait
                with open(queue_path, "r", encoding='utf-8') as f:
                    lines = f.readlines()
                if not lines:  # semmi nincs benne
                    continue

                # 4) Megkeressük az első nem üres sort
                for j, line in enumerate(lines):
                    line_stripped = line.strip()
                    if line_stripped:
                        next_signal = line_stripped
                        first_valid_line_index = j
                        break

                if next_signal is None:
                    # minden sor üres, akkor resetelhetjük a file-t
                    if all(not line.strip() for line in lines):
                        open(queue_path, 'w', encoding='utf-8').close()
                    continue

                # 5) Megpróbáljuk írni a signals.txt-be
                # Ha közben a signals.txt létrejött, azaz az EA (vagy más) is...
                # de a fenti if ezt már lekezelte, feltételezzük, hogy most még nincs signals.txt
                try:
                    with open(signal_path, "w", encoding='utf-8') as f:
                        f.write(next_signal)
                except IOError as e:
                    logger.error(f"❌ [Queue->EA] Hiba signals.txt írásnál ({signal_path}): {e}")
                    continue

                # 6) Töröljük az első érvényes sort a queue-ból
                try:
                    with open(queue_path, "w", encoding='utf-8') as f:
                        if first_valid_line_index + 1 < len(lines):
                            f.writelines(lines[first_valid_line_index + 1:])
                    logger.info(f"📤 [Queue->EA] Szignál ('{os.path.basename(queue_path)}') -> EA fájl ('{signal_path}'): {next_signal}")
                except IOError as e:
                    logger.error(f"❌ [QueueUpdate] Kritikus hiba a queue frissítésnél ({queue_path}): {e}")
                    continue
                    
            except Exception as e:
                logger.error(f"❌ [QueueProc] Hiba az {i+1}. MT4 queue feldolgozásakor ({queue_path}): {e}")
                continue

    except Exception as e:
        logger.error(f"❌ [QueueProc] Általános hiba a queue feldolgozásakor: {e}")
        traceback.print_exc()
