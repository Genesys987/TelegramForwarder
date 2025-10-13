from typing import List, Optional

class SignalData:
    def __init__(
        self,
        signal_type: Optional[str] = None,
        symbol: Optional[str] = None,
        entry: Optional[float] = None,
        take_profits: Optional[List[float]] = None,
        stop_loss: Optional[float] = None,
        channel_name: Optional[str] = None,
        is_warmup: bool = False,
        timestamp_utc: Optional[int] = None,
        group_id: Optional[int] = None,
        original_channel: Optional[str] = None,
        is_modify: bool = False
    ):
        self.signal_type = signal_type
        self.symbol = symbol
        self.entry = entry
        self.take_profits = take_profits if take_profits is not None else []
        self.stop_loss = stop_loss
        self.channel_name = channel_name
        self.is_warmup = is_warmup
        self.timestamp_utc = timestamp_utc
        self.group_id = group_id
        self.original_channel = original_channel
        self.is_modify = is_modify

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

    def is_valid(self) -> bool:
        return (
            bool(self.signal_type) and
            bool(self.symbol) and
            self.entry is not None and
            self.take_profits is not None and
            isinstance(self.take_profits, list) and
            len(self.take_profits) > 0 and
            self.stop_loss is not None
        )

    def debug_missing_parts(self, messageText: str):
        # Log which parts are missing if debugging is needed
        missing = []
        if not self.signal_type:
            missing.append("signal_type")
        if not self.symbol:
            missing.append("symbol")
        if not self.entry:
            missing.append("entry")
        if not self.take_profits or len(self.take_profits) == 0:
            missing.append("take_profits")
        if not self.stop_loss:
            missing.append("stop_loss")
            
        print(f"Debug: Signal parsing incomplete. Missing or invalid parts: {missing}. Original text: {messageText[:1000]}...")
        return None
