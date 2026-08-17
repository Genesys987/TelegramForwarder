import logging
from config import WARMUP_SIGNAL_CHANNEL
from signal_data import SignalData, SignalType
from signal_parser import clean_invisible_chars

import re

logger = logging.getLogger(__name__)


_WARMUP_SYMBOL_MAP = {
    "GOLD": "XAUUSD",
    "NQ": "NAS100",
}


def is_warmup_message(text: str) -> tuple[bool, SignalType | None, str | None]:
    """
    Check if the message is a standalone warmup signal (no TP/SL) that instructs
    the EA to open a position; the real TP/SL arrives as a follow-up message.

    A warmup message is always a single line (no newlines) that matches:
      [High risk] SYMBOL BUY/SELL [price] [optional trailing]
    OR a multi-line "Open order: ... sl: 0.00000 tp: 0.00000" message.

    Supported symbols: XAUUSD, GOLD, NAS100, NQ

    Args:
        text: Message text to check

    Returns:
        tuple: (is_ready: bool, signal_type: str or None, symbol: str or None)
    """
    text = clean_invisible_chars(text)
    stripped = text.strip()

    # Check for multi-line "Open order: ACTION SYMBOL at PRICE sl: 0.00000 tp: 0.00000"
    m_open = re.search(
        r"Open\s+order\s*:\s*(BUY|SELL)\s+([\w\.]+)\s+at\s+[\d\.]+\s+sl\s*:\s*([\d\.]+)\s+tp\s*:\s*([\d\.]+)",
        stripped, re.IGNORECASE,
    )
    if m_open:
        sl_v = float(m_open.group(3))
        tp_v = float(m_open.group(4))
        if sl_v == 0.0 and tp_v == 0.0:
            raw_symbol = m_open.group(2).upper()
            symbol = _WARMUP_SYMBOL_MAP.get(raw_symbol, raw_symbol)
            return True, m_open.group(1).upper(), symbol

    # Multi-line messages are never warmup signals (single-line patterns below)
    if "\n" in stripped:
        return False, None, None

    # Match: [High risk] SYMBOL BUY/SELL [anything on same line]
    m = re.match(
        r"^(?:(?:very\s+)?high\s+risk\s+)?(xauusd|gold|nas100|nq)\s+(buy|sell)\b",
        stripped,
        re.IGNORECASE,
    )
    if m:
        raw_symbol = m.group(1).upper()
        signal_type = m.group(2).upper()
        symbol = _WARMUP_SYMBOL_MAP.get(raw_symbol, raw_symbol)
        return True, signal_type, symbol

    # Also handle action-first format: "SELL GOLD NOW🚨"
    m2 = re.match(
        r"^(buy|sell)\s+(xauusd|gold|nas100|nq)\b",
        stripped,
        re.IGNORECASE,
    )
    if m2:
        # Reject if trailing text contains a numeric range like "4000-4010" or "4000/4010"
        # — that signals a regular trade entry, not a warmup placeholder
        trailing = stripped[m2.end():].strip()
        if re.search(r"\d+[-\/]\d+", trailing):
            logger.info("Signal is not a warmup message.")
            return False, None, None
        signal_type = m2.group(1).upper()
        raw_symbol = m2.group(2).upper()
        symbol = _WARMUP_SYMBOL_MAP.get(raw_symbol, raw_symbol)
        return True, signal_type, symbol

    logger.info("Signal is not a warmup message.")
    return False, None, None


def generate_warmup_signal(
    signal_type: SignalType | None,
    symbol: str | None = None,
    tp_levels: int = 4,
):
    """
    Generate a warmup signal with zero values - EA calculates actual TP/SL.

    Args:
        signal_type: "BUY" or "SELL"
        symbol: Trading symbol (e.g. "XAUUSD", "NAS100"); defaults to "XAUUSD"
        tp_levels: Number of zero TP slots to include (default 4, use 1 for Open-order format)

    Returns:
        SignalData: Generated warmup signal data with zeros for EA calculation
    """

    return SignalData(
        signal_type=signal_type,
        symbol=symbol or "XAUUSD",
        entry=0,  # EA will use current market price
        take_profits=[0] * tp_levels,  # EA will calculate based on its logic
        stop_loss=0,  # EA will calculate based on its logic
        channel_name=WARMUP_SIGNAL_CHANNEL,  # Use configured channel name
        is_warmup=True,  # Flag to identify warmup signals
    )
