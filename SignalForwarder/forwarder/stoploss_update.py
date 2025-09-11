# --- stoploss_update.py (Updated for signals.txt integration) ---
import re
import os
import traceback
import logging
import time
from datetime import datetime, timedelta
from collections import OrderedDict

logger = logging.getLogger(__name__)

try:
    from config import MT4_SIGNAL_FILE_PATHS  # Use signals.txt instead of stoploss_update.txt
except ImportError:
    logger.error("Hiba: config.py/MT4_SIGNAL_FILE_PATHS hiányzik.")
    MT4_SIGNAL_FILE_PATHS = ["signals.txt"]

# Global tracking with timestamps for automatic cleanup
_processed_signals = {
    'close_breakeven': OrderedDict(),  # key -> timestamp
    'breakeven': OrderedDict(),
    'close': OrderedDict()
}

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
    """Generate a unique key for tracking signal operations"""
    return f"{group_id}_{channel_name}_{signal_type}"

def _is_signal_processed(group_id, channel_name, signal_type):
    """Check if signal has already been processed"""
    # Auto-cleanup before checking
    _cleanup_old_tracking()
    
    key = _get_signal_key(group_id, channel_name, signal_type)
    tracking_dict = _processed_signals.get(signal_type, {})
    return key in tracking_dict

def _mark_signal_processed(group_id, channel_name, signal_type):
    """Mark signal as processed with current timestamp"""
    # Auto-cleanup before adding
    _cleanup_old_tracking()
    
    key = _get_signal_key(group_id, channel_name, signal_type)
    timestamp = time.time()
    
    if signal_type in _processed_signals:
        _processed_signals[signal_type][key] = timestamp
        logger.info(f"{signal_type.upper()} marked as processed for GID={group_id}, Channel={channel_name}")
    else:
        logger.error(f"Unknown signal type: {signal_type}")

def clear_all_signal_tracking():
    """Clear all signal tracking (useful for testing or manual reset)"""
    for signal_type in _processed_signals:
        _processed_signals[signal_type].clear()
    logger.info("All signal tracking cleared")

def clear_close_breakeven_tracking():
    """Clear close+breakeven tracking (backward compatibility)"""
    _processed_signals['close_breakeven'].clear()
    logger.info("Close+Breakeven tracking cleared")

def get_tracking_stats():
    """Get current tracking statistics for monitoring"""
    stats = {}
    for signal_type, tracking_dict in _processed_signals.items():
        stats[signal_type] = {
            'count': len(tracking_dict),
            'oldest': None,
            'newest': None
        }
        
        if tracking_dict:
            timestamps = list(tracking_dict.values())
            stats[signal_type]['oldest'] = datetime.fromtimestamp(min(timestamps)).strftime('%Y-%m-%d %H:%M:%S')
            stats[signal_type]['newest'] = datetime.fromtimestamp(max(timestamps)).strftime('%Y-%m-%d %H:%M:%S')
    
    return stats

# Backward compatibility functions (for existing tests)
def _get_close_breakeven_key(group_id, channel_name):
    """Generate a unique key for tracking close+breakeven operations"""
    return _get_signal_key(group_id, channel_name, "close_breakeven")

def _is_close_breakeven_processed(group_id, channel_name):
    """Check if close+breakeven has already been processed for this signal"""
    return _is_signal_processed(group_id, channel_name, "close_breakeven")

def _mark_close_breakeven_processed(group_id, channel_name):
    """Mark close+breakeven as processed for this signal"""
    _mark_signal_processed(group_id, channel_name, "close_breakeven")

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

    # Check if breakeven has already been processed for this signal
    if _is_signal_processed(group_id, channel_name, "breakeven"):
        logger.warning(f"Breakeven már feldolgozva GID={group_id}, Channel={channel_name} - kihagyás")
        return None

    # Mark as processed first to prevent race conditions
    _mark_signal_processed(group_id, channel_name, "breakeven")

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

    # Check if close has already been processed for this signal
    if _is_signal_processed(group_id, channel_name, "close"):
        logger.warning(f"Close már feldolgozva GID={group_id}, Channel={channel_name} - kihagyás")
        return None

    # Mark as processed first to prevent race conditions
    _mark_signal_processed(group_id, channel_name, "close")

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

    # Check if close+breakeven has already been processed for this signal
    if _is_signal_processed(group_id, channel_name, "close_breakeven"):
        logger.warning(f"Close+Breakeven már feldolgozva GID={group_id}, Channel={channel_name} - kihagyás")
        return None

    # Mark as processed first to prevent race conditions
    _mark_signal_processed(group_id, channel_name, "close_breakeven")

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
