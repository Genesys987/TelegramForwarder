# --- stoploss_update.py (Updated for signals.txt integration) ---
import re
import logging
import time
import json
from collections import OrderedDict
from enum import Enum
from queue_manager import write_message_to_queue
from config import MESSAGE_GID_MAP_FILE, NON_REPLY_SL_CHANNEL

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

# Enhanced natural language SL extraction
def extract_price_from_text(text):
    """
    Enhanced SL extraction using natural language parsing.
    Falls back to simple patterns if advanced parsing fails.
    """
    # Try advanced natural language parsing first
    try:
        from signal_parser import parse_natural_language_sl_modification
        sl_value = parse_natural_language_sl_modification(text)
        if sl_value and sl_value > 0:
            logger.debug(f"SL Extract (advanced): Price '{sl_value}' from '{text}'")
            return str(sl_value)
    except ImportError:
        logger.warning("Advanced SL parsing not available, using fallback")
    except Exception as e:
        logger.debug(f"Advanced SL parsing failed: {e}, using fallback")
    
    # Fallback to original patterns
    patterns = [
        r"(?:SL|Stop\s*loss|Adjust)\s*(?:on\s+\w+)?\s*(?:to|at|is|here)?\s*:?\s*([\d]+\.?[\d]*)",
        r"([\d]+\.?[\d]*)"
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match and match.group(1):
            price_str = match.group(1)
            if re.fullmatch(r"[\d]+\.?[\d]*", price_str) and "." != price_str:
                logger.debug(f"SL Extract (fallback): Price '{price_str}' from '{text}'")
                return price_str
    logger.debug(f"SL Extract: No price found in '{text}'")
    return None

def process_signal(signal_type: SignalType, group_id, channel_name="UNKN", modified_value=None):
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
        signal_line = f"{timestamp}|{signal_type.value}|{modified_value}|GID:{group_id}|{channel_name}\n"
    else:
        signal_line = f"{timestamp}|{signal_type.value}|GID:{group_id}|{channel_name}\n"

    return write_message_to_queue(signal_line)

def find_latest_group_id_for_channel(channel_name):
    """
    Find the latest (highest) group_id for the configured channel.
    We need to look at the signals files to find channel-specific GIDs.
    
    Args:
        channel_name: Should match NON_REPLY_SL_CHANNEL
        
    Returns:
        The latest group_id for the channel, or None if not found
    """
    try:
        # Non-reply SL modifications konfigurált csatornán (alapértelmezett: FXTM)
        if channel_name != NON_REPLY_SL_CHANNEL:
            logger.warning(f"Non-reply SL modification csak {NON_REPLY_SL_CHANNEL} csatornán támogatott, kapott: {channel_name}")
            return None
        
        # Load the message_id to group_id mapping
        try:
            with open(MESSAGE_GID_MAP_FILE, 'r', encoding='utf-8') as f:
                message_gid_map = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            message_gid_map = {}
        
        if not message_gid_map:
            logger.warning("No message-GID mappings found")
            return None
        
        # Convert all values to integers and get the highest
        try:
            gid_values = []
            for value in message_gid_map.values():
                if isinstance(value, (int, str)):
                    gid_values.append(int(value))
                    
            if not gid_values:
                logger.warning("No valid GID values found in mapping")
                return None
                
            latest_gid = max(gid_values)
            logger.info(f"Found latest GID for {NON_REPLY_SL_CHANNEL}: {latest_gid}")
            return latest_gid
            
        except (ValueError, TypeError) as e:
            logger.error(f"Error processing GID values: {e}")
            return None
        
    except Exception as e:
        logger.error(f"Error in find_latest_group_id_for_channel: {e}")
        return None

def process_stoploss_reply(reply_text, group_id, channel_name="UNKN"):
    """
    Process SL modification for a specific GID (reply message scenario).
    
    Args:
        reply_text: The message text containing new SL value
        group_id: The specific group ID to modify
        channel_name: The channel name
    
    Returns:
        Result of the signal processing
    """
    logger.info(f"SL Process (with GID): GID={group_id}, Channel={channel_name}, Reply='{reply_text}'")
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

    return process_signal(SignalType.MODIFY, group_id, channel_name, modified_value=new_sl_value_formatted)

def process_stoploss_non_reply(message_text, channel_name="UNKN"):
    """
    Process SL modification when there's no reply (non-reply scenario).
    Finds the latest open orders from the channel and modifies their SL.
    
    Args:
        message_text: The message text containing new SL value  
        channel_name: The channel name where the message came from
    
    Returns:
        Result of the signal processing
    """
    logger.info(f"SL Process (non-reply): Channel={channel_name}, Message='{message_text}'")
    
    # Extract SL value from the message
    new_sl_value_str = extract_price_from_text(message_text)
    if not new_sl_value_str:
        logger.error(f"Hiba SL Process (non-reply): Új SL kinyerése sikertelen: '{message_text}'")
        return None

    # Find the latest GID for this channel
    latest_gid = find_latest_group_id_for_channel(channel_name)
    if not latest_gid:
        logger.error(f"Hiba SL Process (non-reply): Nincs friss GID található ehhez a csatornához: {channel_name}")
        return None
    
    logger.info(f"SL Process (non-reply): Legfrissebb GID {latest_gid} használata a csatornából: {channel_name}")
    
    try:
        new_sl_float = float(new_sl_value_str)
        if new_sl_float <= 0:
            logger.warning(f"Warning SL Process (non-reply): Extracted SL {new_sl_float} not positive.")
        new_sl_value_formatted = new_sl_value_str
    except ValueError:
        logger.error(f"Hiba SL Process (non-reply): Kinyert érték '{new_sl_value_str}' nem szám.")
        return None

    return process_signal(SignalType.MODIFY, latest_gid, channel_name, modified_value=new_sl_value_formatted)
