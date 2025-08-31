# --- stoploss_update.py (Updated for signals.txt integration) ---
import re
import os
import traceback
import logging
import time

logger = logging.getLogger(__name__)

try:
    from config import MT4_SIGNAL_FILE_PATHS  # Use signals.txt instead of stoploss_update.txt
except ImportError:
    logger.error("Hiba: config.py/MT4_SIGNAL_FILE_PATHS hiányzik.")
    MT4_SIGNAL_FILE_PATHS = ["signals.txt"]

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

def process_stoploss_reply(reply_text, original_text, group_id, channel_name="UNKN"):
    logger.info(f"SL Process: GID={group_id}, Channel={channel_name}, Reply='{reply_text}'")
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
        if new_sl_float <= 0: 
            logger.warning(f"Warning SL Process: Extracted SL {new_sl_float} not positive.")
        new_sl_value_formatted = new_sl_value_str # Use as extracted
    except ValueError:
         logger.error(f"Hiba SL Process: Kinyert érték '{new_sl_value_str}' nem szám.")
         return None

    # Create new unified signal format: TIMESTAMP|MODIFY|NEW_SL|GID:xxxx|CHANNEL
    timestamp = int(time.time())
    signal_line = f"{timestamp}|MODIFY|{new_sl_value_formatted}|GID:{group_id}|{channel_name}"

    try:
        # Write to all signal files
        success = True
        for signal_path in MT4_SIGNAL_FILE_PATHS:
            try:
                # Ensure the directory exists
                os.makedirs(os.path.dirname(signal_path), exist_ok=True)
                
                # Write with explicit flush to ensure immediate write
                with open(signal_path, "w", encoding='utf-8') as f:
                    f.write(signal_line)
                    f.flush()
                    os.fsync(f.fileno())  # Force write to disk
                    
                logger.info(f"✅ MODIFY signal kiírva ('{os.path.basename(signal_path)}'): {signal_line}")
            except IOError as e:
                logger.error(f"❌ Hiba MODIFY signal írásakor ('{signal_path}'): {e}")
                success = False
        
        return signal_line if success else None
    except Exception as e:
        logger.error(f"❌ Váratlan Hiba MODIFY signal írásakor: {e}")
        traceback.print_exc()
        return None

def process_breakeven_signal(group_id, channel_name="UNKN"):
    """Create a BREAKEVEN signal for MT4"""
    logger.info(f"Breakeven Process: GID={group_id}, Channel={channel_name}")
    
    if not isinstance(group_id, int) or group_id <= 0:
        logger.error(f"Hiba Breakeven Process: Érvénytelen group_id: {group_id}")
        return None

    # Create BREAKEVEN signal format: TIMESTAMP|BREAKEVEN|GID:xxxx|CHANNEL
    timestamp = int(time.time())
    signal_line = f"{timestamp}|BREAKEVEN|GID:{group_id}|{channel_name}"

    try:
        # Write to all signal files
        success = True
        for signal_path in MT4_SIGNAL_FILE_PATHS:
            try:
                # Ensure the directory exists
                os.makedirs(os.path.dirname(signal_path), exist_ok=True)
                
                # Write with explicit flush to ensure immediate write
                with open(signal_path, "w", encoding='utf-8') as f:
                    f.write(signal_line)
                    f.flush()
                    os.fsync(f.fileno())  # Force write to disk
                    
                logger.info(f"✅ BREAKEVEN signal kiírva ('{os.path.basename(signal_path)}'): {signal_line}")
            except IOError as e:
                logger.error(f"❌ Hiba BREAKEVEN signal írásakor ('{signal_path}'): {e}")
                success = False
        
        return signal_line if success else None
    except Exception as e:
        logger.error(f"❌ Váratlan Hiba BREAKEVEN signal írásakor: {e}")
        traceback.print_exc()
        return None

def process_close_signal(group_id, channel_name="UNKN"):
    """Create a CLOSE signal for MT4"""
    logger.info(f"Close Process: GID={group_id}, Channel={channel_name}")
    
    if not isinstance(group_id, int) or group_id <= 0:
        logger.error(f"Hiba Close Process: Érvénytelen group_id: {group_id}")
        return None

    # Create CLOSE signal format: TIMESTAMP|CLOSE|GID:xxxx|CHANNEL
    timestamp = int(time.time())
    signal_line = f"{timestamp}|CLOSE|GID:{group_id}|{channel_name}"

    try:
        # Write to all signal files
        success = True
        for signal_path in MT4_SIGNAL_FILE_PATHS:
            try:
                # Ensure the directory exists
                os.makedirs(os.path.dirname(signal_path), exist_ok=True)
                
                # Write with explicit flush to ensure immediate write
                with open(signal_path, "w", encoding='utf-8') as f:
                    f.write(signal_line)
                    f.flush()
                    os.fsync(f.fileno())  # Force write to disk
                    
                logger.info(f"✅ CLOSE signal kiírva ('{os.path.basename(signal_path)}'): {signal_line}")
            except IOError as e:
                logger.error(f"❌ Hiba CLOSE signal írásakor ('{signal_path}'): {e}")
                success = False
        
        return signal_line if success else None
    except Exception as e:
        logger.error(f"❌ Váratlan Hiba CLOSE signal írásakor: {e}")
        traceback.print_exc()
        return None

def process_close_and_breakeven_signal(group_id, channel_name="UNKN"):
    """Create a CLOSE_HALF_BREAKEVEN signal for MT4 - close half orders, breakeven the rest"""
    logger.info(f"Close+Breakeven Process: GID={group_id}, Channel={channel_name}")
    
    if not isinstance(group_id, int) or group_id <= 0:
        logger.error(f"Hiba Close+Breakeven Process: Érvénytelen group_id: {group_id}")
        return None

    # Create CLOSE_HALF_BREAKEVEN signal format: TIMESTAMP|CLOSE_HALF_BREAKEVEN|GID:xxxx|CHANNEL
    timestamp = int(time.time())
    signal_line = f"{timestamp}|CLOSE_HALF_BREAKEVEN|GID:{group_id}|{channel_name}"

    try:
        # Write to all signal files
        success = True
        for signal_path in MT4_SIGNAL_FILE_PATHS:
            try:
                # Ensure the directory exists
                os.makedirs(os.path.dirname(signal_path), exist_ok=True)
                
                # Write with explicit flush to ensure immediate write
                with open(signal_path, "w", encoding='utf-8') as f:
                    f.write(signal_line)
                    f.flush()
                    os.fsync(f.fileno())  # Force write to disk
                    
                logger.info(f"✅ CLOSE_HALF_BREAKEVEN signal kiírva ('{os.path.basename(signal_path)}'): {signal_line}")
            except IOError as e:
                logger.error(f"❌ Hiba CLOSE_HALF_BREAKEVEN signal írásakor ('{signal_path}'): {e}")
                success = False
        
        return signal_line if success else None
    except Exception as e:
        logger.error(f"❌ Váratlan Hiba CLOSE_HALF_BREAKEVEN signal írásakor: {e}")
        traceback.print_exc()
        return None
