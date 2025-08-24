# --- stoploss_update.py (Updated - Assumes this structure) ---
import re
import os
import traceback
import logging

logger = logging.getLogger(__name__)

try:
    from config import STOPLOSS_UPDATE_FILE_PATHS
except ImportError:
    logger.error("Hiba: config.py/STOPLOSS_UPDATE_FILE_PATH hiányzik.")
    STOPLOSS_UPDATE_FILE_PATHS = "stoploss_update.txt"

# Helper function (copied from userbot refactoring)
def extract_price_from_text(text):
    patterns = [
        r"(?:SL|Stop\s*loss|Adjust)\s*(?:on\s+\w+)?\s*(?:to|at|is|here)?\s*:?\s*([\d]+\.?[\d]*)",
        r"([\d]+\.?[\d]*)"
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match and match.group(1):
            price_str = match.group(1)
            if re.fullmatch(r"[\d]+\.?[\d]*", price_str) and "." != price_str:
                logger.debug(f"SL Extract: Price '{price_str}' from '{text}'")
                return price_str
    logger.debug(f"SL Extract: No price found in '{text}'")
    return None

def process_stoploss_reply(reply_text, original_text, group_id):
    logger.info(f"SL Process: GID={group_id}, Reply='{reply_text}'")
    if not isinstance(group_id, int) or group_id <= 0:
        logger.error(f"Hiba SL Process: Érvénytelen group_id: {group_id}")
        return None

    new_sl_value_str = extract_price_from_text(reply_text)
    if not new_sl_value_str:
        logger.error(f"Hiba SL Process: Új SL kinyerése sikertelen: '{reply_text}'")
        return None

    try:
        # Basic validation
        new_sl_float = float(new_sl_value_str)
        if new_sl_float <= 0: logger.warning(f"Warning SL Process: Extracted SL {new_sl_float} not positive.")
        new_sl_value_formatted = new_sl_value_str # Use as extracted
    except ValueError:
         logger.error(f"Hiba SL Process: Kinyert érték '{new_sl_value_str}' nem szám.")
         return None

    # Use new format: xxxx|NEW_SL:value (without GID: prefix)
    command = f"{group_id}|NEW_SL:{new_sl_value_formatted}"

    try:
        # Write to all stoploss update files
        success = True
        for sl_path in STOPLOSS_UPDATE_FILE_PATHS:
            try:
                with open(sl_path, "w", encoding='utf-8') as f:
                    f.write(command)
                logger.info(f"✅ SL Update parancs kiírva ('{os.path.basename(sl_path)}'): {command}")
            except IOError as e:
                logger.error(f"❌ Hiba SL Update parancs írásakor ('{sl_path}'): {e}")
                success = False
        
        return command if success else None
    except Exception as e:
        logger.error(f"❌ Váratlan Hiba SL Update parancs írásakor: {e}")
        traceback.print_exc()
        return None
