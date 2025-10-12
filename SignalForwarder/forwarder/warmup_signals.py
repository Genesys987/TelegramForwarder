from dotenv import dotenv_values
from config import WARMUP_SIGNAL_CHANNEL
from signal_data import SignalData

import re

def is_warmup_message(text: str):
    """
    Check if the message matches any ready message pattern for warmup signals.

    Args:
        text: Message text to check

    Returns:
        tuple: (is_ready: bool, signal_type: str or None, current_price: float or None)
    """

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
        SignalData: Generated warmup signal data with zeros for EA calculation
    """

    signal_data = SignalData(
        signal_type=signal_type,
        symbol="XAUUSD",  # Default to XAUUSD for GOLD signals
        entry=0,  # EA will use current market price
        take_profits=[0, 0],  # EA will calculate based on its logic
        stop_loss=0,  # EA will calculate based on its logic
        channel_name=WARMUP_SIGNAL_CHANNEL,  # Use configured channel name
        is_warmup=True  # Flag to identify warmup signals
    )

    return signal_data
