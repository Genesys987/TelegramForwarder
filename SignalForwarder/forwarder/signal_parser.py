import re
import os
from dotenv import dotenv_values

# Dictionary of common symbol mappings
symbol_mappings = {
    'GOLD': 'XAUUSD'
}

# Load warmup signal settings from .env
config = dotenv_values(".env")
WARMUP_SIGNAL_ENABLED = config.get("WARMUP_SIGNAL_ENABLED", "false").lower() == "true"
WARMUP_SIGNAL_CHANNEL = config.get("WARMUP_SIGNAL_CHANNEL", "FXTM")

# Ready message patterns for warmup signals
READY_MESSAGE_PATTERNS = [
    r"I'?m\s+buying\s+now",
    r"I'?m\s+selling\s+now", 
    r"Let'?s\s+scalping\s+sell\s+gold\s+slowly\s+mid\s+risk",
    r"ready\s+sell",
    r"Mid\s+risk\s+let'?s\s+scalping\s+buy\s+gold\s+slowly",
    r"Ready\s+Buy",
    r"Double\s+sell\s+ready", 
    r"HIGH\s+risk\s+let'?s\s+scalping\s+buy\s+gold\s+slowly",
    r"GOLD\s+SELL\s+READY",
    r"ANOTHER\s+GOLD\s+BUY\s+READY"
]

def clean_channel_name(channel_name: str) -> str:
    """
    Clean channel name by keeping letters only
    Uses simple truncation for consistency with MT4.
    
    Args:
        channel_name: Raw channel name/title that may contain emojis
        
    Returns:
        Clean channel name with exactly 4 letters for MT4 comment limit
    """
    if not channel_name or not channel_name.strip():
        return "UNKN"

    # Convert to uppercase and extract only alphabetic characters
    clean_name = channel_name.upper()
    alpha_only = re.sub(r'[^A-Z]', '', clean_name)
    
    # Simple truncation/padding logic to match MT4 exactly
    if alpha_only:
        if len(alpha_only) <= 4:
            result = alpha_only
            # Pad with 'X' if needed
            while len(result) < 4:
                result += "X"
        else:
            # Simple truncation for long names - take first 4 characters
            result = alpha_only[:4]
    else:
        result = "UNKN"
    
    return result[:4]

def parse_entry_price(entry_text, signal_type):
    """
    Parse entry price from text, handling range formats like '3334/3337', '3339-3344', '@3339-3344'
    
    Args:
        entry_text: The entry price text to parse
        signal_type: 'BUY' or 'SELL' to determine which price to use from ranges
    
    Returns:
        Parsed entry price as float or original text if parsing fails
    """
    # Clean up the entry text - remove @ symbol and extra spaces
    entry_text = entry_text.strip().lstrip('@').strip()
    
    # Handle different range separators (including space-separated like "3340.5 -3338")
    if '/' in entry_text:
        split = entry_text.split('/')
    elif '-' in entry_text:
        # Handle both "3339-3344" and "3340.5 -3338" formats
        if ' -' in entry_text:
            split = entry_text.split(' -')
        else:
            split = entry_text.split('-')
    else:
        # Single price
        try:
            return float(entry_text)
        except ValueError:
            return entry_text
    
    try:
        # Convert to floats for proper comparison
        prices = [float(p.strip()) for p in split if p.strip()]
        
        if not prices:
            return entry_text
            
        # For SELL: use the higher price (better entry for seller)
        # For BUY: use the lower price (better entry for buyer)
        if signal_type == "SELL":
            return max(prices)
        else:
            return min(prices)
    except ValueError:
        print(f"Warning: Invalid range format: {entry_text}")
        return entry_text

def parse_single_line_signal(text):
    """
    Parse a single-line signal where all components are on one line
    Example: "BUY BTCUSD ENTRY 89300.00 TP 89500.00 SL 88600.00"
    """
    text = text.strip()
    if not text:
        return None
    
    # If there are multiple lines, this should be handled by the multi-line parser
    if '\n' in text and len(text.splitlines()) > 1:
        # Check if any line has a significant amount of content
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if len(lines) > 1:
            return None  # Let multi-line parser handle this
    
    signal = {}
    take_profits = []
    
    # Check for immediate entry (NOW keyword) first
    is_immediate = 'NOW' in text.upper()
    
    # Try different single-line patterns
    
    # Pattern 1: Pipe format "BTCUSD | BUY 109500 ❌ Stop Loss 109000 ✅TP1 109700"
    pipe_pattern = r'([\w\.\/\-]+)\s*\|\s*(BUY|SELL)\s+([\d\/\.\-@]+)'
    pipe_match = re.search(pipe_pattern, text, re.IGNORECASE)
    if pipe_match:
        raw_symbol = pipe_match.group(1).upper()
        signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
        signal["signal_type"] = pipe_match.group(2).upper()
        if not is_immediate:  # Only set entry if not immediate
            signal["entry"] = parse_entry_price(pipe_match.group(3), signal["signal_type"])
    
    # Pattern 2: Enhanced regex patterns for NOW signals and regular signals
    if not signal.get("signal_type"):
        regular_patterns = [
            # Enhanced patterns for NOW signals with emojis
            r'🚨?\s*([\w\.\/\-]+)\s+(BUY|SELL)\s+NOW\s*🚨?',                    # 🚨 GOLD SELL NOW 🚨
            r'(BUY|SELL)\s+([\w\.\/\-]+)\s+NOW',                                # BUY GOLD NOW
            r'([\w\.\/\-]+)\s+NOW\s+(BUY|SELL)',                                # GOLD NOW SELL
            r'NOW\s+(BUY|SELL)\s+([\w\.\/\-]+)',                                # NOW BUY BTCUSD
            r'I[\'\u2019]?M\s+(SELLING|BUYING)\s+([\w\.\/\-]+)\s+NOW\s*\(([\d\-\s@\.]+)\)', # I'M SELLING XAUUSD NOW (3337 - 3340)
            # Regular patterns (existing + new @ and - range formats)
            r'([\w\.\/\-]+)\s+(BUY|SELL)\s+FROM\s+([\d\/\.\-@]+)',              # GOLD SELL FROM 3313/3315.3
            r'([\w\.\/\-]+)\s+(BUY|SELL)\s+@([\d\-]+)',                         # Sell Gold @3339-3344
            r'([\w\.\/\-]+)\s+(BUY|SELL)\s+([\d\-@]+)',                         # Gold Sell 3341-3346
            r'([\w\.\/\-]+)\s+(BUY|SELL)\s+([\d\/\.]+)',                        # XAUUSD BUY 3417
            r'(BUY|SELL)\s+([\w\.\/\-]+)(?:\s+ENTRY\s+)?([\d\/\.\-@]+)',        # BUY BTCUSD ENTRY 89300.00
            r'(BUY|SELL)\s+([\w\.\/\-]+)\s+([\d\/\.\-@]+)',                     # SELL XAUUSD 3290.5
        ]
        
        for pattern in regular_patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                if 'NOW' in pattern:
                    # NOW pattern handling
                    if pattern == r'🚨?\s*([\w\.\/\-]+)\s+(BUY|SELL)\s+NOW\s*🚨?':
                        # 🚨 SYMBOL BUY/SELL NOW 🚨
                        raw_symbol = match.group(1).upper()
                        signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                        signal["signal_type"] = match.group(2).upper()
                    elif pattern == r'(BUY|SELL)\s+([\w\.\/\-]+)\s+NOW':
                        # BUY/SELL SYMBOL NOW
                        signal["signal_type"] = match.group(1).upper()
                        raw_symbol = match.group(2).upper()
                        signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    elif pattern == r'([\w\.\/\-]+)\s+NOW\s+(BUY|SELL)':
                        # SYMBOL NOW BUY/SELL
                        raw_symbol = match.group(1).upper()
                        signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                        signal["signal_type"] = match.group(2).upper()
                    elif pattern == r'NOW\s+(BUY|SELL)\s+([\w\.\/\-]+)':
                        # NOW BUY/SELL SYMBOL
                        signal["signal_type"] = match.group(1).upper()
                        raw_symbol = match.group(2).upper()
                        signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    elif pattern == r'I[\'\u2019]?M\s+(SELLING|BUYING)\s+([\w\.\/\-]+)\s+NOW\s*\(([\d\-\s@\.]+)\)':
                        # I'M SELLING XAUUSD NOW (3337 - 3340)
                        action = match.group(1).upper()
                        signal["signal_type"] = "SELL" if action == "SELLING" else "BUY"
                        raw_symbol = match.group(2).upper()
                        signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                        # Extract range from parentheses and use as entry price
                        range_text = match.group(3).strip()
                        signal["entry"] = parse_entry_price(range_text, signal["signal_type"])
                        signal["_range_info"] = range_text
                elif 'FROM' in pattern:
                    # FROM format: SYMBOL BUY/SELL FROM price
                    raw_symbol = match.group(1).upper()
                    signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    signal["signal_type"] = match.group(2).upper()
                    if not is_immediate:
                        signal["entry"] = parse_entry_price(match.group(3), signal["signal_type"])
                elif '@' in pattern:
                    # @ format: SYMBOL BUY/SELL @price-range
                    raw_symbol = match.group(1).upper()
                    signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    signal["signal_type"] = match.group(2).upper()
                    if not is_immediate:
                        signal["entry"] = parse_entry_price(match.group(3), signal["signal_type"])
                elif pattern == r'([\w\.\/\-]+)\s+(BUY|SELL)\s+([\d\-@]+)':
                    # SYMBOL BUY/SELL price-range format: Gold Sell 3341-3346
                    raw_symbol = match.group(1).upper()
                    signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    signal["signal_type"] = match.group(2).upper()
                    if not is_immediate:
                        signal["entry"] = parse_entry_price(match.group(3), signal["signal_type"])
                elif pattern == r'([\w\.\/\-]+)\s+(BUY|SELL)\s+([\d\/\.]+)':
                    # SYMBOL BUY/SELL price format: XAUUSD BUY 3417
                    raw_symbol = match.group(1).upper()
                    signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    signal["signal_type"] = match.group(2).upper()
                    if not is_immediate:
                        signal["entry"] = parse_entry_price(match.group(3), signal["signal_type"])
                else:
                    # Regular format: BUY/SELL SYMBOL price
                    signal["signal_type"] = match.group(1).upper()
                    raw_symbol = match.group(2).upper()
                    signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    if len(match.groups()) >= 3 and not is_immediate:
                        signal["entry"] = parse_entry_price(match.group(3), signal["signal_type"])
                break
    
    # Extract all TP values using multiple patterns (enhanced for emojis)
    tp_patterns = [
        r'[🤑💰✅]\s*TP(\d*)\s*:?\s*([\d\.]+)',        # Emoji TP with number capture
        r'T\.P(\d+)\s+([\d\.]+)',                       # T.P1 114600, T.P2 114500 (T.P format)
        r'TP(\d+)\s*:?\s*([\d\.]+)',                    # TP1: 3289.0 or TP1 3289.0
        r'TP\s*:\s*([\d\.]+)',                          # TP: 89500.00 (with colon)
        r'TP\s+([\d\.]+)',                              # TP 89500.00 (without colon)
        r'Take\s+profit\s+(\d+)\s+at\s+([\d\.]+)',     # Take profit 1 at 89500.00
    ]
    
    for tp_pattern in tp_patterns:
        tp_matches = re.findall(tp_pattern, text, re.IGNORECASE)
        for tp_match in tp_matches:
            try:
                if isinstance(tp_match, tuple) and len(tp_match) > 1:
                    # If pattern captured both number and value, use the value
                    tp_value = float(tp_match[-1])  # Last element is the price
                else:
                    # Single capture group or string
                    tp_value = float(tp_match if isinstance(tp_match, str) else tp_match[0])
                
                if tp_value not in take_profits and tp_value > 0.1:  # Filter out very small numbers but allow forex values
                    take_profits.append(tp_value)
            except (ValueError, IndexError):
                continue
    
    # Extract SL value using multiple patterns (enhanced for emojis)
    sl_patterns = [
        r'[🔴❌🛑]\s*(?:SL|Stop\s*Loss|STOP\s*LOSS)\s*:?\s*([\d\.]+)',  # Emoji SL
        r'S\.L\s+([\d\.]+)',                                           # S.L   115900 (S.L format)
        r'SL\s*:\s*([\d\.]+)',                                         # SL: 88600.00 (with colon)
        r'SL\s+([\d\.]+)',                                             # SL 88600.00 (without colon)
        r'Stop\s+loss\s+(?:at\s+)?([\d\.]+)',                         # Stop loss at 88600.00
    ]
    
    for sl_pattern in sl_patterns:
        sl_match = re.search(sl_pattern, text, re.IGNORECASE)
        if sl_match:
            try:
                signal["stop_loss"] = float(sl_match.group(1))
                break
            except ValueError:
                continue
    
    # Set entry to 0 for immediate signals
    if is_immediate and signal.get("signal_type") and signal.get("symbol"):
        signal["entry"] = 0
    
    # Sort take profits
    if take_profits:
        if signal.get("signal_type") == "BUY":
            take_profits.sort()
        else:
            take_profits.sort(reverse=True)
        signal["take_profits"] = take_profits
    
    # Validate essential components
    if (signal.get("signal_type") and 
        signal.get("symbol") and 
        signal.get("entry") is not None and
        signal.get("take_profits") and
        len(signal.get("take_profits", [])) > 0 and
        signal.get("stop_loss") is not None):
        return signal
    
    return None

def parse_signal(text: str):
    """
    Parses signal text into a dictionary. Handles known formats.

    Example Format:
    BUY BTCUSD
    ENTRY 89300.00
    Take profit 1 at 89500.00
    Take profit 2 at 89800.00
    Take profit 3 at 90300.00
    Stop loss at 88600.00

    Returns dict with keys:
    signal_type, symbol, entry, take_profits (list), stop_loss
    or None if parsing fails or essential info is missing.
    """
    if not text: 
        return None # Handle empty input

    # First, try to parse as a single line with all components
    single_line_result = parse_single_line_signal(text)
    if single_line_result:
        return single_line_result

    # If single line parsing fails, use multi-line parsing
    lines = text.splitlines()
    signal = {}
    take_profits = []  # Collect all TPs, will be sorted later
    
    for line in lines:
        line = line.strip()
        if not line: 
            continue # Skip empty lines

        # Signal Type and Symbol parsing - handle multiple formats
        if not signal.get("signal_type"):
            # Format 0: NOW signals with emojis like "🚨 GOLD SELL NOW 🚨"
            match_emoji_now = re.match(r'^🚨?\s*([\w\.\/\-]+)\s+(BUY|SELL)\s+NOW\s*🚨?', line, re.IGNORECASE)
            if match_emoji_now:
                raw_symbol = match_emoji_now.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_emoji_now.group(2).upper()
                # NOW signals have entry = 0
                signal["entry"] = 0
                continue
                
            # Format 1: "GOLD SELL FROM 3313/3315" or "SYMBOL BUY FROM price" (check this first, it's more specific)
            match_symbol_type_from = re.match(r'^([\w\.\/\-]+)\s+(BUY|SELL)\s+FROM\s+([\d\/\.\-@]+)', line, re.IGNORECASE)
            if match_symbol_type_from:
                raw_symbol = match_symbol_type_from.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_symbol_type_from.group(2).upper()
                # Also capture the entry price from the FROM clause
                entry_text = match_symbol_type_from.group(3)
                signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 1.5: "Sell Gold @3339-3344" or similar @ formats
            match_symbol_at = re.match(r'^(BUY|SELL)\s+([\w\.\/\-]+)\s+@([\d\-]+)', line, re.IGNORECASE)
            if match_symbol_at:
                signal["signal_type"] = match_symbol_at.group(1).upper()
                raw_symbol = match_symbol_at.group(2).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                entry_text = match_symbol_at.group(3)
                signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 2: "BUY BTCUSD" or "SELL GOLD" or "BUY CHFJPY 180.430" or "GOLD SELL 3334/3337"
            match_type_symbol = re.match(r'^(BUY|SELL)\s+([\w\.\/\-]+)\s*([\d\/\.\-@]*)', line, re.IGNORECASE)
            if match_type_symbol:
                signal["signal_type"] = match_type_symbol.group(1).upper()
                raw_symbol = match_type_symbol.group(2).upper()
                # Map symbol if it exists in our mappings, otherwise use as-is
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                # Capture the entry price if present (including range formats)
                entry_text = match_type_symbol.group(3).strip()
                if entry_text:
                    signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 3: "SYMBOL SIGNAL_TYPE" or "SYMBOL SIGNAL_TYPE entry_range" (e.g., "GOLD SELL 3334/3337", "Gold Sell 3341-3346")
            # Note: Exclude colon format which is handled separately
            match_symbol_type_alt = re.match(r'^([\w\.\/\-]+)\s+(BUY|SELL)(?!\s*:)\s*([\d\/\.\-@]*)', line, re.IGNORECASE)
            if match_symbol_type_alt:
                raw_symbol = match_symbol_type_alt.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_symbol_type_alt.group(2).upper()
                # Capture the entry price if present (including range formats)
                entry_text = match_symbol_type_alt.group(3).strip()
                if entry_text:
                    signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
                
            # Format 3.5: "SYMBOL SIGNAL_TYPE : entry_range" (e.g., "Gold buy : 3340.5 -3338")
            match_symbol_type_colon = re.match(r'^([\w\.\/\-]+)\s+(BUY|SELL)\s*:\s*([\d\/\.\-@\s]+)', line, re.IGNORECASE)
            if match_symbol_type_colon:
                raw_symbol = match_symbol_type_colon.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_symbol_type_colon.group(2).upper()
                # Capture the entry price with colon format
                entry_text = match_symbol_type_colon.group(3).strip()
                if entry_text:
                    signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 4: "EURUSD BUY" or "XAUUSD BUY" or "XAUUSD BUY 3417" or "XAUUSD / GOLD SELL" (symbol first, then type, optional price)
            match_symbol_type_simple = re.match(r'^([\w\.\/\-]+(?:\s*/\s*[\w\.\/\-]+)?)\s+(BUY|SELL)(?:\s+([\d\/\.\-@]+))?', line, re.IGNORECASE)
            if match_symbol_type_simple:
                raw_symbol = match_symbol_type_simple.group(1).upper()
                # Handle compound symbols like "XAUUSD / GOLD" - use the first one or map appropriately
                if '/' in raw_symbol:
                    symbol_parts = [part.strip() for part in raw_symbol.split('/')]
                    # Use the first symbol, but check if any part maps to a known symbol
                    for part in symbol_parts:
                        if part in symbol_mappings:
                            raw_symbol = symbol_mappings[part]
                            break
                        elif part in ['XAUUSD', 'BTCUSD', 'EURUSD']:  # Known forex symbols take precedence
                            raw_symbol = part
                            break
                    else:
                        # If no mapping found, use the first symbol
                        raw_symbol = symbol_parts[0]
                
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_symbol_type_simple.group(2).upper()
                # Check if there's an entry price in the same line
                entry_text = match_symbol_type_simple.group(3)
                if entry_text:
                    signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 5: "BTCUSD | BUY 109500" (symbol | type price)
            match_pipe_format = re.match(r'^([\w\.\/\-]+)\s*\|\s*(BUY|SELL)\s+([\d\/\.\-@]+)', line, re.IGNORECASE)
            if match_pipe_format:
                raw_symbol = match_pipe_format.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_pipe_format.group(2).upper()
                entry_text = match_pipe_format.group(3)
                signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 6: "I'M SELLING XAUUSD NOW (3337 - 3340)" - handle NOW with range in parentheses
            match_im_now = re.match(r'^I[\'\u2019]?M\s+(SELLING|BUYING)\s+([\w\.\/\-]+)\s+NOW\s*\(([\d\-\s@\.]+)\)', line, re.IGNORECASE)
            if match_im_now:
                action = match_im_now.group(1).upper()
                signal["signal_type"] = "SELL" if action == "SELLING" else "BUY"
                raw_symbol = match_im_now.group(2).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                # Extract and parse the range from parentheses as entry price
                range_text = match_im_now.group(3).strip()
                signal["entry"] = parse_entry_price(range_text, signal["signal_type"])
                signal["_range_info"] = range_text  # Keep for reference
                continue

        # Entry Price parsing
        if not signal.get("entry"):
            # Look for ENTRY keyword with optional colon
            m = re.search(r'ENTRY\s*:?\s*(?:at\s+)?([\d\/\.\-@]+)', line, re.IGNORECASE)
            if m:
                entry_text = m.group(1)
                signal["entry"] = parse_entry_price(entry_text, signal.get("signal_type", "BUY"))
                continue
            
            # NEW: Check for standalone entry price line (just numbers with optional slash)
            # This should be a line that looks like an entry price but not TPs
            entry_standalone_pattern = r'^([\d\.]+(?:/[\d\.]+)?)$'
            entry_match = re.match(entry_standalone_pattern, line.strip())
            if entry_match and signal.get("signal_type") and signal.get("symbol"):
                # Make sure this looks like an entry price and not TPs
                entry_text = entry_match.group(1)
                potential_entry = parse_entry_price(entry_text, signal.get("signal_type", "BUY"))
                
                # Simple heuristic: if it's a range (contains /), treat as entry
                # or if it's a single reasonable value for the symbol
                if '/' in entry_text or (isinstance(potential_entry, (int, float)) and potential_entry > 0):
                    signal["entry"] = potential_entry
                    continue

        # Take Profits parsing - consolidated and improved
        # Check for various TP patterns in order of specificity
        tp_patterns = [
            r'[🤑💰✅]\s*TP\d*\s*:\s*([\d\.]+(?:/[\d\.]+)*|open)',   # Emoji TP formats like "💰TP1: 3289.0", "💰TP2: 3331" (with colon)
            r'[🤑💰✅]\s*TP\d+\s+([\d\.]+(?:/[\d\.]+)*|open)',      # Emoji TP formats like "✅TP1 109700" (without colon)
            r'T\.P\d+\s+([\d\.]+|open)',                             # "T.P1 114600", "T.P2 114500" (T.P format)
            r'TP\s*\d+\s*:\s*([\d\.]+|open)',                        # "TP1: 3289.0", "TP 2 : open", "Tp 1 : 3346" (with colon)
            r'TP\d+\s+([\d\.]+|open)',                               # "TP1 3420", "TP2 3423" (without colon, with number)
            r'TP\s*:\s*([\d\.]+|open)',                              # "TP: 1.1455", "TP: open"
            r'(?:TAKE\s*PROFIT)\s*\d*\s*(?:at\s+)?([\d\.]+|open)',   # "Take profit 1 at 89500.00", "Take profit 2 at open"
            r'TP\s+([\d\.]+(?:/[\d\.]+)*|open)',                     # "TP 3364" or "TP 3332/3334/3336/3338/3340" or "TP open" (without colon)
        ]
        
        tp_found = False
        for tp_pattern in tp_patterns:
            m = re.search(tp_pattern, line, re.IGNORECASE)
            if m:
                try:
                    tp_values_text = m.group(1)
                    if '/' in tp_values_text:
                        # Multiple TP values separated by slashes
                        tp_values = tp_values_text.split('/')
                        for tp_val in tp_values:
                            if tp_val.strip().lower() == 'open':
                                # Store "open" as a special marker
                                take_profits.append('open')
                            else:
                                tp_value = float(tp_val.strip())
                                if tp_value > 0.1:  # Filter out very small numbers but allow forex values
                                    take_profits.append(tp_value)
                        tp_found = True
                    else:
                        # Single TP value or "open"
                        if tp_values_text.strip().lower() == 'open':
                            # Store "open" as a special marker
                            take_profits.append('open')
                        else:
                            tp_value = float(tp_values_text)
                            if tp_value > 0.1:  # Filter out very small numbers but allow forex values
                                take_profits.append(tp_value)
                        tp_found = True
                    break
                except ValueError:
                    print(f"Warning: Invalid number for TP: {m.group(1)}")
        
        # NEW: Check for slash-separated TP values OR single numeric TP (e.g., "3332/3330/3328/3325" or "3340")
        if not tp_found:
            # Pattern for line containing only numbers separated by slashes OR single number
            # Prioritize lines with multiple values (likely TPs) over single values (could be entry)
            # Updated to handle spaces around slashes (e.g., "3590/ 3595" or "3590 / 3595")
            slash_tp_pattern = r'^([\d\.]+(?:\s*/\s*[\d\.]+)+)$'  # Must have at least one slash (multiple values), spaces allowed
            slash_match = re.match(slash_tp_pattern, line.strip())
            if slash_match:
                tp_values_text = slash_match.group(1)
                # Split by slash and strip whitespace from each value
                tp_values = [val.strip() for val in tp_values_text.split('/') if val.strip()]
                
                for tp_val in tp_values:
                    try:
                        tp_value = float(tp_val)
                        if tp_value > 10:  # Filter out small numbers
                            take_profits.append(tp_value)
                            tp_found = True
                    except ValueError:
                        print(f"Warning: Invalid TP value in numeric format: {tp_val}")
            else:
                # Also check for single numeric TP (but only if we already have signal info and entry)
                single_tp_pattern = r'^([\d\.]+)$'
                single_match = re.match(single_tp_pattern, line.strip())
                if single_match and signal.get("signal_type") and signal.get("entry") is not None:
                    # This is likely a single TP since we already have entry
                    try:
                        tp_value = float(single_match.group(1))
                        if tp_value > 10:  # Filter out small numbers
                            take_profits.append(tp_value)
                            tp_found = True
                    except ValueError:
                        pass
        
        if tp_found:
            continue

        # Stop Loss parsing - enhanced to handle different formats
        if not signal.get("stop_loss"):
            sl_patterns = [
                r'[🔴❌🛑]\s*(?:SL|Stop\s*Loss|STOP\s*LOSS)\s*:?\s*([\d\.]+)',      # Emoji SL formats
                r'(?:STOP\s*LOSS|SL|S\.L)\s*:?\s*(?:at\s+)?([\d\.]+)(?:\s*\([^)]*\))?',  # Regular SL with optional parentheses, including S.L format
                r'SL\s*:\s*([\d\.]+)',                                              # "SL: 3298.8"
                r'S\.L\s+([\d\.]+)',                                                # "S.L   115900" (S.L format)
            ]
            
            for sl_pattern in sl_patterns:
                m = re.search(sl_pattern, line, re.IGNORECASE)
                if m:
                    try:
                        signal["stop_loss"] = float(m.group(1))
                        break
                    except ValueError:
                        print(f"Warning: Invalid number for Stop Loss: {m.group(1)}")

    # Sort take profits and add to signal
    if take_profits:
        # Process "open" TP values - calculate them based on previous TP and signal type
        processed_tps = []
        for i, tp in enumerate(take_profits):
            if tp == 'open':
                # Calculate "open" TP based on the previous TP (if exists) or entry price
                if i > 0 and isinstance(processed_tps[i-1], (int, float)):
                    # Case 1: Previous TP exists - use prev_tp ± 4
                    prev_tp = processed_tps[i-1]
                    if signal.get("signal_type") == "BUY":
                        # For BUY: open TP should be higher (prev_tp + 4)
                        calculated_tp = prev_tp + 4
                    else:
                        # For SELL: open TP should be lower (prev_tp - 4)
                        calculated_tp = prev_tp - 4
                    processed_tps.append(calculated_tp)
                elif signal.get("entry") is not None and signal.get("entry") != 0:
                    # Case 2: No previous TP but have entry - use entry ± 6
                    entry_price = signal.get("entry")
                    if signal.get("signal_type") == "BUY":
                        # For BUY: open TP should be higher (entry + 6)
                        calculated_tp = entry_price + 6
                    else:
                        # For SELL: open TP should be lower (entry - 6)
                        calculated_tp = entry_price - 6
                    processed_tps.append(calculated_tp)
                else:
                    print(f"Warning: Cannot calculate 'open' TP - no previous TP or entry found")
                    # Skip this TP
                    continue
            else:
                processed_tps.append(tp)
        
        take_profits = processed_tps
        
        # Sort TPs based on signal type
        if signal.get("signal_type") == "BUY":
            # For BUY signals, TPs should be in ascending order (higher prices)
            take_profits.sort()
        else:
            # For SELL signals, TPs should be in descending order (lower prices)
            take_profits.sort(reverse=True)
        signal["take_profits"] = take_profits

    # NEW: Simple check for immediate entry - set entry to 0 if NOW keyword found BUT no entry was set
    if 'NOW' in text.upper() and signal.get("entry") is None:
        signal["entry"] = 0

    # Final Validation: Check if all essential parts were found
    if (signal.get("signal_type") and
        signal.get("symbol") and
        signal.get("entry") is not None and
        signal.get("take_profits") and
        len(signal.get("take_profits", [])) > 0 and
        signal.get("stop_loss") is not None):
        
        # Debug: Show parsed signal info
        if signal.get("channel_name"):
            print(f"Debug: Successfully parsed signal from channel '{signal['channel_name']}': {signal['signal_type']} {signal['symbol']}")
        
        return signal
    else:
        # Log which parts are missing if debugging is needed
        missing = []
        if not signal.get("signal_type"):
            missing.append("signal_type")
        if not signal.get("symbol"):
            missing.append("symbol")
        if signal.get("entry") is None:
            missing.append("entry")
        if not signal.get("take_profits") or len(signal.get("take_profits", [])) == 0:
            missing.append("take_profits")
        if signal.get("stop_loss") is None:
            missing.append("stop_loss")
            
        print(f"Debug: Signal parsing incomplete. Missing or invalid parts: {missing}. Original text: {text[:100]}...")
        return None

def format_mt4_comment(group_id: int, channel_name: str, stop_loss: float, digits: int = 5) -> str:
    """
    Format MT4 comment string within 31 character limit.
    
    Format: 1234|ABCD|1.2345 (without GID: and SL: prefixes to save space)
    Where ABCD is the 4-letter channel abbreviation.
    
    Args:
        group_id: Group ID number
        channel_name: Channel name (will be truncated to 4 letters)
        stop_loss: Stop loss value
        digits: Number of decimal places for SL formatting
        
    Returns:
        Formatted comment string within 31 character limit
    """
    # Ensure channel name is 4 characters
    clean_channel = clean_channel_name(channel_name)
    
    # Format SL with minimal precision to save space
    sl_str = f"{stop_loss:.{min(digits, 4)}f}".rstrip('0').rstrip('.')
    
    # Build comment: xxxx|ABCD|value (without GID: and SL: prefixes)
    comment = f"{group_id}|{clean_channel}|{sl_str}"
    
    # If comment exceeds 31 chars, reduce SL precision
    if len(comment) > 31:
        sl_str = f"{stop_loss:.2f}".rstrip('0').rstrip('.')
        comment = f"{group_id}|{clean_channel}|{sl_str}"
    
    # If still too long, reduce to 1 decimal place
    if len(comment) > 31:
        sl_str = f"{stop_loss:.1f}".rstrip('0').rstrip('.')
        comment = f"{group_id}|{clean_channel}|{sl_str}"
    
    # Final truncation if still too long (should not happen with proper formatting)
    if len(comment) > 31:
        comment = comment[:31]
    
    return comment

def is_ready_message(text: str):
    """
    Check if the message matches any ready message pattern for warmup signals.
    
    Args:
        text: Message text to check
        
    Returns:
        tuple: (is_ready: bool, signal_type: str or None, current_price: float or None)
    """
    if not WARMUP_SIGNAL_ENABLED:
        return False, None, None
        
    text_lower = text.lower()
    
    # Determine signal type from ready message patterns
    signal_type = None
    
    # BUY patterns - exact matching for ready messages
    buy_patterns = [
        r"^I'?m\s+buying\s+now[\.\!]*$",
        r"^ready\s+buy[\s\w]*[\.\!]*$",
        r"^Mid\s+risk\s+let'?s\s+scalping\s+buy\s+gold\s+slowly[\.\!]*$", 
        r"^HIGH\s+risk\s+let'?s\s+scalping\s+buy\s+gold\s+slowly[\.\!]*$",
        r"^ANOTHER\s+GOLD\s+BUY\s+READY[\.\!]*$"
    ]
    
    # SELL patterns - exact matching for ready messages  
    sell_patterns = [
        r"^I'?m\s+selling\s+now[\.\!]*$",
        r"^Let'?s\s+scalping\s+sell\s+gold\s+slowly\s+mid\s+risk[\.\!]*$",
        r"^ready\s+sell[\s\w]*[\.\!]*$",
        r"^Double\s+sell\s+ready[\.\!]*$",
        r"^GOLD\s+SELL\s+READY[\.\!]*$"
    ]
    
    for pattern in buy_patterns:
        if re.search(pattern, text, re.IGNORECASE):
            signal_type = "BUY"
            break
            
    if not signal_type:
        for pattern in sell_patterns:
            if re.search(pattern, text, re.IGNORECASE):
                signal_type = "SELL"
                break
    
    if signal_type:
        # No price extraction needed - warmup signals use instant execution
        return True, signal_type, None
        
    return False, None, None

def generate_warmup_signal(signal_type: str):
    """
    Generate a warmup signal with zero values - EA calculates actual TP/SL.
    
    Args:
        signal_type: "BUY" or "SELL"
        
    Returns:
        dict: Generated warmup signal data with zeros for EA calculation
    """
    if not WARMUP_SIGNAL_ENABLED:
        return None
        
    # Generate signal data structure with zeros - let EA calculate actual values
    signal_data = {
        "signal_type": signal_type,
        "symbol": "XAUUSD",  # Default to XAUUSD for GOLD signals
        "entry": 0,  # EA will use current market price
        "take_profits": [0, 0],  # EA will calculate based on its logic
        "stop_loss": 0,  # EA will calculate based on its logic
        "channel_name": WARMUP_SIGNAL_CHANNEL,  # Use configured channel name
        "is_warmup": True  # Flag to identify warmup signals
    }
    
    return signal_data
