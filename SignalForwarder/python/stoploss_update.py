# --- stoploss_update.py (Updated - Assumes this structure) ---
import re
import os
import traceback

try:
    from config import STOPLOSS_UPDATE_FILE_PATH
except ImportError:
    print("Hiba: config.py/STOPLOSS_UPDATE_FILE_PATH hiányzik.")
    STOPLOSS_UPDATE_FILE_PATH = "stoploss_update.txt"

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
                print(f"DEBUG SL Extract: Price '{price_str}' from '{text}'")
                return price_str
    print(f"DEBUG SL Extract: No price found in '{text}'")
    return None

def process_stoploss_reply(reply_text, original_text, group_id):
    """
    Processes SL adjustment reply, expects GID, writes command file.
    Output format: "GID:XXX|NEW_SL:YYY.YY"
    """
    print(f"DEBUG SL Process: GID={group_id}, Reply='{reply_text}'")
    if not isinstance(group_id, int) or group_id <= 0:
        print(f"Hiba SL Process: Érvénytelen group_id: {group_id}")
        return None

    new_sl_value_str = extract_price_from_text(reply_text)
    if not new_sl_value_str:
        print(f"Hiba SL Process: Új SL kinyerése sikertelen: '{reply_text}'")
        return None

    try:
        # Basic validation
        new_sl_float = float(new_sl_value_str)
        if new_sl_float <= 0: print(f"Warning SL Process: Extracted SL {new_sl_float} not positive.")
        new_sl_value_formatted = new_sl_value_str # Use as extracted
    except ValueError:
         print(f"Hiba SL Process: Kinyert érték '{new_sl_value_str}' nem szám.")
         return None

    command = f"GID:{group_id}|NEW_SL:{new_sl_value_formatted}"

    try:
        with open(STOPLOSS_UPDATE_FILE_PATH, "w", encoding='utf-8') as f:
            f.write(command)
        print(f"✅ SL Update parancs kiírva ('{os.path.basename(STOPLOSS_UPDATE_FILE_PATH)}'): {command}")
        return command
    except IOError as e:
        print(f"❌ Hiba SL Update parancs írásakor ('{STOPLOSS_UPDATE_FILE_PATH}'): {e}")
        return None
    except Exception as e:
        print(f"❌ Váratlan Hiba SL Update parancs írásakor: {e}")
        traceback.print_exc()
        return None