import unittest
import sys
import os

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from warmup_signals import is_warmup_message, generate_warmup_signal
from signal_data import SignalData
from config import WARMUP_SIGNAL_CHANNEL


class TestWarmupSignalFormats(unittest.TestCase):
    """Test warmup signal pattern: GOLD BUY/SELL <price> (standalone, no TP/SL)."""

    def test_buy_pattern(self):
        """Test GOLD BUY <price> warmup pattern."""
        buy_cases = [
            "GOLD BUY 4509",
            "gold buy 4509",
            "Gold Buy 4509",
            "GOLD BUY 4509.5",
            "GOLD  BUY  4509",   # extra spaces
            "GOLD BUY 4509 ",    # trailing space
        ]
        for text in buy_cases:
            is_ready, signal_type, price = is_warmup_message(text)
            self.assertTrue(is_ready, f"'{text}' should be recognised as warmup")
            self.assertEqual(signal_type, "BUY", f"'{text}' should be BUY")
            self.assertIsNone(price)

    def test_sell_pattern(self):
        """Test GOLD SELL <price> warmup pattern."""
        sell_cases = [
            "GOLD SELL 4509",
            "gold sell 4509",
            "Gold Sell 4509",
            "GOLD SELL 3850.25",
        ]
        for text in sell_cases:
            is_ready, signal_type, price = is_warmup_message(text)
            self.assertTrue(is_ready, f"'{text}' should be recognised as warmup")
            self.assertEqual(signal_type, "SELL", f"'{text}' should be SELL")
            self.assertIsNone(price)

    def test_non_warmup_messages(self):
        """Test that non-warmup messages are not recognised."""
        non_warmup = [
            # old-style ready phrases (no longer valid)
            "Gold buy now",
            "I'm buying now",
            "GOLD SELL READY",
            "Let's scalping buy gold slowly",
            # signal with TP/SL (multi-line)
            "GOLD BUY 4509\nTP 4520\nSL 4498",
            # range entry
            "GOLD BUY 4509/4506",
            "Buy gold now 4000-4010",
            # extra words
            "GOLD BUY 4509 MORE BUY 4506",
            "GOLD BUY NOW 4509",
            # unrelated
            "Random message",
            "TP1: 4520",
            "SL: 4498",
        ]
        for text in non_warmup:
            is_ready, signal_type, price = is_warmup_message(text)
            self.assertFalse(is_ready, f"'{text}' should NOT be recognised as warmup")
            self.assertIsNone(signal_type)

    def test_generate_warmup_buy_signal(self):
        """Test generation of BUY warmup signal."""
        signal = generate_warmup_signal("BUY")
        self.assertIsInstance(signal, SignalData)
        self.assertEqual(signal.signal_type, "BUY")
        self.assertEqual(signal.symbol, "XAUUSD")
        self.assertEqual(signal.entry, 0)
        self.assertEqual(signal.take_profits, [0, 0])
        self.assertEqual(signal.stop_loss, 0)
        self.assertEqual(signal.channel_name, WARMUP_SIGNAL_CHANNEL)
        self.assertTrue(signal.is_warmup)

    def test_generate_warmup_sell_signal(self):
        """Test generation of SELL warmup signal."""
        signal = generate_warmup_signal("SELL")
        self.assertIsInstance(signal, SignalData)
        self.assertEqual(signal.signal_type, "SELL")
        self.assertEqual(signal.symbol, "XAUUSD")
        self.assertEqual(signal.entry, 0)
        self.assertEqual(signal.take_profits, [0, 0])
        self.assertEqual(signal.stop_loss, 0)
        self.assertEqual(signal.channel_name, WARMUP_SIGNAL_CHANNEL)
        self.assertTrue(signal.is_warmup)

    def test_warmup_signal_validation(self):
        """Test that generated warmup signals pass is_valid()."""
        self.assertTrue(generate_warmup_signal("BUY").is_valid())
        self.assertTrue(generate_warmup_signal("SELL").is_valid())

    def test_full_warmup_workflow_buy(self):
        """Test complete workflow: recognition → signal generation (BUY)."""
        is_ready, signal_type, price = is_warmup_message("GOLD BUY 4509")
        self.assertTrue(is_ready)
        self.assertEqual(signal_type, "BUY")
        self.assertIsNone(price)
        signal = generate_warmup_signal(signal_type)
        self.assertEqual(signal.signal_type, "BUY")
        self.assertTrue(signal.is_warmup)
        self.assertTrue(signal.is_valid())

    def test_full_warmup_workflow_sell(self):
        """Test complete workflow: recognition → signal generation (SELL)."""
        is_ready, signal_type, price = is_warmup_message("GOLD SELL 3850")
        self.assertTrue(is_ready)
        self.assertEqual(signal_type, "SELL")
        self.assertIsNone(price)
        signal = generate_warmup_signal(signal_type)
        self.assertEqual(signal.signal_type, "SELL")
        self.assertTrue(signal.is_warmup)
        self.assertTrue(signal.is_valid())


if __name__ == "__main__":
    unittest.main(verbosity=2)
