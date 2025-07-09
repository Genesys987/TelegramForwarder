import re

# Dictionary of common symbol mappings
symbol_mappings = {
    'GOLD': 'XAUUSD'
}

def clean_channel_name(channel_name: str) -> str:
    """
    Clean channel name by removing emojis and unwanted characters.
    
    Args:
        channel_name: Raw channel name/title that may contain emojis
        
    Returns:
        Clean channel name with exactly 4 letters for MT4 comment limit
    """
    if not channel_name or not channel_name.strip():
        return "UNKN"
    
    # Remove emojis using regex pattern for most Unicode emoji ranges
    emoji_pattern = re.compile(
        "["
        "\U0001F600-\U0001F64F"  # emoticons
        "\U0001F300-\U0001F5FF"  # symbols & pictographs
        "\U0001F680-\U0001F6FF"  # transport & map symbols
        "\U0001F1E0-\U0001F1FF"  # flags (iOS)
        "\U00002500-\U00002BEF"  # chinese char
        "\U00002702-\U000027B0"
        "\U00002702-\U000027B0"
        "\U000024C2-\U0001F251"
        "\U0001f926-\U0001f937"
        "\U00010000-\U0010ffff"
        "\u2640-\u2642"
        "\u2600-\u2B55"
        "\u200d"
        "\u23cf"
        "\u23e9"
        "\u231a"
        "\ufe0f"  # dingbats
        "\u3030"
        "]+", flags=re.UNICODE)
    
    # Remove emojis
    clean_name = emoji_pattern.sub('', channel_name)
    
    # Remove unwanted characters (keep only alphanumeric and spaces, remove underscores)
    clean_name = re.sub(r'[^\w\s]', '', clean_name)  # First remove non-word chars except spaces
    clean_name = re.sub(r'_', '', clean_name)        # Then remove underscores specifically
    
    # Remove extra whitespace
    clean_name = re.sub(r'\s+', ' ', clean_name).strip()
    
    # Convert to uppercase and extract only alphabetic characters
    clean_name = clean_name.upper()
    alpha_only = re.sub(r'[^A-Z]', '', clean_name)
    
    # Take first 4 letters or pad with 'U' if too short
    if alpha_only:
        result = alpha_only[:4]
    else:
        result = ""
    
    # Ensure exactly 4 characters
    if len(result) < 4:
        result = (result + "UNKN")[:4]
    
    return result

def parse_entry_price(entry_text, signal_type):
    """
    Parse entry price from text, handling range formats like '3313/3315'
    
    Args:
        entry_text: The entry price text to parse
        signal_type: 'BUY' or 'SELL' to determine which price to use from ranges
    
    Returns:
        Parsed entry price as float or original text if parsing fails
    """
    if '/' in entry_text:
        split = entry_text.split('/')
        # keep the higher of range (sell) or lower (buy)
        if signal_type == "SELL":
            return max(float(split[0]), float(split[1]))
        else:
            return min(float(split[0]), float(split[1]))
    else:
        try:
            return float(entry_text)
        except ValueError:
            return entry_text

def parse_single_line_signal(text):
    """
    Parse a single-line signal where all components are on one line
    Example: "BUY BTCUSD ENTRY 89300.00 TP 89500.00 SL 88600.00"
    """
    text = text.strip()
    if not text:
        return None
    
    signal = {}
    take_profits = []
    
    # Try different single-line patterns
    
    # Pattern 1: Pipe format "BTCUSD | BUY 109500 ❌ Stop Loss 109000 ✅TP1 109700"
    pipe_pattern = r'([\w\.\/\-]+)\s*\|\s*(BUY|SELL)\s+([\d\/\.]+)'
    pipe_match = re.search(pipe_pattern, text, re.IGNORECASE)
    if pipe_match:
        raw_symbol = pipe_match.group(1).upper()
        signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
        signal["signal_type"] = pipe_match.group(2).upper()
        signal["entry"] = parse_entry_price(pipe_match.group(3), signal["signal_type"])
    
    # Pattern 2: Regular format "BUY BTCUSD ENTRY 89300.00" or "SELL XAUUSD 3290.5"
    # Also handle FROM format "GOLD SELL FROM 3313/3315.3" and "XAUUSD BUY 3417"
    if not signal.get("signal_type"):
        regular_patterns = [
            r'([\w\.\/\-]+)\s+(BUY|SELL)\s+FROM\s+([\d\/\.]+)',  # GOLD SELL FROM 3313/3315.3
            r'([\w\.\/\-]+)\s+(BUY|SELL)\s+([\d\/\.]+)',         # XAUUSD BUY 3417
            r'(BUY|SELL)\s+([\w\.\/\-]+)(?:\s+ENTRY\s+)?([\d\/\.]+)',  # BUY BTCUSD ENTRY 89300.00
            r'(BUY|SELL)\s+([\w\.\/\-]+)\s+([\d\/\.]+)',         # SELL XAUUSD 3290.5
        ]
        
        for pattern in regular_patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                if 'FROM' in pattern:
                    # FROM format: SYMBOL BUY/SELL FROM price
                    raw_symbol = match.group(1).upper()
                    signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    signal["signal_type"] = match.group(2).upper()
                    signal["entry"] = parse_entry_price(match.group(3), signal["signal_type"])
                elif pattern == r'([\w\.\/\-]+)\s+(BUY|SELL)\s+([\d\/\.]+)':
                    # SYMBOL BUY/SELL price format: XAUUSD BUY 3417
                    raw_symbol = match.group(1).upper()
                    signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    signal["signal_type"] = match.group(2).upper()
                    signal["entry"] = parse_entry_price(match.group(3), signal["signal_type"])
                else:
                    # Regular format: BUY/SELL SYMBOL price
                    signal["signal_type"] = match.group(1).upper()
                    raw_symbol = match.group(2).upper()
                    signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                    signal["entry"] = parse_entry_price(match.group(3), signal["signal_type"])
                break
    
    # Extract all TP values using multiple patterns
    tp_patterns = [
        r'[🤑✅]\s*TP(\d*)\s*:?\s*([\d\.]+)',        # Emoji TP with number capture
        r'TP(\d+)\s*:?\s*([\d\.]+)',                  # TP1: 3289.0 or TP1 3289.0
        r'TP\s*:?\s*([\d\.]+)',                       # TP: 89500.00 or TP 89500.00 (no number)
        r'Take\s+profit\s+(\d+)\s+at\s+([\d\.]+)',   # Take profit 1 at 89500.00
    ]
    
    for tp_pattern in tp_patterns:
        tp_matches = re.findall(tp_pattern, text, re.IGNORECASE)
        for tp_match in tp_matches:
            try:
                if isinstance(tp_match, tuple):
                    # If pattern captured both number and value, use the value
                    tp_value = float(tp_match[-1])  # Last element is the price
                else:
                    tp_value = float(tp_match)
                
                if tp_value not in take_profits and tp_value > 10:  # Filter out small numbers (likely indices)
                    take_profits.append(tp_value)
            except ValueError:
                continue
    
    # Extract SL value using multiple patterns
    sl_patterns = [
        r'[🔴❌]\s*(?:SL|Stop\s*Loss)\s*:?\s*([\d\.]+)',  # Emoji SL
        r'SL\s*:?\s*([\d\.]+)',                           # SL: 88600.00 or SL 88600.00
        r'Stop\s+loss\s+(?:at\s+)?([\d\.]+)',            # Stop loss at 88600.00
    ]
    
    for sl_pattern in sl_patterns:
        sl_match = re.search(sl_pattern, text, re.IGNORECASE)
        if sl_match:
            try:
                signal["stop_loss"] = float(sl_match.group(1))
                break
            except ValueError:
                continue
    
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
            # Format 1: "BUY BTCUSD" or "SELL GOLD" or "BUY CHFJPY 180.430"
            match_type_symbol = re.match(r'^(BUY|SELL)\s+([\w\.\/\-]+)\s*([\d\/\.]*)', line, re.IGNORECASE)
            if match_type_symbol:
                signal["signal_type"] = match_type_symbol.group(1).upper()
                raw_symbol = match_type_symbol.group(2).upper()
                # Map symbol if it exists in our mappings, otherwise use as-is
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                # Capture the entry price if present
                entry_text = match_type_symbol.group(3).strip()
                if entry_text:
                    signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 2: "GOLD SELL FROM 3313/3315" or "SYMBOL BUY FROM price"
            match_symbol_type = re.match(r'^([\w\.\/\-]+)\s+(BUY|SELL)\s+FROM\s+([\d\/\.]+)', line, re.IGNORECASE)
            if match_symbol_type:
                raw_symbol = match_symbol_type.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_symbol_type.group(2).upper()
                # Also capture the entry price from the FROM clause
                entry_text = match_symbol_type.group(3)
                signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 3: "EURUSD BUY" or "XAUUSD BUY" or "XAUUSD BUY 3417" (symbol first, then type, optional price)
            match_symbol_type_simple = re.match(r'^([\w\.\/\-]+)\s+(BUY|SELL)(?:\s+([\d\/\.]+))?', line, re.IGNORECASE)
            if match_symbol_type_simple:
                raw_symbol = match_symbol_type_simple.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_symbol_type_simple.group(2).upper()
                # Check if there's an entry price in the same line
                entry_text = match_symbol_type_simple.group(3)
                if entry_text:
                    signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue
            
            # Format 4: "BTCUSD | BUY 109500" (symbol | type price)
            match_pipe_format = re.match(r'^([\w\.\/\-]+)\s*\|\s*(BUY|SELL)\s+([\d\/\.]+)', line, re.IGNORECASE)
            if match_pipe_format:
                raw_symbol = match_pipe_format.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_pipe_format.group(2).upper()
                entry_text = match_pipe_format.group(3)
                signal["entry"] = parse_entry_price(entry_text, signal["signal_type"])
                continue

        # Entry Price parsing
        if not signal.get("entry"):
            # Look for ENTRY keyword with optional colon
            m = re.search(r'ENTRY\s*:?\s*(?:at\s+)?([\d\/\.]+)', line, re.IGNORECASE)
            if m:
                entry_text = m.group(1)
                signal["entry"] = parse_entry_price(entry_text, signal.get("signal_type", "BUY"))
                continue

        # Take Profits parsing - consolidated and improved
        # Check for various TP patterns in order of specificity
        tp_patterns = [
            r'[🤑✅]\s*TP\d*\s*:?\s*([\d\.]+)',               # Emoji TP formats like "🤑TP1: 3289.0" or "✅TP1 109700"
            r'TP\d+\s*:?\s*([\d\.]+)',                         # "TP1: 3289.0", "TP1 3420", "TP2 3423"
            r'TP\s*:\s*([\d\.]+)',                             # "TP: 1.1455"
            r'(?:TAKE\s*PROFIT)\s*\d*\s*(?:at\s+)?([\d\.]+)',  # "Take profit 1 at 89500.00"
            r'TP\s+([\d\.]+)',                                 # "TP 3364"
        ]
        
        tp_found = False
        for tp_pattern in tp_patterns:
            m = re.search(tp_pattern, line, re.IGNORECASE)
            if m:
                try:
                    tp_value = float(m.group(1))
                    take_profits.append(tp_value)
                    tp_found = True
                    break
                except ValueError:
                    print(f"Warning: Invalid number for TP: {m.group(1)}")
        
        if tp_found:
            continue

        # Stop Loss parsing - enhanced to handle different formats
        if not signal.get("stop_loss"):
            sl_patterns = [
                r'[🔴❌]\s*(?:SL|Stop\s*Loss)\s*:?\s*([\d\.]+)',                # Emoji SL formats
                r'(?:STOP\s*LOSS|SL)\s*:?\s*(?:at\s+)?([\d\.]+)(?:\s*\([^)]*\))?',  # Regular SL with optional parentheses
                r'SL\s*:\s*([\d\.]+)',                                          # "SL: 3298.8"
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
        # Sort TPs based on signal type
        if signal.get("signal_type") == "BUY":
            # For BUY signals, TPs should be in ascending order (higher prices)
            take_profits.sort()
        else:
            # For SELL signals, TPs should be in descending order (lower prices)
            take_profits.sort(reverse=True)
        signal["take_profits"] = take_profits

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

# Test function to verify 4-letter channel name formatting
def test_channel_name_cleaning():
    """Test cases for channel name cleaning to 4-letter format"""
    test_cases = [
        ("🔥 Trading Signals Elite 🚀", "TRAD"),
        ("CRYPTO MASTER SIGNALS", "CRYP"),
        ("Gold & Forex VIP", "GOLD"),
        ("ABC123", "ABCU"),  # ABC + U (padding)
        ("", "UNKN"),
        ("x", "XUNK"),
        ("12345", "UNKN"),
        ("🎯📊💎 VIP SIGNALS 📊💎🎯", "VIPS"),
        ("Trading_Channel_Pro", "TRAD"),
        ("   SPACE   SIGNALS   ", "SPAC"),
    ]
    
    print("Testing channel name cleaning (4-letter format):")
    for input_name, expected in test_cases:
        result = clean_channel_name(input_name)
        status = "✅" if result == expected else "❌"
        print(f"{status} '{input_name}' -> '{result}' (expected: '{expected}')")
    
    # Test MT4 comment formatting
    print("\nTesting MT4 comment formatting:")
    test_comments = [
        (12345, "TRADING SIGNALS", 1.23456, 5),
        (999, "CRYPTO MASTER", 3456.789, 3),
        (1, "VIP", 123.0, 2),
        (999999, "SUPER LONG CHANNEL NAME", 12345.67890, 5),  # Test long values
        (1, "A", 0.001, 5),  # Test minimal values
        (12345, "FOREX", 1.123456789, 8),  # Test high precision
    ]
    
    for gid, channel, sl, digits in test_comments:
        comment = format_mt4_comment(gid, channel, sl, digits)
        status = "✅" if len(comment) <= 31 else "❌"
        print(f"{status} GID:{gid}, Channel:'{channel}', SL:{sl} -> '{comment}' (len: {len(comment)})")
        
    # Test edge cases for 31-character limit
    print("\nTesting edge cases for 31-character limit:")
    edge_cases = [
        (123456, "TEST", 123456.789, 5),  # Very long numbers
        (1, "X", 0.000001, 6),  # Very small numbers with high precision
        (99999, "ABCD", 99999.999, 3),  # Maximum likely values
        (999999, "LONG", 99999.999, 5),  # Test very long GID
    ]
    
    for gid, channel, sl, digits in edge_cases:
        comment = format_mt4_comment(gid, channel, sl, digits)
        status = "✅" if len(comment) <= 31 else "❌"
        print(f"{status} GID:{gid}, Channel:'{channel}', SL:{sl} -> '{comment}' (len: {len(comment)})")
        
    # Test space savings comparison
    print("\nSpace savings comparison (old vs new format):")
    old_format_examples = [
        "GID:12345|TRAD|SL:1.2346",  # Old format
        "GID:999|CRYP|SL:3456.789",
        "GID:1|VIPU|SL:123",
    ]
    
    for old in old_format_examples:
        # Remove GID: and SL: to simulate new format
        new = old.replace("GID:", "").replace("SL:", "")
        saved = len(old) - len(new)
        print(f"Old: '{old}' ({len(old)} chars) -> New: '{new}' ({len(new)} chars) | Saved: {saved} chars")
        
def demonstrate_space_savings():
    """Demonstrate how much space is saved by removing GID: and SL: prefixes"""
    print("\n" + "="*60)
    print("SPACE SAVINGS DEMONSTRATION")
    print("="*60)
    
    # Realistic trading scenarios
    scenarios = [
        (12345, "FOREX ELITE SIGNALS", 1.23456, 5),
        (999, "CRYPTO MASTER PRO", 45678.901, 3),
        (1, "VIP GOLD ALERTS", 2345.67, 4),
        (567890, "BITCOIN SIGNALS VIP", 98765.432, 2),
        (9999, "PREMIUM TRADING", 123.456789, 6),
    ]
    
    total_old_chars = 0
    total_new_chars = 0
    
    for gid, channel, sl, digits in scenarios:
        new_comment = format_mt4_comment(gid, channel, sl, digits)
        old_comment = f"GID:{gid}|{clean_channel_name(channel)}|SL:{new_comment.split('|')[2]}"
        
        saved = len(old_comment) - len(new_comment)
        total_old_chars += len(old_comment)
        total_new_chars += len(new_comment)
        
        print(f"Channel: {channel[:20]:<20}")
        print(f"  Old: '{old_comment}' ({len(old_comment)} chars)")
        print(f"  New: '{new_comment}' ({len(new_comment)} chars)")
        print(f"  Saved: {saved} characters")
        print()
    
    total_saved = total_old_chars - total_new_chars
    print(f"TOTAL SAVINGS: {total_saved} characters across {len(scenarios)} comments")
    print(f"Average savings per comment: {total_saved/len(scenarios):.1f} characters")
    print(f"Space efficiency: {(total_saved/total_old_chars)*100:.1f}% reduction")
    print("="*60)

if __name__ == "__main__":
    test_channel_name_cleaning()
    demonstrate_space_savings()
