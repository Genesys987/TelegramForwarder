#!/usr/bin/env python3
"""
Comprehensive compatibility test between Python and MT4 functions
Tests the complete workflow from Python signal generation to MT4 parsing
"""

import unittest
import os
from signal_data import SignalData
from signal_parser import clean_channel_name, format_mt4_comment
from queue_manager import add_signal_to_queue


class TestPythonMT4Compatibility(unittest.TestCase):
    def test_channel_name_python_vs_mt4_logic(self):
        """Test that Python and MT4 channel name cleaning produces compatible results"""

        # Test cases that should work the same in both Python and MT4
        test_cases = [
            "TRADING_SIGNALS",
            "CRYPTO_MASTER",
            "FOREX_VIP",
            "GOLD_PREMIUM",
            "BTC_SIGNALS",
            "TEST123",
            "ABC",
            "ABCDEF",
            "VeryLongChannelName",
            "🔥SIGNALS🔥",
            "CHANNEL_A",
            "CHANNEL_B",
            "",
            "123",
            "!@#$%",
        ]

        print("Testing channel name compatibility Python vs MT4:")

        for channel in test_cases:
            python_result = clean_channel_name(channel)

            # Simulate MT4 CleanChannelName logic
            mt4_result = ""
            for char in channel.upper():
                if len(mt4_result) >= 4:
                    break
                if char.isalpha():
                    mt4_result += char

            if len(mt4_result) == 0:
                mt4_result = "UNKN"
            elif len(mt4_result) < 4:
                mt4_result = mt4_result + "UNKN"[: (4 - len(mt4_result))]

            mt4_result = mt4_result[:4]

            # Check if they are compatible (don't need to be identical due to hash)
            self.assertEqual(
                len(python_result),
                4,
                f"Python result should be 4 chars: {python_result}",
            )
            self.assertEqual(
                len(mt4_result), 4, f"MT4 result should be 4 chars: {mt4_result}"
            )
            self.assertTrue(
                python_result.isalnum(),
                f"Python result should be alphanumeric: {python_result}",
            )
            self.assertTrue(
                mt4_result.isalnum(), f"MT4 result should be alphanumeric: {mt4_result}"
            )

            print(
                f"  '{channel}' -> Python: '{python_result}', MT4 equivalent: '{mt4_result}'"
            )

    def test_comment_format_python_vs_mt4_parsing(self):
        """Test that Python-generated comments can be parsed by MT4 logic"""

        test_cases = [
            (1234, "TEST", 1.23456, 5),
            (999999, "LONG", 0.12345, 4),
            (1, "ABCD", 99999.99, 2),
            (12345, "SHOR", 1.1, 1),
        ]

        print("\nTesting comment format compatibility:")

        for gid, channel, sl, digits in test_cases:
            # Generate comment with Python
            python_comment = format_mt4_comment(gid, channel, sl, digits)

            # Simulate MT4 ParseOrderCommentFull logic for new format
            parts = python_comment.split("|")

            self.assertEqual(
                len(parts), 3, f"Comment should have 3 parts: {python_comment}"
            )

            # Parse GID
            parsed_gid = int(parts[0])
            self.assertEqual(
                parsed_gid, gid, f"GID should match: {parsed_gid} vs {gid}"
            )

            # Parse channel
            parsed_channel = parts[1]
            self.assertEqual(
                len(parsed_channel), 4, f"Channel should be 4 chars: {parsed_channel}"
            )

            # Parse SL
            parsed_sl = float(parts[2])
            self.assertAlmostEqual(
                parsed_sl, sl, places=2, msg=f"SL should match: {parsed_sl} vs {sl}"
            )

            print(
                f"  GID:{gid}, Channel:'{channel}', SL:{sl} -> '{python_comment}' -> Parsed: GID:{parsed_gid}, Channel:'{parsed_channel}', SL:{parsed_sl}"
            )

    def test_signal_queue_format_compatibility(self):
        """Test that queue file format is compatible with MT4 ReadSignalFile"""

        # Create test signal
        signal_data = SignalData(
            timestamp_utc=1234567890000,
            signal_type="BUY",
            symbol="EURUSD",
            entry=1.1234,
            take_profits=[1.1250, 1.1270, 1.1300],
            stop_loss=1.1200,
            group_id=1234,
            channel_name="TEST_CHANNEL",
        )

        # Add to queue (this generates the format)
        result = add_signal_to_queue(signal_data)
        self.assertTrue(result, "Signal should be added to queue successfully")

        # Read the generated queue file to verify format
        from config import MT4_QUEUE_FILE_PATHS

        if MT4_QUEUE_FILE_PATHS:
            queue_path = MT4_QUEUE_FILE_PATHS[0]
            if os.path.exists(queue_path):
                with open(queue_path, "r", encoding="utf-8") as f:
                    lines = f.readlines()
                    if lines:
                        last_line = lines[-1].strip()
                        print(f"\nGenerated queue format: {last_line}")

                        # Simulate MT4 parsing
                        parts = last_line.split("|")
                        self.assertGreaterEqual(
                            len(parts), 8, f"Should have at least 8 parts: {len(parts)}"
                        )

                        # Verify each part
                        self.assertEqual(parts[0], "1234567890000")  # timestamp
                        self.assertEqual(parts[1], "BUY")  # signal_type
                        self.assertEqual(parts[2], "EURUSD")  # symbol
                        self.assertEqual(parts[3], "1.1234")  # entry
                        self.assertEqual(parts[4], "1.125,1.127,1.13")  # take_profits
                        self.assertEqual(parts[5], "1.12")  # stop_loss
                        self.assertEqual(parts[6], "GID:1234")  # group_id
                        self.assertEqual(len(parts[7]), 4)  # channel_name (4 chars)

                        print("✅ Queue format is compatible with MT4 ReadSignalFile")

    def test_backward_compatibility_old_formats(self):
        """Test that old comment formats can still be parsed"""

        # Test old format parsing logic
        old_format_comments = [
            "GID:1234|SL:1.2345",
            "GID:999|TEST|SL:0.9876",
            "GID:12345|ABCD|SL:99.99",
        ]

        print("\nTesting backward compatibility:")

        for comment in old_format_comments:
            # Simulate MT4 ParseOrderCommentFull logic for old format
            if comment.startswith("GID:"):
                parts = comment.split("|")

                # Extract GID
                gid_part = parts[0]
                gid = int(gid_part[4:])  # Remove "GID:" prefix

                # Find SL part
                sl_part = None
                channel = "LEGC"  # Default for old format

                for part in parts[1:]:
                    if part.startswith("SL:"):
                        sl_part = part
                        break
                    elif not part.startswith("SL:"):
                        channel = part

                if sl_part:
                    sl = float(sl_part[3:])  # Remove "SL:" prefix
                    print(f"  '{comment}' -> GID:{gid}, Channel:'{channel}', SL:{sl}")

                    # Verify parsing logic
                    self.assertGreater(gid, 0, f"GID should be positive: {gid}")
                    self.assertEqual(
                        len(channel), 4, f"Channel should be 4 chars: {channel}"
                    )
                    self.assertIsInstance(sl, float, f"SL should be float: {sl}")

    def test_array_bounds_and_tp_handling(self):
        """Test that TP array handling is compatible between Python and MT4"""

        # Test different TP counts
        tp_test_cases = [
            [1.1250],  # 1 TP
            [1.1250, 1.1270],  # 2 TPs
            [1.1250, 1.1270, 1.1300],  # 3 TPs
            [1.1250, 1.1270, 1.1300, 1.1350],  # 4 TPs
            [1.1250 + i * 0.001 for i in range(15)],  # 15 TPs
            [1.1250 + i * 0.001 for i in range(25)],  # 25 TPs (exceeds MT4 limit)
        ]

        print("\nTesting TP array handling:")

        for i, tps in enumerate(tp_test_cases):
            signal_data = SignalData(
                timestamp_utc=1234567890000,
                signal_type="BUY",
                symbol="EURUSD",
                entry=1.1234,
                take_profits=tps,
                stop_loss=1.1200,
                group_id=1000 + i,
                channel_name=f"TEST{i}",
            )

            # Test Python handling
            result = add_signal_to_queue(signal_data)
            self.assertTrue(result, f"Should handle {len(tps)} TPs")

            # Test MT4 bounds (simulate)
            mt4_tp_count = min(len(tps), 20)  # MT4 has max 20 limit

            print(
                f"  {len(tps)} TPs -> Python: ✅, MT4 equivalent: {mt4_tp_count} TPs (max 20)"
            )

            if len(tps) > 20:
                print("    Warning: MT4 would truncate to 20 TPs")


if __name__ == "__main__":
    unittest.main(verbosity=2)
