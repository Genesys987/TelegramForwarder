#!/usr/bin/env python3
"""
Test edge cases and potential issues in the signal processing logic
"""

import unittest
import os
import tempfile
import shutil
import config
from signal_parser import parse_signal, clean_channel_name, format_mt4_comment
from queue_manager import add_signal_to_queue
from signal_data import SignalData


class TestEdgeCases(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self._orig_queue_paths = list(config.MT4_QUEUE_FILE_PATHS)
        self._orig_signal_paths = list(config.MT4_SIGNAL_FILE_PATHS)
        config.MT4_QUEUE_FILE_PATHS.clear()
        config.MT4_QUEUE_FILE_PATHS.append(os.path.join(self.test_dir, "test_queue.txt"))
        config.MT4_SIGNAL_FILE_PATHS.clear()
        config.MT4_SIGNAL_FILE_PATHS.append(os.path.join(self.test_dir, "test_signals.txt"))

    def tearDown(self):
        config.MT4_QUEUE_FILE_PATHS.clear()
        config.MT4_QUEUE_FILE_PATHS.extend(self._orig_queue_paths)
        config.MT4_SIGNAL_FILE_PATHS.clear()
        config.MT4_SIGNAL_FILE_PATHS.extend(self._orig_signal_paths)
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_empty_signal_text(self):
        """Test parsing empty signal text"""
        result = parse_signal("")
        self.assertIsNone(result)

        result = parse_signal("   ")
        self.assertIsNone(result)

        result = parse_signal("\n\n\n")
        self.assertIsNone(result)

    def test_malformed_signal_text(self):
        """Test parsing malformed signal text"""
        malformed_signals = [
            "BUY",  # Missing symbol
            "SELL EURUSD",  # Missing entry price
            "RANDOM TEXT",  # No signal type
            "BUY EURUSD ENTRY",  # No entry price value
            "BUY EURUSD ENTRY abc",  # Invalid entry price
            "BUY EURUSD ENTRY 1.1234",  # Missing TP and SL
        ]

        for signal in malformed_signals:
            with self.subTest(signal=signal):
                result = parse_signal(signal)
                self.assertIsNone(
                    result, f"Should return None for malformed signal: {signal}"
                )

    def test_very_long_channel_name(self):
        """Test channel name cleaning with very long names"""
        long_names = [
            "This_is_a_very_long_channel_name_that_should_be_truncated",
            "🔥💎VIP_PREMIUM_SIGNALS_CHANNEL_WITH_EMOJIS💎🔥",
            "CHANNEL-WITH-LOTS-OF-SPECIAL-CHARACTERS!@#$%^&*()",
            "123456789012345678901234567890",  # 30 characters
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",  # 26 characters
        ]

        for name in long_names:
            with self.subTest(name=name):
                cleaned = clean_channel_name(name)
                self.assertLessEqual(
                    len(cleaned), 4, f"Channel name should be max 4 chars: {cleaned}"
                )
                self.assertGreater(
                    len(cleaned), 0, f"Channel name should not be empty: {cleaned}"
                )
                # Should contain only alphanumeric characters
                self.assertTrue(
                    cleaned.isalnum(), f"Channel name should be alphanumeric: {cleaned}"
                )

    def test_extreme_tp_counts(self):
        """Test signals with extreme number of TP levels"""
        # Signal with 1 TP (minimum)
        signal_1_tp = "BUY EURUSD\nENTRY 1.1234\nTP 1.1250\nSL 1.1200".replace(
            "\\n", "\n"
        )
        result = parse_signal(signal_1_tp)
        self.assertIsNotNone(result)
        self.assertEqual(len(result.take_profits), 1)

        # Signal with many TPs (stress test)
        tp_levels = [f"1.{1250 + i}" for i in range(50)]  # 50 TP levels
        signal_many_tp = (
            f"BUY EURUSD\nENTRY 1.1234\nTP {' '.join(tp_levels)}\nSL 1.1200".replace(
                "\\n", "\n"
            )
        )
        result = parse_signal(signal_many_tp)
        if result:  # Parser might handle this or might not
            self.assertGreater(len(result.take_profits), 0)

    def test_duplicate_tp_levels(self):
        """Test signals with duplicate TP levels"""
        signal_duplicate = "BUY EURUSD\\nENTRY 1.1234\\nTP1 1.1250\\nTP2 1.1250\\nTP3 1.1250\\nSL 1.1200"
        result = parse_signal(signal_duplicate)
        if result:
            # Should still parse but might have identical TP levels
            self.assertEqual(len(result.take_profits), 3)

    def test_invalid_tp_order(self):
        """Test signals with TP levels in wrong order"""
        # For BUY orders, TP should be ascending
        signal_wrong_order = "BUY EURUSD\\nENTRY 1.1234\\nTP1 1.1300\\nTP2 1.1250\\nTP3 1.1200\\nSL 1.1200"
        result = parse_signal(signal_wrong_order)
        if result:
            # Parser might not validate order, but this would be problematic in MT4
            tps = result["take_profits"]
            self.assertEqual(len(tps), 3)

    def test_sl_between_entry_and_tp(self):
        """Test signals where SL is between entry and TP (invalid)"""
        signal_invalid_sl = "BUY EURUSD\\nENTRY 1.1234\\nTP 1.1250\\nSL 1.1240"  # SL higher than entry for BUY
        result = parse_signal(signal_invalid_sl)
        if result:
            # Parser might not validate this, but it would be problematic
            self.assertLess(
                result["stop_loss"], result["entry"], "SL should be below entry for BUY"
            )

    def test_mt4_comment_format_edge_cases(self):
        """Test MT4 comment formatting with edge cases"""
        # Test with very high GID
        comment = format_mt4_comment(999999999, "TEST", 1.23456, 5)
        self.assertLessEqual(len(comment), 31, "Comment should be <= 31 characters")

        # Test with very long SL value
        comment = format_mt4_comment(1234, "TEST", 123456.789012345, 5)
        self.assertLessEqual(len(comment), 31, "Comment should be <= 31 characters")

        # Test with different digit precisions
        for digits in [0, 1, 2, 3, 4, 5, 6]:
            comment = format_mt4_comment(1234, "TEST", 1.23456, digits)
            self.assertLessEqual(
                len(comment),
                31,
                f"Comment should be <= 31 characters for {digits} digits",
            )

    def validate_signal_data(self, signal_data):
        """Local validation function for testing"""
        required_keys = ["signal_type", "symbol", "entry", "take_profits", "stop_loss"]
        # Accept both dict and SignalData for test compatibility
        if hasattr(signal_data, "__dict__"):
            d = signal_data.__dict__
        else:
            d = signal_data
        if not all(key in d for key in required_keys):
            return False

        if d["signal_type"] not in ["BUY", "SELL"]:
            return False

        if not isinstance(d["take_profits"], list) or len(d["take_profits"]) == 0:
            return False

        return True

    def test_signal_validation_edge_cases(self):
        """Test signal validation with edge cases"""
        # Valid signal
        valid_signal = SignalData(
            timestamp_utc=1234567890,
            signal_type="BUY",
            symbol="EURUSD",
            entry=1.1234,
            take_profits=[1.1250, 1.1270, 1.1300],
            stop_loss=1.1200,
            group_id=1,
            channel_name="TEST",
        )
        self.assertTrue(self.validate_signal_data(valid_signal))

        # Missing required fields
        for field in ["signal_type", "symbol", "entry", "take_profits", "stop_loss"]:
            invalid_signal = valid_signal.__dict__.copy()
            del invalid_signal[field]
            self.assertFalse(
                self.validate_signal_data(invalid_signal),
                f"Should be invalid without {field}",
            )

        # Empty take_profits
        invalid_signal = valid_signal.__dict__.copy()
        invalid_signal["take_profits"] = []
        self.assertFalse(
            self.validate_signal_data(invalid_signal),
            "Should be invalid with empty take_profits",
        )

        # Invalid signal type
        invalid_signal = valid_signal.__dict__.copy()
        invalid_signal["signal_type"] = "INVALID"
        self.assertFalse(
            self.validate_signal_data(invalid_signal),
            "Should be invalid with invalid signal_type",
        )

    def test_signal_queue_addition_edge_cases(self):
        """Test signal queue addition with edge cases"""
        # Test with many TP levels
        many_tps = [1.1250 + i * 0.001 for i in range(20)]  # 20 TP levels
        signal_data = SignalData(
            timestamp_utc=1234567890000,
            signal_type="BUY",
            symbol="EURUSD",
            entry=1.1234,
            take_profits=many_tps,
            stop_loss=1.1200,
            group_id=1234,
            channel_name="TEST",
        )

        try:
            result = add_signal_to_queue(signal_data)
            # Should handle many TPs gracefully
            self.assertIsNotNone(result)
        except Exception as e:
            self.fail(f"Should not raise exception for many TPs: {e}")

    def test_concurrent_signal_processing(self):
        """Test potential race conditions in signal processing"""
        # This is a conceptual test - actual implementation would need threading
        # For now, just test multiple rapid signal generations

        signal_data = SignalData(
            timestamp_utc=1234567890000,
            signal_type="BUY",
            symbol="EURUSD",
            entry=1.1234,
            take_profits=[1.1250, 1.1270, 1.1300],
            stop_loss=1.1200,
            group_id=1234,
            channel_name="TEST",
        )

        # Generate multiple signals rapidly
        for i in range(10):
            try:
                test_signal = SignalData(
                    **{
                        **signal_data.__dict__,
                        "group_id": 1234 + i,
                        "channel_name": f"CHAN{i}",
                    }
                )
                result = add_signal_to_queue(test_signal)
                self.assertIsNotNone(result)
            except Exception as e:
                self.fail(f"Should not raise exception for signal {i}: {e}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
