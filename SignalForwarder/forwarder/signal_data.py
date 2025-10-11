from typing import List, Optional

class SignalData:
    def __init__(
        self,
        signal_type: str,
        symbol: str,
        entry: float,
        take_profits: List[float],
        stop_loss: float,
        channel_name: str,
        is_warmup: bool = False
    ):
        self.signal_type = signal_type
        self.symbol = symbol
        self.entry = entry
        self.take_profits = take_profits
        self.stop_loss = stop_loss
        self.channel_name = channel_name
        self.is_warmup = is_warmup

    def to_dict(self):
        return {
            "signal_type": self.signal_type,
            "symbol": self.symbol,
            "entry": self.entry,
            "take_profits": self.take_profits,
            "stop_loss": self.stop_loss,
            "channel_name": self.channel_name,
            "is_warmup": self.is_warmup
        }
