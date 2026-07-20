import logging
import re
import unicodedata
from signal_data import SignalData

logger = logging.getLogger(__name__)

# Dictionary of common symbol mappings
symbol_mappings = {
    "GOLD": "XAUUSD",
    "GODL": "XAUUSD",
    "BTC/USDT": "BTCUSD",
    "XAU/USD": "XAUUSD",
    "EUR-USD": "EURUSD",
    "NQ": "NAS100"
}


def clean_invisible_chars(text: str) -> str:
    """
    Remove invisible/hidden characters from text.
    This includes:
    - Non-breaking spaces (U+00A0)
    - Zero-width spaces (U+200B)
    - Zero-width non-joiners (U+200C)
    - Zero-width joiners (U+200D)
    - Other invisible Unicode characters
    - *_=+ markdown characters

    Args:
        text: Input text that may contain invisible characters

    Returns:
        Cleaned text with invisible characters removed
    """
    if not text:
        return text

    # Replace invisible characters line by line to preserve structure
    lines = text.splitlines()
    cleaned_lines = []

    for line in lines:
        # Replace invisible characters with regular spaces to preserve word boundaries
        invisible_chars = {
            "\u00a0": " ",  # Non-breaking space -> regular space
            "\u200b": "",  # Zero-width space -> nothing
            "\u200c": "",  # Zero-width non-joiner -> nothing
            "\u200d": "",  # Zero-width joiner -> nothing
            "\u2060": "",  # Word joiner -> nothing
            "\ufeff": "",  # Byte order mark / Zero-width no-break space -> nothing
        }

        cleaned_line = line
        for char, replacement in invisible_chars.items():
            cleaned_line = cleaned_line.replace(char, replacement)

        # Also normalize Unicode to remove any other hidden characters
        cleaned_line = unicodedata.normalize("NFKC", cleaned_line)

        # Clean up multiple spaces that might have been introduced
        cleaned_line = re.sub(r" +", " ", cleaned_line)
        # Remove markdown characters (but preserve '#' used in signal format and '+' used as price range separator)
        cleaned_line = re.sub(r"[*_=]", "", cleaned_line)
        # Remove '+' only when it's NOT between two digits (preserve "5360+5350" style ranges)
        cleaned_line = re.sub(r"(?<!\d)\+|\+(?!\d)", "", cleaned_line)

        # Normalize superscript digits to regular digits (TP¹ → TP1, etc.)
        superscript_map = str.maketrans("\u00b9\u00b2\u00b3\u2074\u2075\u2076\u2077\u2078\u2079\u2070",
                                        "1234567890")
        cleaned_line = cleaned_line.translate(superscript_map)

        cleaned_lines.append(cleaned_line)

    return "\n".join(cleaned_lines)


def strip_emojis_from_line(text: str) -> str:
    """
    Strip emoji and decorative Unicode characters from a line for pattern matching.
    Preserves standard ASCII punctuation, en/em dashes, and alphanumeric characters.
    """
    emoji_pattern = re.compile(
        "["
        "\U0001F300-\U0001FAFF"  # Misc symbols, emoticons
        "\U00002600-\U000027BF"  # Misc symbols (⚠️, ✅, ⭐ etc.)
        "\U00002B00-\U00002BFF"  # Misc symbols and arrows (⭐)
        "\U00002300-\U000023FF"  # Misc technical
        "\U00002194-\U000021FF"  # Arrows
        "\U0000FE00-\U0000FE0F"  # Variation selectors
        "]+",
        flags=re.UNICODE,
    )
    stripped = emoji_pattern.sub(" ", text)
    stripped = re.sub(r" +", " ", stripped).strip()
    return stripped


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
    alpha_only = re.sub(r"[^A-Z]", "", clean_name)

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


def expand_abbreviated_price(price_text):
    """
    Expand abbreviated price format like '4207/04' to '4207/4204'

    Args:
        price_text: Text that may contain abbreviated prices

    Returns:
        Expanded price text or original if no abbreviation found
    """
    if "/" not in price_text:
        return price_text

    parts = price_text.split("/")
    if len(parts) != 2:
        return price_text

    first_price = parts[0].strip()
    second_price = parts[1].strip()

    # Check if second price is abbreviated (2 digits)
    if len(second_price) == 2 and second_price.isdigit() and len(first_price) >= 3:
        # Expand by taking first digits from first price + abbreviated part
        base_digits = first_price[:-2]  # All but last 2 digits
        expanded_second = base_digits + second_price
        return f"{first_price}/{expanded_second}"

    return price_text


def is_buy_signal(signal_type: str | None) -> bool:
    return signal_type in {"BUY", "BUYLIMIT"}


def is_sell_signal(signal_type: str | None) -> bool:
    return signal_type in {"SELL", "SELLLIMIT"}


def parse_entry_price(entry_text, signal_type):
    """
    Parse entry price from text, handling range formats like '3334/3337', '3339-3344', '@3339-3344', '4207/04'

    Args:
        entry_text: The entry price text to parse
        signal_type: 'BUY' or 'SELL' to determine which price to use from ranges

    Returns:
        Parsed entry price as float or original text if parsing fails
    """
    # Clean up the entry text - remove @ symbol and extra spaces
    entry_text = entry_text.strip().lstrip("@").strip()

    # Expand abbreviated prices like 4207/04 -> 4207/4204
    entry_text = expand_abbreviated_price(entry_text)

    # Handle __ separator (e.g. "5185 __ 5196")
    if "__" in entry_text:
        split = re.split(r"__+", entry_text)
        try:
            prices = [float(p.strip()) for p in split if p.strip()]
            if prices:
                return min(prices) if signal_type == "SELL" else max(prices)
        except ValueError:
            pass
        return entry_text

    # Handle different range separators (including space-separated like "3340.5 -3338")
    if "/" in entry_text:
        split = entry_text.split("/")
    elif "+" in entry_text:
        split = entry_text.split("+")
    elif "-" in entry_text or "–" in entry_text or "—" in entry_text:
        # Handle various dash formats: regular dash (-), en dash (–), em dash (—)
        if " -" in entry_text:
            split = entry_text.split(" -")
        elif " –" in entry_text:
            split = entry_text.split(" –")
        elif " —" in entry_text:
            split = entry_text.split(" —")
        elif "–" in entry_text:
            split = entry_text.split("–")
        elif "—" in entry_text:
            split = entry_text.split("—")
        else:
            split = entry_text.split("-")
    else:
        # No price range detected, try to parse as single numeric value
        try:
            return float(entry_text.strip())
        except ValueError:
            print(f"Warning: Invalid entry price format: {entry_text}")
            return entry_text

    try:
        # Convert to floats for proper comparison
        prices = [float(p.strip()) for p in split if p.strip()]

        if not prices:
            return entry_text

        # For SELL/SELLLIMIT: use lower price as range limit
        # For BUY/BUYLIMIT: use higher price as range limit
        if is_sell_signal(signal_type):
            return min(prices)
        else:
            return max(prices)
    except ValueError:
        print(f"Warning: Invalid range format: {entry_text}")
        return entry_text



def parse_signal(text: str) -> SignalData | None:
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
        return None  # Handle empty input

    # If the signal contains a ✅ checkmark it means a TP was already hit on a
    # previously processed version of this signal - skip it entirely.
    # Exception: ✅ used decoratively on the same line as a BUY/SELL keyword
    # (e.g. "GOLD buy🔥 ✅ Now") — these are valid new signals, not TP-hit updates.
    if "\u2705" in text:
        has_action_with_checkmark = any(
            "\u2705" in line and re.search(r"\b(?:buy|sell)\b", line, re.IGNORECASE)
            for line in text.splitlines()
        )
        if not has_action_with_checkmark:
            logger.info("Signal contains ✅ (TP hit marker) - skipping")
            return None

    # Clean invisible characters from the input text
    text = clean_invisible_chars(text)

    signal = SignalData()
    take_profits = signal.take_profits

    lines = text.splitlines()
    for line in lines:
        line = line.strip()
        if not line:
            continue  # Skip empty lines

        # Emoji-stripped version of line for reliable pattern matching
        line_clean = strip_emojis_from_line(line)

        # Signal Type and Symbol parsing - handle multiple formats
        if not signal.signal_type:
            # NEW: If symbol already known from a previous line, handle "BUY price" / "SELL price"
            if signal.symbol:
                match_action_price_only = re.match(
                    r"^(BUY|SELL)\s+([\d\.\/\-@]+)$", line_clean, re.IGNORECASE
                )
                if match_action_price_only:
                    signal.signal_type = match_action_price_only.group(1).upper()
                    signal.entry = parse_entry_price(
                        match_action_price_only.group(2), signal.signal_type
                    )
                    continue

            # e.g. NQ – SELL    
            match_symbol_action = re.match(
                r"^([\w\.\/\-]+)\s*[–-]\s*(BUY|SELL)", line_clean, re.IGNORECASE
            )
            if match_symbol_action:
                raw_symbol = match_symbol_action.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_action.group(2).upper()
                continue

            # NEW: Direction: BUY/SELL format (e.g. "Direction: BUY")
            match_direction = re.match(
                r"^Direction\s*:\s*(BUY|SELL|Long|Short)\b", line_clean, re.IGNORECASE
            )
            if match_direction and signal.symbol:
                action = match_direction.group(1).upper()
                signal.signal_type = "SELL" if action == "SHORT" else ("BUY" if action == "LONG" else action)
                continue

            # Format 0a: "XAUUSD Buy here around 4485" - HIGHEST PRIORITY for 'here around' format
            match_here_around = re.match(
                r"^([\w\.\/\-]+)\s+(BUY|SELL)\s+here\s+around\s+([\d\.]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_here_around:
                raw_symbol = match_here_around.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_here_around.group(2).upper()
                signal.entry = float(match_here_around.group(3))
                continue

            # Format 0: "#XAUUSD SELL" - hash prefix with symbol and action
            match_hash_symbol = re.match(
                r"^#([\w\.\/\-]+)\s+(BUY|SELL)", line_clean, re.IGNORECASE
            )
            if match_hash_symbol:
                raw_symbol = match_hash_symbol.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_hash_symbol.group(2).upper()
                continue

            # NEW: "Trade Details: #BUY" / "Trade Details: #SELL" format
            match_trade_details = re.match(
                r"^Trade\s+Details\s*:.*#(BUY|SELL)", line_clean, re.IGNORECASE
            )
            if match_trade_details and signal.symbol:
                signal.signal_type = match_trade_details.group(1).upper()
                continue

            # NEW: "BUY #SYMBOL #SYMBOL2 price" - BUY/SELL with hash-prefixed symbols
            match_action_hash_symbol = re.match(
                r"^(BUY|SELL)\s+#([\w\.\/\-]+)(?:\s+#[\w\.\/\-]+)?\s*([\.\d\/\-@]*)",
                line_clean,
                re.IGNORECASE,
            )
            if match_action_hash_symbol:
                signal.signal_type = match_action_hash_symbol.group(1).upper()
                raw_symbol = match_action_hash_symbol.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                entry_text = match_action_hash_symbol.group(3).strip()
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 0e: "XAUUSD: BUY NOW" - colon after symbol, entry on separate line
            match_symbol_colon_action = re.match(
                r"^([\w\.\/\-]+):\s*(BUY|SELL)(?:\s+NOW)?",
                line_clean,
                re.IGNORECASE,
            )
            if match_symbol_colon_action:
                raw_symbol = match_symbol_colon_action.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_colon_action.group(2).upper()
                continue

            # Format 0f: "GOLD BUY NOW @ price" (emoji-tolerant via line_clean)
            match_symbol_now_at = re.match(
                r"^([\w\.\/\-]+)\s+(BUY|SELL)\s+NOW\s*@\s*([\d\.]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_symbol_now_at:
                raw_symbol = match_symbol_now_at.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_now_at.group(2).upper()
                signal.entry = float(match_symbol_now_at.group(3))
                if not signal.stop_loss:
                    inline_sl = re.search(
                        r"Stop\s+Loss\s*(?:\([^)]*\))?\s*[-:\u2013]?\s*(?:at\s+)?([\d\.]+)",
                        line_clean, re.IGNORECASE
                    )
                    if inline_sl:
                        try:
                            signal.stop_loss = float(inline_sl.group(1))
                        except ValueError:
                            pass
                continue

            # NEW: "Buy EURUSD at any price between 1.1748 till 1.1720" - range entry with 'till'
            match_between_till = re.match(
                r"^(BUY|SELL)\s+([\w\.\/\-]+)\s+at\s+any\s+price\s+between\s+([\d\.]+)\s+till\s+([\d\.]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_between_till:
                signal.signal_type = match_between_till.group(1).upper()
                raw_symbol = match_between_till.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                p1 = float(match_between_till.group(3))
                p2 = float(match_between_till.group(4))
                signal.entry = max(p1, p2) if is_buy_signal(signal.signal_type) else min(p1, p2)
                continue

            # Format 1a: "SELL FROM 4210/4215" - action FROM price without symbol
            match_type_from_no_symbol = re.match(
                r"^(BUY|SELL)\s+FROM\s+([\d\/\.\-@\u2013\u2014]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_type_from_no_symbol:
                signal.signal_type = match_type_from_no_symbol.group(1).upper()
                entry_text = match_type_from_no_symbol.group(2)
                signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 1b: "GOLD SELL FROM/NOW/NOW AT/NOW @ price"
            match_symbol_type_from = re.match(
                r"^([\w\.\/\-]+)\s+(BUY|SELL)\s+(?:FROM|NOW\s*(?:AT|@)?)\s+([\d\/\.\-@\u2013\u2014]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_symbol_type_from:
                raw_symbol = match_symbol_type_from.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_type_from.group(2).upper()
                entry_text = match_symbol_type_from.group(3)
                signal.entry = parse_entry_price(entry_text, signal.signal_type)
                if not signal.stop_loss:
                    inline_sl = re.search(
                        r"Stop\s+Loss\s*(?:\([^)]*\))?\s*[-:\u2013]?\s*(?:at\s+)?([\d\.]+)",
                        line_clean, re.IGNORECASE
                    )
                    if inline_sl:
                        try:
                            signal.stop_loss = float(inline_sl.group(1))
                        except ValueError:
                            pass
                continue

            # NEW: "SELL SYMBOL NOW price" - action, symbol, NOW keyword, price
            match_type_symbol_now_price = re.match(
                r"^(BUY|SELL)\s+([\w\.\/\-]+)\s+NOW\s*(?:AT|@)?\s*([\d\.]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_type_symbol_now_price:
                signal.signal_type = match_type_symbol_now_price.group(1).upper()
                raw_symbol = match_type_symbol_now_price.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.entry = float(match_type_symbol_now_price.group(3))
                continue

            # NEW: "SELL SYMBOL (@ price)" - entry in parentheses
            match_type_symbol_paren = re.match(
                r"^(BUY|SELL)\s+([\w\.\/\-]+)\s+\(?@?\s*([\d\.]+)\)?$",
                line_clean,
                re.IGNORECASE,
            )
            if match_type_symbol_paren:
                signal.signal_type = match_type_symbol_paren.group(1).upper()
                raw_symbol = match_type_symbol_paren.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.entry = float(match_type_symbol_paren.group(3))
                continue

            # NEW: "Long SYMBOL" / "Short SYMBOL" (optional price)
            match_long_short = re.match(
                r"^(Long|Short)\s+([\w\.\/\-]+)(?:\s+([\d\.\/\-@]+))?$",
                line_clean,
                re.IGNORECASE,
            )
            if match_long_short:
                action = match_long_short.group(1).upper()
                signal.signal_type = "SELL" if action == "SHORT" else "BUY"
                raw_symbol = match_long_short.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                entry_text = match_long_short.group(3)
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 1.5: "Sell Gold @3339-3344" or similar @ formats
            match_symbol_at = re.match(
                r"^(BUY|SELL)\s+([\w\.\/\-]+)\s+@\s*([\d\.\-\s]+)", line_clean, re.IGNORECASE
            )
            if match_symbol_at:
                signal.signal_type = match_symbol_at.group(1).upper()
                raw_symbol = match_symbol_at.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                entry_text = match_symbol_at.group(3).strip()
                signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 1.6: "Gold Sell @ 4231 - 4235" - symbol first, then action, then @ range
            match_symbol_sell_at = re.match(
                r"^([\w\.\/\-]+)\s+(BUY|SELL)\s+@\s*([\d\.\-\s]+)", line_clean, re.IGNORECASE
            )
            if match_symbol_sell_at:
                raw_symbol = match_symbol_sell_at.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_sell_at.group(2).upper()
                entry_text = match_symbol_sell_at.group(3).strip()
                signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 1.7: "Sell gold price @ 4355-4358" - action, symbol, price, @ range
            match_sell_symbol_price_at = re.match(
                r"^(BUY|SELL)\s+([\w\.\/\-]+)\s+price\s+@\s*([\d\.\-\s]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_sell_symbol_price_at:
                signal.signal_type = match_sell_symbol_price_at.group(1).upper()
                raw_symbol = match_sell_symbol_price_at.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                entry_text = match_sell_symbol_price_at.group(3).strip()
                signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # NEW: "High risk SYMBOL BUY/SELL [LIMIT] [price]" - risk-prefixed signals
            match_risk_prefix = re.match(
                r"^(?:very\s+high\s+risk|high\s+risk)\s*[;:,]?\s*([\w\.\/\-]+)\s+(BUY|SELL)(?:\s+(LIMIT))?\s*([\d\/\.\-@]*)",
                line_clean,
                re.IGNORECASE,
            )
            if match_risk_prefix:
                raw_symbol = match_risk_prefix.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                base_type = match_risk_prefix.group(2).upper()
                signal.signal_type = base_type + "LIMIT" if match_risk_prefix.group(3) else base_type
                entry_text = match_risk_prefix.group(4).strip()
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # NEW: "SYMBOL BUY/SELL LIMIT [price]" → BUYLIMIT/SELLLIMIT
            match_symbol_limit = re.match(
                r"^([\w\.\/\-]+)\s+(BUY|SELL)\s+LIMIT\b\s*([\d\/\.\-@]*)",
                line_clean,
                re.IGNORECASE,
            )
            if match_symbol_limit:
                raw_symbol = match_symbol_limit.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_limit.group(2).upper() + "LIMIT"
                entry_text = match_symbol_limit.group(3).strip()
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # NEW: "SELL POSITION XAUUSD" - action + POSITION keyword + symbol
            match_type_position_symbol = re.match(
                r"^(BUY|SELL)\s+POSITION\s+([\w\.\/\-]+)(?:\s+([\d\/\.\-@]+))?",
                line_clean,
                re.IGNORECASE,
            )
            if match_type_position_symbol:
                signal.signal_type = match_type_position_symbol.group(1).upper()
                raw_symbol = match_type_position_symbol.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                entry_text = match_type_position_symbol.group(3)
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 2: "BUY BTCUSD" or "SELL GOLD" or "BUY CHFJPY 180.430" or "GOLD SELL 3334/3337"
            match_type_symbol = re.match(
                r"^(BUY|SELL)\s+([\w\.\/\-]+)\s*([\d\/\.\-@]*)", line_clean, re.IGNORECASE
            )
            if match_type_symbol:
                signal.signal_type = match_type_symbol.group(1).upper()
                raw_symbol = match_type_symbol.group(2).upper()
                # Map symbol if it exists in our mappings, otherwise use as-is
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                # Capture the entry price if present (including range formats)
                entry_text = match_type_symbol.group(3).strip()
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 3: "SYMBOL SIGNAL_TYPE" or "SYMBOL SIGNAL_TYPE entry_range" (e.g., "GOLD SELL 3334/3337", "Gold Sell 3341-3346", "GOLD BUY 4207/04")
            # Note: Exclude colon format which is handled separately
            match_symbol_type_alt = re.match(
                r"^([\w\.\/\-]+)\s+(BUY|SELL)(?!\s*:)\s*(?:@\s*)?([\d\/\.\-]*)",
                line_clean,
                re.IGNORECASE,
            )
            if match_symbol_type_alt:
                raw_symbol = match_symbol_type_alt.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_type_alt.group(2).upper()
                # Capture the entry price if present (including abbreviated range formats like 4207/04)
                entry_text = match_symbol_type_alt.group(3).strip()
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 3.5: "SYMBOL SIGNAL_TYPE : entry_range" (e.g., "Gold buy : 3340.5 -3338")
            match_symbol_type_colon = re.match(
                r"^([\w\.\/\-]+)\s+(BUY|SELL)\s*:\s*([\d\/\.\-@\s]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_symbol_type_colon:
                raw_symbol = match_symbol_type_colon.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_type_colon.group(2).upper()
                # Capture the entry price with colon format
                entry_text = match_symbol_type_colon.group(3).strip()
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 4: "EURUSD BUY" or "XAUUSD BUY" or "XAUUSD BUY 3417" or "XAUUSD / GOLD SELL" (symbol first, then type, optional price)
            match_symbol_type_simple = re.match(
                r"^([\w\.\/\-]+(?:\s*/\s*[\w\.\/\-]+)?)\s+(BUY|SELL)(?:\s+([\d\/\.\-@]+))?",
                line_clean,
                re.IGNORECASE,
            )
            if match_symbol_type_simple:
                raw_symbol = match_symbol_type_simple.group(1).upper()
                # Handle compound symbols like "XAUUSD / GOLD" - use the first one or map appropriately
                if "/" in raw_symbol:
                    symbol_parts = [part.strip() for part in raw_symbol.split("/")]
                    # Use the first symbol, but check if any part maps to a known symbol
                    for part in symbol_parts:
                        if part in symbol_mappings:
                            raw_symbol = symbol_mappings[part]
                            break
                        elif part in [
                            "XAUUSD",
                            "BTCUSD",
                            "EURUSD",
                        ]:  # Known forex symbols take precedence
                            raw_symbol = part
                            break
                    else:
                        # If no mapping found, use the first symbol
                        raw_symbol = symbol_parts[0]

                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_symbol_type_simple.group(2).upper()
                # Check if there's an entry price in the same line
                entry_text = match_symbol_type_simple.group(3)
                if entry_text:
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 5: "BTCUSD | BUY 109500" (symbol | type price)
            match_pipe_format = re.match(
                r"^([\w\.\/\-]+)\s*\|\s*(BUY|SELL)\s+([\d\/\.\-@]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_pipe_format:
                raw_symbol = match_pipe_format.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_pipe_format.group(2).upper()
                entry_text = match_pipe_format.group(3)
                signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # Format 6: "I'M SELLING XAUUSD NOW (3337 - 3340)" - handle NOW with range in parentheses
            match_im_now = re.match(
                r"^I[\'\u2019]?M\s+(SELLING|BUYING)\s+([\w\.\/\-]+)\s+NOW\s*\(([\d\-\s@\.]+)\)",
                line_clean,
                re.IGNORECASE,
            )
            if match_im_now:
                action = match_im_now.group(1).upper()
                signal.signal_type = "SELL" if action == "SELLING" else "BUY"
                raw_symbol = match_im_now.group(2).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                # Extract and parse the range from parentheses as entry price
                range_text = match_im_now.group(3).strip()
                signal.entry = parse_entry_price(range_text, signal.signal_type)
                continue

            # Format 9: NOW signals with ranges like "GOLD Sell Now 4086 - 4090"
            match_now_range = re.match(
                r"^([\w\.\/\-]+)\s+(BUY|SELL)\s+NOW\s+([\d\s\-\.]+)",
                line_clean,
                re.IGNORECASE,
            )
            if match_now_range:
                raw_symbol = match_now_range.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_now_range.group(2).upper()
                range_text = match_now_range.group(3).strip()
                signal.entry = parse_entry_price(range_text, signal.signal_type)
                continue

            # Format 10: "I've entered" format like "I've entered a gold buy at 4778 with SL 4725 and a TP 4800 and TP 4825"
            match_entered = re.search(
                r"I['’]?ve\s+entered\s+a\s+([\w\.\/\-]+)\s+(buy|sell)(?:\s+at\s+([\d\.]+))?\s+with\s+SL\s+([\d\.]+)\s+and\s+(?:a\s+single\s+TP|a\s+TP|TP)\s+([\d\.]+(?:\s+and\s+TP\s+[\d\.]+)*)",
                line_clean,
                re.IGNORECASE,
            )
            if match_entered:
                raw_symbol = match_entered.group(1).upper()
                signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                signal.signal_type = match_entered.group(2).upper()
                
                # Parse entry price (optional - if not present, use 0 for immediate entry)
                entry_text = match_entered.group(3)
                if entry_text:
                    signal.entry = float(entry_text)
                else:
                    signal.entry = 0
                
                # Parse stop loss
                signal.stop_loss = float(match_entered.group(4))
                
                # Parse take profits (can be multiple)
                tp_text = match_entered.group(5)
                tp_values = re.findall(r'([\d\.]+)', tp_text)
                signal.take_profits = [float(tp) for tp in tp_values if tp]
                
                # Sort TPs based on signal type
                if signal.take_profits:
                    if is_buy_signal(signal.signal_type):
                        signal.take_profits.sort()
                    else:
                        signal.take_profits.sort(reverse=True)
                
                continue

            # NEW: Standalone symbol-only line (sets symbol for subsequent BUY/SELL line)
            if not signal.symbol:
                # NEW: "SYMBOL Free Signal!" header (e.g., "📉EUR-USD Free Signal!")
                match_free_signal_header = re.match(
                    r"^([\w\-\.\/]+)\s+Free\s+Signal[!]?$",
                    line_clean,
                    re.IGNORECASE,
                )
                if match_free_signal_header:
                    raw_symbol = match_free_signal_header.group(1).upper().replace("-", "")
                    signal.symbol = symbol_mappings.get(raw_symbol, raw_symbol)
                    continue

                # NEW: Standalone "#SYMBOL" hash-prefixed symbol line (e.g., "#XAUUSD")
                match_hash_standalone = re.match(r"^#([A-Z][A-Z0-9\.]{2,10})$", line_clean)
                if match_hash_standalone:
                    candidate = match_hash_standalone.group(1).upper()
                    signal.symbol = symbol_mappings.get(candidate, candidate)
                    continue

                symbol_only = re.match(r"^([A-Z][A-Z0-9\.\/]{2,10})$", line_clean)
                if symbol_only:
                    candidate = symbol_only.group(1).upper()
                    reserved = {"BUY", "SELL", "NOW", "OPEN", "STOP", "LOSS", "TAKE",
                                "PROFIT", "TARGET", "LONG", "SHORT", "ENTRY", "LEVEL",
                                "PRICE", "DIRECTION", "MORE", "NEW", "TRADE", "IDEA"}
                    if candidate not in reserved:
                        signal.symbol = symbol_mappings.get(candidate, candidate)
                        continue

            # NEW: Standalone "Sell!" / "Buy!" action line (with optional exclamation mark)
            match_action_excl = re.match(r"^(BUY|SELL)[!]?$", line_clean, re.IGNORECASE)
            if match_action_excl:
                signal.signal_type = match_action_excl.group(1).upper()
                continue

        # Entry Price parsing
        if signal.entry is None:
            # Enhanced entry patterns - order matters for specificity
            entry_patterns = [
                r"🔊\s*LEVEL\s*:?\s*([\d\.]+)",  # 🔊LEVEL :2653
                r"Entry\s*(?:Price|Level|Point)?\s*[-\u2013:]\s*\$?\s*([\d\.]+)",  # Entry Price: / Entry - / Entry Level -
                r"Entry\s*:\s*\$?\s*([\d\.]+)",  # Entry : $ 95033
                r"Entered\s+at\s+([\d\.]+)",  # Entered at 4588
                r"Enter\s+([\d\.]+)",  # Enter 4585
                r"Zone\s*:\s*([\d\.]+(?:[\-\/][\d\.]+)?)",  # Zone:4703-4701 or Zone: 4703/4701
                r"^OPEN\s*:\s*([\d\.]+(?:\s*[\-\/]\s*[\d\.]+)?)",  # "OPEN : 4134-4136"
                r"^(?:very\s+high\s+risk|high\s+risk)\s*[;:,]?\s*([\d\.]+(?:\s*[\-\/]\s*[\d\.]+)?)\s*$",  # "High risk 4018-4021.5"
            ]

            entry_found = False
            for entry_pattern in entry_patterns:
                entry_match = re.search(entry_pattern, line, re.IGNORECASE)
                if entry_match:
                    entry_text = entry_match.group(1)
                    lower_line = line.lower()
                    if "limit" in lower_line:
                        if is_buy_signal(signal.signal_type) or "buy" in lower_line:
                            signal.signal_type = "BUYLIMIT"
                        elif is_sell_signal(signal.signal_type) or "sell" in lower_line:
                            signal.signal_type = "SELLLIMIT"
                    signal.entry = parse_entry_price(entry_text, signal.signal_type)
                    entry_found = True
                    break

            if entry_found:
                continue

            # Look for ENTRY keyword with optional colon (support unicode dashes) - LEGACY
            m = re.search(
                r"ENTRY\s*:?\s*(?:at\s+)?([\d\/\.\-@–—\+\s]+)", line_clean, re.IGNORECASE
            )
            if m:
                entry_text = m.group(1)
                signal.entry = parse_entry_price(entry_text, signal.signal_type)
                continue

            # NEW: Check for standalone entry price line (just numbers with optional slash or dash range)
            # This should be a line that looks like an entry price but not TPs
            entry_standalone_pattern = r"^([\d\.]+(?:[/\-\s]+[\d\.]+)?)$"
            entry_match = re.match(entry_standalone_pattern, line_clean.strip())
            if entry_match and signal.signal_type and signal.symbol:
                # Make sure this looks like an entry price and not TPs
                entry_text = entry_match.group(1)
                potential_entry = parse_entry_price(entry_text, signal.signal_type)

                # Simple heuristic: if it's a range (contains / or -), treat as entry
                # or if it's a single reasonable value for the symbol
                if ("/" in entry_text or "-" in entry_text) or (
                    isinstance(potential_entry, (int, float)) and potential_entry > 0
                ):
                    signal.entry = potential_entry
                    continue

        # Take Profits parsing - consolidated and improved
        # Check for various TP patterns in order of specificity
        tp_patterns = [
            r"[🤑💰✅]\s*TP\d*\s*:\s*([\d\.]+(?:/[\d\.]+)*(?:/OPEN)?|open)",  # Emoji TP formats like "💰TP1: 3289.0", "💰TP2: 3331" (with colon), includes /OPEN ignore
            r"[🤑💰✅]\s*TP\d+\s+([\d\.]+(?:/[\d\.]+)*|open)",  # Emoji TP formats like "✅TP1 109700" (without colon)
            r"Take\s+Profit\s+\d+\s*\(TP\d*\)\s*:\s*([\d\.]+)",  # "Take Profit 1 (TP1): 4701"
            r"T\.P\d+\s+([\d\.]+|open)",  # "T.P1 114600", "T.P2 114500" (T.P format)
            r"TP\.(?!\.)\s*([0-9][\d\.]*)",  # NEW: "TP. 5220", "TP. 5222" (single dot format, not double)
            r"Target\s*\d+\s*:\s*\$?\s*([\d\.]+)",  # NEW: "Target1: $ 94800", "Target 1: 1.1795", "Target2: $94300"
            r"TP\s*(\d+)\s*:\s*([\d\.]+|open)",  # "TP 1 : 4604", "TP1: 3289.0", "TP 2 : open" (with colon and number)
            r"TP\s+(\d+)\s+([\d\.]+)",  # "TP 1 4081", "TP 2 4078" (numbered format with space)
            r"TP\d+\s+([\d\.]+|open)",  # "TP1 3420", "TP2 3423" (without colon, with number)
            r"TP\s*:\s*([\d\.]+|open)",  # "TP: 1.1455", "TP: open"
            r"Target\s+Profit\s*:\s*([\d\.]+)",  # "Target Profit : 4081"
            r"(?:Take\s+Profit)\s*:\s*([\d\.]+|open)",  # NEW: "Take Profit: 1.1697"
            r"(?:TAKE\s*PROFIT)\s*\d*\s*(?:at\s+)?([\d\.]+|open)",  # "Take profit 1 at 89500.00", "Take profit 2 at open"
            r"TP\s+([\d\.]+(?:/[\d\.]+)*|open)",  # "TP 3364" or "TP 3332/3334/3336/3338/3340" or "TP open" (without colon)
            r"TP\.{1,2}\s*([\d\.]+)",  # TP.. double-dot
            r"(?:Take|Tp)\s*[-\u2013]\s*([\d\.]+)",  # Take - / Tp - price
            r"(?:Take\s+Profit)\s*[-\u2013]\s*([\d\.]+)",  # Take Profit - price
        ]

        tp_found = False
        for tp_pattern in tp_patterns:
            m = re.search(tp_pattern, line_clean, re.IGNORECASE)
            if m:
                try:
                    # Handle special numbered TP format "TP 1 4081"
                    if tp_pattern == r"TP\s+(\d+)\s+([\d\.]+)":
                        # For numbered format, use the second group (the price)
                        tp_value = float(m.group(2))
                        if tp_value > 0.1:
                            take_profits.append(tp_value)
                        tp_found = True
                    # Handle TP dots format "TP. 5220"
                    elif tp_pattern == r"TP\.(?!\.)\s*([0-9][\d\.]*)":  # single dot format
                        tp_value = float(m.group(1))
                        if tp_value > 0.1:
                            take_profits.append(tp_value)
                        tp_found = True
                    # Handle Target format "Target1: $ 94800"
                    elif tp_pattern == r"Target\s*\d+\s*:\s*\$?\s*([\d\.]+)":
                        tp_value = float(m.group(1))
                        if tp_value > 0.1:
                            take_profits.append(tp_value)
                        tp_found = True
                    # Handle TP with number format "TP 1 : 4604"
                    elif tp_pattern == r"TP\s*(\d+)\s*:\s*([\d\.]+|open)":
                        tp_values_text = m.group(2)
                        if tp_values_text.lower() == "open":
                            take_profits.append("open")
                        else:
                            tp_value = float(tp_values_text)
                            if tp_value > 0.1:
                                take_profits.append(tp_value)
                        tp_found = True
                    else:
                        tp_values_text = m.group(1)
                        # Handle /OPEN suffix - ignore it
                        if tp_values_text.endswith("/OPEN"):
                            tp_values_text = tp_values_text[:-5]  # Remove "/OPEN"
                        
                        if "/" in tp_values_text:
                            # Multiple TP values separated by slashes
                            tp_values = tp_values_text.split("/")
                            for tp_val in tp_values:
                                if tp_val.strip().lower() == "open":
                                    # Store "open" as a special marker
                                    take_profits.append("open")
                                else:
                                    tp_value = float(tp_val.strip())
                                    if (
                                        tp_value > 0.1
                                    ):  # Filter out very small numbers but allow forex values
                                        take_profits.append(tp_value)
                            tp_found = True
                        else:
                            # Single TP value or "open"
                            if tp_values_text.strip().lower() == "open":
                                # Store "open" as a special marker
                                take_profits.append("open")
                            else:
                                tp_value = float(tp_values_text)
                                if (
                                    tp_value > 0.1
                                ):  # Filter out very small numbers but allow forex values
                                    take_profits.append(tp_value)
                            tp_found = True
                    break
                except ValueError:
                    print(
                        f"Warning: Invalid number for TP: {m.group(1) if len(m.groups()) == 1 else m.group(2)}"
                    )

        # NEW: Check for slash-separated TP values OR single numeric TP (e.g., "3332/3330/3328/3325" or "3340")
        if not tp_found:
            # Pattern for line containing only numbers separated by slashes OR single number
            # Prioritize lines with multiple values (likely TPs) over single values (could be entry)
            # Updated to handle spaces around slashes (e.g., "3590/ 3595" or "3590 / 3595")
            slash_tp_pattern = r"^([\d\.]+(?:\s*/\s*[\d\.]+)+)$"  # Must have at least one slash (multiple values), spaces allowed
            slash_match = re.match(slash_tp_pattern, line_clean.strip())
            if slash_match:
                tp_values_text = slash_match.group(1)
                # Split by slash and strip whitespace from each value
                tp_values = [
                    val.strip() for val in tp_values_text.split("/") if val.strip()
                ]

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
                single_tp_pattern = r"^([\d\.]+)$"
                single_match = re.match(single_tp_pattern, line_clean.strip())
                if single_match and signal.signal_type and signal.entry is not None:
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
        if not signal.stop_loss:
            sl_patterns = [
                r"[\u26a0\U0001F534\u274c\U0001F6D1]\s*(?:SL|Stop\s*Loss|STOP\s*LOSS)\s*:?\s*([\d\.]+)",  # Emoji SL
                r"[\U0001F6A8\U0001F534]\s*SL\s*:?\s*([\d\.]+)",  # Emoji before SL
                r"SL\s+at\s+([\d\.]+)",  # SL at 4560
                r"SL\.{1,2}\s*([\d\.]+)",  # SL. or SL..5208
                r"SL[_]([\d\.]+)",  # SL_5140
                r"SL\s*@\s*([\d\.]+)",  # SL @ 5190
                r"SL\s*:\s*\$?\s*([\d\.]+)(?:\s*\([^)]*\))?",  # SL: price
                r"Stop\s+Loss\s*(?:\([^)]*\))?\s*[-:\u2013]?\s*(?:at\s+)?([\d\.]+)",  # Stop Loss variants
                r"(?:Stop|SL|S\.L)\s*[-\u2013]\s*([\d\.]+)",  # Stop - / SL - / Sl -
                r"(?:STOP\s*LOSS|SL|S\.L)\s*:?\s*(?:at\s+)?([\d\.]+)(?:\s*\([^)]*\))?",  # General SL
                r"S\.L\s+([\d\.]+)",  # S.L format
            ]

            for sl_pattern in sl_patterns:
                m = re.search(sl_pattern, line_clean, re.IGNORECASE)
                if m:
                    try:
                        signal.stop_loss = float(m.group(1))
                        break
                    except ValueError:
                        print(f"Warning: Invalid number for Stop Loss: {m.group(1)}")

    # Sort take profits and add to signal
    if take_profits:
        # Check if we have only "open" TP values and no numeric TPs
        numeric_tps = [tp for tp in take_profits if tp != "open"]
        open_tps = [tp for tp in take_profits if tp == "open"]

        if len(numeric_tps) == 0 and len(open_tps) > 0:
            # Special case: Only "open" TPs, no numeric TPs
            # Set TP to 0 to indicate no TP should be set (order opens without TP)
            signal.take_profits = [0]
        else:
            # Process "open" TP values - calculate them based on previous TP and signal type
            processed_tps = []
            for i, tp in enumerate(take_profits):
                if tp == "open":
                    # Calculate "open" TP based on the previous TP (if exists) or entry price
                    if i > 0 and isinstance(processed_tps[i - 1], (int, float)):
                        # Case 1: Previous TP exists - use prev_tp ± 4
                        prev_tp = processed_tps[i - 1]
                        if is_buy_signal(signal.signal_type):
                            # For BUY/BUYLIMIT: open TP should be higher (prev_tp + 4)
                            calculated_tp = prev_tp + 4
                        else:
                            # For SELL: open TP should be lower (prev_tp - 4)
                            calculated_tp = prev_tp - 4
                        processed_tps.append(calculated_tp)
                    elif signal.entry is not None and signal.entry != 0:
                        # Case 2: No previous TP but have entry - use entry ± 6
                        entry_price = signal.entry
                        if is_buy_signal(signal.signal_type):
                            # For BUY/BUYLIMIT: open TP should be higher (entry + 6)
                            calculated_tp = entry_price + 6
                        else:
                            # For SELL: open TP should be lower (entry - 6)
                            calculated_tp = entry_price - 6
                        processed_tps.append(calculated_tp)
                    else:
                        print(
                            "Warning: Cannot calculate 'open' TP - no previous TP or entry found"
                        )
                        # Skip this TP
                        continue
                else:
                    processed_tps.append(tp)

            take_profits = processed_tps

            # Sort TPs based on signal type
            if is_buy_signal(signal.signal_type):
                # For BUY/BUYLIMIT signals, TPs should be in ascending order (higher prices)
                take_profits.sort()
            else:
                # For SELL signals, TPs should be in descending order (lower prices)
                take_profits.sort(reverse=True)
            signal.take_profits = take_profits

    # NEW: Simple check for immediate entry - set entry to 0 if NOW keyword found BUT no entry was set
    if "NOW" in text.upper() and signal.entry is None:
        logger.info(
            "No entry price parsed, 'now' keyword found - set to immediate entry"
        )
        signal.entry = 0

    # Final Validation: Check if all essential parts were found
    signal.fill_symbol_if_missing()
    if signal.is_valid():
        # Debug: Show parsed signal info
        if signal.channel_name:
            print(
                f"Debug: Successfully parsed signal from channel '{signal.channel_name}': {signal.signal_type} {signal.symbol}"
            )

        return signal
    else:
        signal.debug_missing_parts(text)
        return None


def format_mt4_comment(
    group_id: int, channel_name: str, stop_loss: float, digits: int = 5
) -> str:
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
    sl_str = f"{stop_loss:.{min(digits, 4)}f}".rstrip("0").rstrip(".")

    # Build comment: xxxx|ABCD|value (without GID: and SL: prefixes)
    comment = f"{group_id}|{clean_channel}|{sl_str}"

    # If comment exceeds 31 chars, reduce SL precision
    if len(comment) > 31:
        sl_str = f"{stop_loss:.2f}".rstrip("0").rstrip(".")
        comment = f"{group_id}|{clean_channel}|{sl_str}"

    # If still too long, reduce to 1 decimal place
    if len(comment) > 31:
        sl_str = f"{stop_loss:.1f}".rstrip("0").rstrip(".")
        comment = f"{group_id}|{clean_channel}|{sl_str}"

    # Final truncation if still too long (should not happen with proper formatting)
    if len(comment) > 31:
        comment = comment[:31]

    return comment
