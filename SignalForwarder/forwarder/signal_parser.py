import re

def remove_emojis(text):
    """Remove emojis from text using regex"""
    # Pattern to match emoji characters
    emoji_pattern = re.compile("["
                               u"\U0001F600-\U0001F64F"  # emoticons
                               u"\U0001F300-\U0001F5FF"  # symbols & pictographs
                               u"\U0001F680-\U0001F6FF"  # transport & map symbols
                               u"\U0001F1E0-\U0001F1FF"  # flags (iOS)
                               u"\U00002702-\U000027B0"
                               u"\U000024C2-\U0001F251"
                               "]+", flags=re.UNICODE)
    return emoji_pattern.sub(r'', text)

# Dictionary of common symbol mappings
symbol_mappings = {
    'GOLD': 'XAUUSD',
    'XAUUSD': 'XAUUSD',
    'BTCUSD': 'BTCUSD',
    'EURUSD': 'EURUSD',
    'GBPUSD': 'GBPUSD',
    'USDJPY': 'USDJPY',
    'AUDUSD': 'AUDUSD',
    'USDCAD': 'USDCAD',
    'NZDUSD': 'NZDUSD',
    'USDCHF': 'USDCHF',
    'SILVER': 'XAGUSD',
    'XAGUSD': 'XAGUSD'
}

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
    
    # Remove emojis from the message before parsing
    text = remove_emojis(text)
    
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
                # Capture the entry price
                entry_text = match_type_symbol.group(3)
                # If it contains a range (like 3313/3315), keep as string
                if '/' in entry_text:
                    split = entry_text.split('/')
                    # keep the higher of range (sell) or lower (buy)
                    if signal["signal_type"] == "SELL":
                        signal["entry"] = max(float(split[0]), float(split[1]))
                    else:
                        signal["entry"] = min(float(split[0]), float(split[1]))
                else:
                    try:
                        signal["entry"] = float(entry_text)
                    except ValueError:
                        signal["entry"] = entry_text
                continue
            
            # Format 2: "GOLD SELL FROM 3313/3315" or "SYMBOL BUY FROM price"
            match_symbol_type = re.match(r'^([\w\.\/\-]+)\s+(BUY|SELL)\s+FROM\s+([\d\/\.]+)', line, re.IGNORECASE)
            if match_symbol_type:
                raw_symbol = match_symbol_type.group(1).upper()
                signal["symbol"] = symbol_mappings.get(raw_symbol, raw_symbol)
                signal["signal_type"] = match_symbol_type.group(2).upper()
                # Also capture the entry price from the FROM clause
                entry_text = match_symbol_type.group(3)
                # If it contains a range (like 3313/3315), keep as string
                if '/' in entry_text:
                    split = entry_text.split('/')
                    # keep the higher of range (sell) or lower (buy)
                    if signal["signal_type"] == "SELL":
                        signal["entry"] = max(float(split[0]), float(split[1]))
                    else:
                        signal["entry"] = min(float(split[0]), float(split[1]))
                else:
                    try:
                        signal["entry"] = float(entry_text)
                    except ValueError:
                        signal["entry"] = entry_text
                continue

        # Entry Price parsing
        if not signal.get("entry"):
            # Look for ENTRY keyword
            m = re.search(r'ENTRY\s*(?:at)?\s*([\d\/\.]+)', line, re.IGNORECASE)
            if m:
                entry_text = m.group(1)
                # If it contains a range (like 3313/3315), keep as string
                if '/' in entry_text:
                    signal["entry"] = entry_text
                else:
                    try:
                        signal["entry"] = float(entry_text)
                    except ValueError:
                        signal["entry"] = entry_text
                continue

        # Take Profits parsing - flexible, any line with TP
        # Look for any TP pattern (TP, Take Profit, etc.) followed by a number
        tp_match = re.search(r'(?:TAKE\s*PROFIT|TP)\s*(?:\d+:?\s+)?(?:at\s+)?([\d\.]+)', line, re.IGNORECASE)
        if tp_match:
            try:
                tp_value = float(tp_match.group(1))
                take_profits.append(tp_value)
                continue
            except ValueError:
                print(f"Warning: Invalid number for TP: {tp_match.group(1)}")

        # Stop Loss parsing
        if not signal.get("stop_loss"):
            # Allow "Stop loss", "Stoploss", "SL"
            sl_pattern = r'(?:STOP\s*LOSS|SL):?\s*(?:at)?\s*([\d\.]+)'
            m = re.search(sl_pattern, line, re.IGNORECASE)
            if m:
                try:
                    signal["stop_loss"] = float(m.group(1))
                    continue
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
