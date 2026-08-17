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
            is_ready, signal_type, symbol = is_warmup_message(text)
            self.assertTrue(is_ready, f"'{text}' should be recognised as warmup")
            self.assertEqual(signal_type, "BUY", f"'{text}' should be BUY")
            self.assertEqual(symbol, "XAUUSD", f"'{text}' should map to XAUUSD")

    def test_sell_pattern(self):
        """Test GOLD SELL <price> warmup pattern."""
        sell_cases = [
            "GOLD SELL 4509",
            "gold sell 4509",
            "Gold Sell 4509",
            "GOLD SELL 3850.25",
        ]
        for text in sell_cases:
            is_ready, signal_type, symbol = is_warmup_message(text)
            self.assertTrue(is_ready, f"'{text}' should be recognised as warmup")
            self.assertEqual(signal_type, "SELL", f"'{text}' should be SELL")
            self.assertEqual(symbol, "XAUUSD", f"'{text}' should map to XAUUSD")

    def test_nas100_warmup_patterns(self):
        """Test new NAS100 warmup signal patterns."""
        cases = [
            ("Nas100 sell 29655", "SELL", "NAS100"),
            ("Nas100 sell", "SELL", "NAS100"),
            ("nas100 buy 29040", "BUY", "NAS100"),
            ("NAS100 SELL 29655", "SELL", "NAS100"),
            ("NQ sell 29655", "SELL", "NAS100"),
        ]
        for text, exp_type, exp_symbol in cases:
            is_ready, signal_type, symbol = is_warmup_message(text)
            self.assertTrue(is_ready, f"'{text}' should be recognised as warmup")
            self.assertEqual(signal_type, exp_type, f"'{text}' type mismatch")
            self.assertEqual(symbol, exp_symbol, f"'{text}' symbol mismatch")

    def test_xauusd_warmup_patterns(self):
        """Test new XAUUSD warmup patterns (without GOLD keyword)."""
        cases = [
            ("Xauusd sell 4132", "SELL", "XAUUSD"),
            ("XAUUSD BUY 4132", "BUY", "XAUUSD"),
        ]
        for text, exp_type, exp_symbol in cases:
            is_ready, signal_type, symbol = is_warmup_message(text)
            self.assertTrue(is_ready, f"'{text}' should be recognised as warmup")
            self.assertEqual(signal_type, exp_type)
            self.assertEqual(symbol, exp_symbol)

    def test_warmup_with_risk_prefix(self):
        """Test warmup patterns with high risk prefix."""
        cases = [
            ("High risk nas100 buy 29040", "BUY", "NAS100"),
            ("high risk xauusd sell 4132", "SELL", "XAUUSD"),
            ("Very high risk gold sell 4132", "SELL", "XAUUSD"),
        ]
        for text, exp_type, exp_symbol in cases:
            is_ready, signal_type, symbol = is_warmup_message(text)
            self.assertTrue(is_ready, f"'{text}' should be recognised as warmup")
            self.assertEqual(signal_type, exp_type)
            self.assertEqual(symbol, exp_symbol)

    def test_warmup_with_trailing_noise(self):
        """Test warmup patterns with trailing punctuation or noise."""
        cases = [
            ("Nas100 sell!!!", "SELL", "NAS100"),
            ("Xauusd sell, high risk again:", "SELL", "XAUUSD"),
            ("GOLD BUY 4509 ", "BUY", "XAUUSD"),
        ]
        for text, exp_type, exp_symbol in cases:
            is_ready, signal_type, symbol = is_warmup_message(text)
            self.assertTrue(is_ready, f"'{text}' should be recognised as warmup")
            self.assertEqual(signal_type, exp_type)
            self.assertEqual(symbol, exp_symbol)

    def test_non_warmup_messages(self):
        """Test that non-warmup messages are not recognised."""
        non_warmup = [
            # multi-line messages are never warmup
            "GOLD BUY 4509\nTP 4520\nSL 4498",
            "Nas100 sell 29655\nSl 29705\nTp-s:\n29580",
            "XAUUSD SELL\nHigh risk 4018-4021.5\nTps:\n4011",
            # no symbol+action match
            "I'm buying now",
            "Let's scalping buy gold slowly",
            "Buy gold now 4000-4010",
            "Random message",
            "TP1: 4520",
            "SL: 4498",
        ]
        for text in non_warmup:
            is_ready, signal_type, symbol = is_warmup_message(text)
            self.assertFalse(is_ready, f"'{text}' should NOT be recognised as warmup")
            self.assertIsNone(signal_type)

    def test_generate_warmup_buy_signal(self):
        """Test generation of BUY warmup signal."""
        signal = generate_warmup_signal("BUY")
        self.assertIsInstance(signal, SignalData)
        self.assertEqual(signal.signal_type, "BUY")
        self.assertEqual(signal.symbol, "XAUUSD")
        self.assertEqual(signal.entry, 0)
        self.assertEqual(signal.take_profits, [0, 0, 0, 0])
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
        self.assertEqual(signal.take_profits, [0, 0, 0, 0])
        self.assertEqual(signal.stop_loss, 0)
        self.assertEqual(signal.channel_name, WARMUP_SIGNAL_CHANNEL)
        self.assertTrue(signal.is_warmup)

    def test_warmup_signal_validation(self):
        """Test that generated warmup signals pass is_valid()."""
        self.assertTrue(generate_warmup_signal("BUY").is_valid())
        self.assertTrue(generate_warmup_signal("SELL").is_valid())

    def test_full_warmup_workflow_buy(self):
        """Test complete workflow: recognition → signal generation (BUY)."""
        is_ready, signal_type, symbol = is_warmup_message("GOLD BUY 4509")
        self.assertTrue(is_ready)
        self.assertEqual(signal_type, "BUY")
        self.assertEqual(symbol, "XAUUSD")
        signal = generate_warmup_signal(signal_type, symbol)
        self.assertEqual(signal.signal_type, "BUY")
        self.assertTrue(signal.is_warmup)
        self.assertTrue(signal.is_valid())

    def test_full_warmup_workflow_sell(self):
        """Test complete workflow: recognition → signal generation (SELL)."""
        is_ready, signal_type, symbol = is_warmup_message("GOLD SELL 3850")
        self.assertTrue(is_ready)
        self.assertEqual(signal_type, "SELL")
        self.assertEqual(symbol, "XAUUSD")
        signal = generate_warmup_signal(signal_type, symbol)
        self.assertEqual(signal.signal_type, "SELL")
        self.assertTrue(signal.is_warmup)
        self.assertTrue(signal.is_valid())

    def test_full_warmup_workflow_nas100(self):
        """Test complete workflow for NAS100 warmup."""
        is_ready, signal_type, symbol = is_warmup_message("Nas100 sell 29655")
        self.assertTrue(is_ready)
        self.assertEqual(signal_type, "SELL")
        self.assertEqual(symbol, "NAS100")
        signal = generate_warmup_signal(signal_type, symbol)
        self.assertEqual(signal.signal_type, "SELL")
        self.assertEqual(signal.symbol, "NAS100")
        self.assertTrue(signal.is_warmup)
        self.assertTrue(signal.is_valid())

    def test_open_order_warmup_detection(self):
        """Multi-line 'Open order: ... sl: 0 tp: 0' must be detected as warmup."""
        cases = [
            (
                "4️⃣1️⃣8️⃣ Open order: SELL NZDCHF at 0.47647 sl: 0.00000 tp: 0.00000\n"
                "(Risk 1% of account balance based on SL of 50 pips)",
                "SELL", "NZDCHF",
            ),
            (
                "Open order: BUY XAUUSD at 3400.00 sl: 0.00000 tp: 0.00000\n"
                "(Risk 2%)",
                "BUY", "XAUUSD",
            ),
            (
                "Open order: SELL GOLD at 3400.00 sl: 0 tp: 0",
                "SELL", "XAUUSD",  # GOLD → XAUUSD via mapping
            ),
        ]
        for text, exp_type, exp_symbol in cases:
            is_ready, signal_type, symbol = is_warmup_message(text)
            self.assertTrue(is_ready, f"Should detect warmup: {text!r}")
            self.assertEqual(signal_type, exp_type)
            self.assertEqual(symbol, exp_symbol)

    def test_open_order_non_warmup_not_detected(self):
        """'Open order:' with real SL/TP must NOT be detected as warmup."""
        text = "Open order: SELL NZDCHF at 0.47647 sl: 0.48147 tp: 0.46147"
        is_ready, _, _ = is_warmup_message(text)
        self.assertFalse(is_ready)

    def test_generate_warmup_single_tp(self):
        """generate_warmup_signal with tp_levels=1 must produce a single [0] TP."""
        signal = generate_warmup_signal("SELL", "NZDCHF", tp_levels=1)
        self.assertEqual(signal.take_profits, [0])
        self.assertTrue(signal.is_valid())
        self.assertTrue(signal.is_warmup)

    def test_generate_warmup_default_tp_levels(self):
        """Default generate_warmup_signal must still produce [0,0,0,0]."""
        signal = generate_warmup_signal("BUY", "XAUUSD")
        self.assertEqual(signal.take_profits, [0, 0, 0, 0])

    def test_open_order_warmup_workflow(self):
        """Full workflow: Open order warmup detected → single-TP warmup generated."""
        text = (
            "4️⃣1️⃣8️⃣ Open order: SELL NZDCHF at 0.47647 sl: 0.00000 tp: 0.00000\n"
            "(Risk 1% of account balance based on SL of 50 pips)"
        )
        is_ready, signal_type, symbol = is_warmup_message(text)
        self.assertTrue(is_ready)
        signal = generate_warmup_signal(signal_type, symbol, tp_levels=1)
        self.assertEqual(signal.signal_type, "SELL")
        self.assertEqual(signal.symbol, "NZDCHF")
        self.assertEqual(signal.take_profits, [0])
        self.assertTrue(signal.is_warmup)
        self.assertTrue(signal.is_valid())


if __name__ == "__main__":
    unittest.main(verbosity=2)
