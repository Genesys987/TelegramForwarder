import logging
from config import WARMUP_SIGNAL_CHANNEL
from signal_data import SignalData, SignalType

import re

logger = logging.getLogger(__name__)


def is_warmup_message(text: str) -> tuple[bool, SignalType | None, float | None]:
    """
    Check if the message matches the warmup signal pattern: GOLD BUY/SELL <price>
    This is a standalone entry-only message (no TP/SL) that signals the EA to
    open a position; the real TP/SL will arrive as a reply to this message.

    Args:
        text: Message text to check

    Returns:
        tuple: (is_ready: bool, signal_type: str or None, current_price: float or None)
    """
    m = re.match(r"^GOLD\s+(BUY|SELL)\s+[\d.]+\s*$", text.strip(), re.IGNORECASE)
    if m:
        signal_type = m.group(1).upper()
        return True, signal_type, None

    logger.info("Signal is not a warmup message.")
    return False, None, None


def generate_warmup_signal(signal_type: SignalType | None):
    """
    Generate a warmup signal with zero values - EA calculates actual TP/SL.

    Args:
        signal_type: "BUY" or "SELL"

    Returns:
        SignalData: Generated warmup signal data with zeros for EA calculation
    """

    return SignalData(
        signal_type=signal_type,
        symbol="XAUUSD",  # Default to XAUUSD for GOLD signals
        entry=0,  # EA will use current market price
        take_profits=[0, 0, 0, 0],  # EA will calculate based on its logic
        stop_loss=0,  # EA will calculate based on its logic
        channel_name=WARMUP_SIGNAL_CHANNEL,  # Use configured channel name
        is_warmup=True,  # Flag to identify warmup signals
    )
