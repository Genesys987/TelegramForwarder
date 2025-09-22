# --- stoploss_update.py (Updated for signals.txt integration) ---
import re
import logging
import time
import os
from collections import OrderedDict
from enum import Enum
from typing import Optional
from queue_manager import write_message_to_queue
from signal_parser import parse_natural_language_sl_modification

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
    pattern = r"(\d+\.?\d*)"
    match = re.search(pattern, text, re.IGNORECASE)
    if match and match.group(1):
      price_str = match.group(1)
      if re.fullmatch(r"[\d]+\.?[\d]*", price_str) and "." != price_str:
        logger.debug(f"SL Extract: Price '{price_str}' from '{text}'")
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

    return process_signal(SignalType.MODIFY, group_id, channel_name, modified_value=new_sl_value_formatted)

def find_latest_group_id_for_channel(channel_name: str) -> Optional[int]:
    """
    Find the most recent group ID for a specific channel by searching archive files.
    
    Args:
        channel_name: The cleaned channel name (4 characters)
        
    Returns:
        The latest group_id for the channel, or None if not found
    """
    try:
        import glob
        
        latest_group_id = None
        latest_timestamp = 0
        
        # Search through archive files (processed signals)
        logger.debug(f"Searching archive files for channel {channel_name}")
        logs_dir = os.path.join(os.path.dirname(__file__), 'logs')
        if os.path.exists(logs_dir):
            # Get all archive files, sorted by date (newest first)
            archive_pattern = os.path.join(logs_dir, 'signals_archive_*.txt')
            archive_files = sorted(glob.glob(archive_pattern), reverse=True)
            
            for archive_file in archive_files:
                try:
                    with open(archive_file, "r", encoding='utf-8') as f:
                        lines = f.readlines()
                    
                    # Process lines in reverse order to find the most recent entry
                    for line in reversed(lines):
                        line = line.strip()
                        if not line:
                            continue
                        
                        # Parse signal line format: timestamp|signal_type|symbol|entry|tps|sl|GID:xxxx|channel_name
                        parts = line.split('|')
                        if len(parts) >= 8:
                            try:
                                timestamp = int(parts[0])
                                line_channel = parts[-1].strip()  # Last part is channel name
                                gid_part = parts[-2].strip()      # Second to last is GID:xxxx
                                
                                # Extract GID from "GID:xxxx" format
                                if gid_part.startswith("GID:"):
                                    group_id = int(gid_part[4:])
                                    
                                    # Check if this is for our target channel and is more recent
                                    if line_channel == channel_name and timestamp > latest_timestamp:
                                        latest_timestamp = timestamp
                                        latest_group_id = group_id
                                        logger.debug(f"Found in archive {archive_file}: GID={group_id}, timestamp={timestamp}")
                                
                            except (ValueError, IndexError):
                                continue
                                
                except Exception as e:
                    logger.warning(f"Error reading archive file {archive_file}: {e}")
                    continue
        
        if latest_group_id:
            logger.info(f"Found latest GID {latest_group_id} for channel {channel_name} (timestamp: {latest_timestamp})")
        else:
            logger.warning(f"No signals found for channel {channel_name} in archive files")
            
        return latest_group_id
        
    except Exception as e:
        logger.error(f"Error finding latest group_id for channel {channel_name}: {e}")
        return None

def process_stoploss_non_reply(message_text: str, channel_name: str) -> bool:
    """
    Process SL modification from non-reply messages using natural language parsing.
    
    Args:
        message_text: The message text containing SL modification
        channel_name: The target channel name (will be cleaned to 4 chars)
        
    Returns:
        True if SL modification was successfully processed, False otherwise
    """
    logger.info(f"Non-reply SL processing for channel: {channel_name}")
    
    try:
        # Parse the new SL value from natural language
        new_sl_value = parse_natural_language_sl_modification(message_text)
        if new_sl_value is None:
            logger.warning(f"Could not extract SL value from message: {message_text}")
            return False
        
        # Clean the channel name to 4-character format
        from signal_parser import clean_channel_name
        clean_channel = clean_channel_name(channel_name)
        
        # Find the latest group ID for this channel
        group_id = find_latest_group_id_for_channel(clean_channel)
        if group_id is None:
            logger.warning(f"No recent signals found for channel {clean_channel}, cannot modify SL")
            return False
        
        # Process the SL modification
        logger.info(f"Processing non-reply SL modification: GID={group_id}, Channel={clean_channel}, New SL={new_sl_value}")
        return process_signal(SignalType.MODIFY, group_id, clean_channel, modified_value=str(new_sl_value))
        
    except Exception as e:
        logger.error(f"Error in non-reply SL processing: {e}")
        return False
