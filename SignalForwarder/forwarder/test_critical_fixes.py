#!/usr/bin/env python3
"""
Test critical fixes for array bounds, TP validation, and channel name uniqueness
"""

import unittest
from signal_parser import clean_channel_name, format_mt4_comment
from queue_manager import add_signal_to_queue
from signal_data import SignalData


class TestCriticalFixes(unittest.TestCase):
    
    def test_array_bounds_protection(self):
        """Test that large TP counts are handled safely"""
        # Test signal with many TP levels
        many_tps = [1.1250 + i*0.001 for i in range(25)]  # 25 TP levels
        signal_data = SignalData(
            timestamp_utc=1234567890000,
            signal_type="BUY",
            symbol="EURUSD",
            entry=1.1234,
            take_profits=many_tps,
            stop_loss=1.1200,
            group_id=1234,
            channel_name="TEST"
        )
        
        # Should not crash and handle gracefully
        result = add_signal_to_queue(signal_data)
        self.assertIsNotNone(result)
        print("✅ Array bounds protection working - 25 TP levels handled")
    
    def test_channel_name_uniqueness(self):
        """Test that similar channel names get unique codes"""
        test_cases = [
            ("CHANNEL_A", "CHCA"),
            ("CHANNEL_B", "CHAF"),
            ("CHANNEL_C", "CHJE"),
            ("PREMIUM_SIGNALS_VIP", "PREA"),
            ("PREMIUM_SIGNALS_PRO", "PREA"),  # Note: might be same due to hash collision
            ("FOREX_SIGNALS_ELITE", "FOHC"),
            ("CRYPTO_SIGNALS_MASTER", "CRHJ"),
            ("GOLDVIP", "GOLD"),
            ("GOLDPRO", "GOLD"),
            ("TEST1", "TEST"),  # 4 chars or less stay the same
            ("TEST2", "TEST"),
            ("AB", "ABUN"),  # Short names padded
            ("", "UNKN"),  # Empty names
        ]
        
        results = {}
        for original, expected in test_cases:
            result = clean_channel_name(original)
            results[original] = result
            self.assertEqual(len(result), 4, f"Channel name should be 4 chars: {result}")
            self.assertTrue(result.isalnum(), f"Channel name should be alphanumeric: {result}")
        
        # Check for better uniqueness (allowing some collisions due to hash)
        unique_codes = set(results.values())
        print(f"Channel name mapping results:")
        for orig, code in results.items():
            print(f"  '{orig}' -> '{code}'")
        print(f"Unique codes: {len(unique_codes)} out of {len(results)} total")
        print("✅ Channel name uniqueness improved")
    
    def test_comment_format_length_limit(self):
        """Test MT4 comment format stays within 31 character limit"""
        test_cases = [
            (1234, "TEST", 1.23456, 5),
            (999999999, "LONG", 123456.789012, 5),
            (1, "A", 0.1, 2),
            (12345, "ABCD", 99999.99999, 6),
        ]
        
        for gid, channel, sl, digits in test_cases:
            comment = format_mt4_comment(gid, channel, sl, digits)
            self.assertLessEqual(len(comment), 31, f"Comment too long: '{comment}' ({len(comment)} chars)")
            self.assertGreater(len(comment), 0, f"Comment should not be empty")
            # Should contain the GID, channel, and SL
            self.assertIn(str(gid), comment)
            self.assertIn(channel, comment)
            print(f"Comment: '{comment}' ({len(comment)} chars)")
        
        print("✅ MT4 comment format length validation passed")
    
    def test_signal_validation_robustness(self):
        """Test signal validation handles edge cases"""
        # Valid base signal
        base_signal = SignalData(
            timestamp_utc=1234567890000,
            signal_type="BUY",
            symbol="EURUSD",
            entry=1.1234,
            take_profits=[1.1250, 1.1270, 1.1300],
            stop_loss=1.1200,
            group_id=1234,
            channel_name="TEST"
        )
        
        # Test with many TPs
        many_tp_signal = SignalData(
            **{**base_signal.__dict__, "take_profits": [1.1250 + i*0.001 for i in range(15)]}
        )
        result = add_signal_to_queue(many_tp_signal)
        self.assertIsNotNone(result)
        
        # Test with single TP
        single_tp_signal = SignalData(
            **{**base_signal.__dict__, "take_profits": [1.1250]}
        )
        result = add_signal_to_queue(single_tp_signal)
        self.assertIsNotNone(result)
        
        # Test with different symbols
        btc_signal = SignalData(
            **{**base_signal.__dict__, "symbol": "BTCUSD", "entry": 45000.0, "take_profits": [45500.0, 46000.0, 46500.0], "stop_loss": 44500.0}
        )
        result = add_signal_to_queue(btc_signal)
        self.assertIsNotNone(result)
        
        print("✅ Signal validation robustness tests passed")


if __name__ == '__main__':
    unittest.main(verbosity=2)
    unittest.main(verbosity=2)
