# --- signal_parser.py (No changes needed) ---

import re

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
    if not text: return None # Handle empty input
    lines = text.splitlines()
    signal = {}
    tp_found = [False, False, False] # Track found TPs

    for line in lines:
        line = line.strip()
        if not line: continue # Skip empty lines

        # Signal Type and Symbol (Expects on first non-empty line usually)
        if not signal.get("signal_type"): # Only parse if not already found
             # Match BUY/SELL at the start, followed by symbol
            match_type_symbol = re.match(r'^(BUY|SELL)\s+([\w\.\/\-]+)', line, re.IGNORECASE)
            if match_type_symbol:
                signal["signal_type"] = match_type_symbol.group(1).upper()
                signal["symbol"] = match_type_symbol.group(2).upper()
                continue # Move to next line once type/symbol found

        # Entry Price
        if not signal.get("entry"):
            m = re.search(r'ENTRY\s*(?:at)?\s*([\d]+\.?[\d]*)', line, re.IGNORECASE)
            if m:
                try:
                    signal["entry"] = float(m.group(1))
                    continue
                except ValueError:
                    print(f"Warning: Invalid number for ENTRY: {m.group(1)}")

        # Take Profits
        for i in range(1, 4):
            if not tp_found[i-1]: # Only parse if not already found
                # Allow variations like "TP1", "Take Profit 1", "Take profit1"
                tp_pattern = r'(?:TAKE\s*PROFIT|TP)\s*' + str(i) + r'\s*(?:at)?\s*([\d]+\.?[\d]*)'
                m = re.search(tp_pattern, line, re.IGNORECASE)
                if m:
                    try:
                        # Initialize take_profits list if first TP is found
                        if "take_profits" not in signal:
                             signal["take_profits"] = [None, None, None]
                        signal["take_profits"][i-1] = float(m.group(1))
                        tp_found[i-1] = True
                        # Found a TP on this line, continue to next line
                        # (avoid accidentally matching SL as TP if format is weird)
                        # Use 'break' if one line can only contain one piece of info
                        # Use 'continue' if one line *might* contain multiple (less likely for signals)
                        continue
                    except ValueError:
                        print(f"Warning: Invalid number for TP{i}: {m.group(1)}")

        # Stop Loss
        if not signal.get("stop_loss"):
             # Allow "Stop loss", "Stoploss", "SL"
             sl_pattern = r'(?:STOP\s*LOSS|SL)\s*(?:at)?\s*([\d]+\.?[\d]*)'
             m = re.search(sl_pattern, line, re.IGNORECASE)
             if m:
                 try:
                     signal["stop_loss"] = float(m.group(1))
                     continue
                 except ValueError:
                      print(f"Warning: Invalid number for Stop Loss: {m.group(1)}")

    # Final Validation: Check if all essential parts were found
    if ("signal_type" in signal and
        "symbol" in signal and
        "entry" in signal and
        "take_profits" in signal and
        all(tp is not None for tp in signal.get("take_profits", [])) and # Ensure all 3 TPs were found
        "stop_loss" in signal):
        return signal
    else:
        # Log which parts are missing if debugging is needed
        missing = [k for k in ["signal_type", "symbol", "entry", "take_profits", "stop_loss"] if k not in signal or (k == "take_profits" and not all(tp is not None for tp in signal.get("take_profits", [])))]
        print(f"Debug: Signal parsing incomplete. Missing or invalid parts: {missing}. Original text: {text[:100]}...")
        return None