import logging
from config import WARMUP_SIGNAL_CHANNEL
from signal_data import SignalData, SignalType

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

    Supported symbols: XAUUSD, GOLD, NAS100, NQ

    Args:
        text: Message text to check

    Returns:
        tuple: (is_ready: bool, signal_type: str or None, symbol: str or None)
    """
    stripped = text.strip()

    # Multi-line messages are never warmup signals
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

    logger.info("Signal is not a warmup message.")
    return False, None, None


def generate_warmup_signal(signal_type: SignalType | None, symbol: str | None = None):
    """
    Generate a warmup signal with zero values - EA calculates actual TP/SL.

    Args:
        signal_type: "BUY" or "SELL"
        symbol: Trading symbol (e.g. "XAUUSD", "NAS100"); defaults to "XAUUSD"

    Returns:
        SignalData: Generated warmup signal data with zeros for EA calculation
    """

    return SignalData(
        signal_type=signal_type,
        symbol=symbol or "XAUUSD",
        entry=0,  # EA will use current market price
        take_profits=[0, 0, 0, 0],  # EA will calculate based on its logic
        stop_loss=0,  # EA will calculate based on its logic
        channel_name=WARMUP_SIGNAL_CHANNEL,  # Use configured channel name
        is_warmup=True,  # Flag to identify warmup signals
    )
