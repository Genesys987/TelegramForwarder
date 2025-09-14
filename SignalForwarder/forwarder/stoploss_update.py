# --- stoploss_update.py (Updated for signals.txt integration) ---
import re
import logging
import time
from datetime import datetime
from collections import OrderedDict
from enum import Enum
from queue_manager import write_message_to_queue

logger = logging.getLogger(__name__)

class SignalType(Enum):
    CLOSE = "CLOSE"
    BREAKEVEN = "BREAKEVEN"
    CLOSE_HALF_BREAKEVEN = "CLOSE_HALF_BREAKEVEN"
    MODIFY = "MODIFY"

# Global tracking with timestamps for automatic cleanup
_processed_signals = {
    SignalType.CLOSE_HALF_BREAKEVEN: OrderedDict(),  # key -> timestamp
    SignalType.BREAKEVEN: OrderedDict(),
    SignalType.CLOSE: OrderedDict()
}

trackable_signal_types = [SignalType.CLOSE, SignalType.BREAKEVEN, SignalType.CLOSE_HALF_BREAKEVEN]

# Auto-cleanup settings
TRACKING_CLEANUP_DAYS = 2  # Clean entries older than 2 days
TRACKING_KEEP_RECENT = 3   # Always keep the most recent 3 entries per type

def _cleanup_old_tracking():
    """Clean up tracking entries older than TRACKING_CLEANUP_DAYS, but keep the most recent TRACKING_KEEP_RECENT entries"""
    cutoff_time = time.time() - (TRACKING_CLEANUP_DAYS * 24 * 60 * 60)  # 2 days ago
    
    for signal_type in _processed_signals:
        tracking_dict = _processed_signals[signal_type]
        original_count = len(tracking_dict)
        
        if original_count <= TRACKING_KEEP_RECENT:
            # If we have 3 or fewer entries, keep them all
            continue
            
        # Convert to list to work with indices
        items = list(tracking_dict.items())
        
        # Calculate how many we can potentially clean (keep at least TRACKING_KEEP_RECENT)
        max_to_remove = original_count - TRACKING_KEEP_RECENT
        
        # Find old entries (older than cutoff)
        old_keys = []
        for key, timestamp in items[:-TRACKING_KEEP_RECENT]:  # Exclude the last 3
            if timestamp < cutoff_time:
                old_keys.append(key)
                if len(old_keys) >= max_to_remove:
                    break
        
        # Remove old entries
        for key in old_keys:
            del tracking_dict[key]
        
        if old_keys:
            logger.info(f"Cleaned {len(old_keys)} old {signal_type} tracking entries (older than {TRACKING_CLEANUP_DAYS} days), kept {len(tracking_dict)} entries")

def _get_signal_key(group_id, channel_name, signal_type):
    return f"{group_id}_{channel_name}_{signal_type.value}"

def _is_signal_processed(group_id, channel_name, signal_type: SignalType):
    _cleanup_old_tracking()
    key = _get_signal_key(group_id, channel_name, signal_type)
    tracking_dict = _processed_signals.get(signal_type, {})
    return key in tracking_dict


def _mark_signal_processed(group_id, channel_name, signal_type: SignalType):
    _cleanup_old_tracking()
    key = _get_signal_key(group_id, channel_name, signal_type)
    timestamp = time.time()
    if signal_type in _processed_signals:
        _processed_signals[signal_type][key] = timestamp
        logger.info(f"{signal_type.value.upper()} marked as processed for GID={group_id}, Channel={channel_name}")
    else:
        logger.error(f"Unknown signal type: {signal_type}")

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

def _process_signal(signal_type: SignalType, group_id, channel_name="UNKN", modified_value=None):
    """Internal unified signal processor for CLOSE, BREAKEVEN, CLOSE_HALF_BREAKEVEN, MODIFY"""
    logger.info(f"Process: {signal_type.value} GID={group_id}, Channel={channel_name}")
    if not isinstance(group_id, int) or group_id <= 0:
        logger.error(f"Hiba {signal_type.value} Process: Érvénytelen group_id: {group_id}")
        return None

    # For MODIFY, extra_value is required
    if signal_type == SignalType.MODIFY and not modified_value:
        logger.error(f"Hiba {signal_type.value} Process: extra_value (new SL) is required.")
        return None

    # Check if already processed (except for MODIFY)
    if signal_type in trackable_signal_types and _is_signal_processed(group_id, channel_name, signal_type):
      logger.warning(f"{signal_type.value} már feldolgozva GID={group_id}, Channel={channel_name} - kihagyás")
      return None

    # Mark as processed (except for MODIFY)
    if signal_type in trackable_signal_types:
      _mark_signal_processed(group_id, channel_name, signal_type)

    timestamp = int(time.time())
    if signal_type == SignalType.MODIFY:
        signal_line = f"{timestamp}|{signal_type.value}|{modified_value}|GID:{group_id}|{channel_name}"
    else:
        signal_line = f"{timestamp}|{signal_type.value}|GID:{group_id}|{channel_name}"

    return write_message_to_queue(signal_line)

def process_stoploss_reply(reply_text, group_id, channel_name="UNKN"):
    logger.info(f"SL Process: GID={group_id}, Channel={channel_name}, Reply='{reply_text}'")
    if not isinstance(group_id, int) or group_id <= 0:
        logger.error(f"Hiba SL Process: Érvénytelen group_id: {group_id}")
        return None

    new_sl_value_str = extract_price_from_text(reply_text)
    if not new_sl_value_str:
        logger.error(f"Hiba SL Process: Új SL kinyerése sikertelen: '{reply_text}'")
        return None

    try:
        new_sl_float = float(new_sl_value_str)
        if new_sl_float <= 0:
            logger.warning(f"Warning SL Process: Extracted SL {new_sl_float} not positive.")
        new_sl_value_formatted = new_sl_value_str
    except ValueError:
        logger.error(f"Hiba SL Process: Kinyert érték '{new_sl_value_str}' nem szám.")
        return None

    return _process_signal(SignalType.MODIFY, group_id, channel_name, modified_value=new_sl_value_formatted)

def process_breakeven_signal(group_id, channel_name="UNKN"):
    return _process_signal(SignalType.BREAKEVEN, group_id, channel_name)

def process_close_signal(group_id, channel_name="UNKN"):
    return _process_signal(SignalType.CLOSE, group_id, channel_name)

def process_close_and_breakeven_signal(group_id, channel_name="UNKN"):
    return _process_signal(SignalType.CLOSE_HALF_BREAKEVEN, group_id, channel_name)
