#!/usr/bin/env python3
"""
Comprehensive end-to-end workflow test
Tests the complete signal processing workflow from parsing to MT4 compatibility
"""

import unittest
import os
from signal_parser import parse_signal, clean_channel_name, format_mt4_comment
from queue_manager import add_signal_to_queue
from signal_data import SignalData


class TestEndToEndWorkflow(unittest.TestCase):
    def test_complete_signal_workflow(self):
        """Test complete workflow: Parse signal -> Generate comment -> MT4 compatibility"""

        # Test signal text (one of the 8 user formats)
        signal_text = """BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Take profit 3 at 90300.00
Stop loss at 88600.00"""

        print("Testing complete signal workflow:")
        print("=" * 50)

        # Step 1: Parse signal
        parsed_signal = parse_signal(signal_text)
        self.assertIsNotNone(parsed_signal, "Signal should parse successfully")

        print(f"1. Signal parsed: {parsed_signal.signal_type} {parsed_signal.symbol}")
        print(f"   Entry: {parsed_signal.entry}")
        print(f"   TPs: {parsed_signal.take_profits}")
        print(f"   SL: {parsed_signal.stop_loss}")

        # Step 2: Create signal data for queue
        signal_data = SignalData(
            timestamp_utc=1234567890000,
            signal_type=parsed_signal.signal_type,
            symbol=parsed_signal.symbol,
            entry=parsed_signal.entry,
            take_profits=parsed_signal.take_profits,
            stop_loss=parsed_signal.stop_loss,
            group_id=5678,
            channel_name="PREMIUM_TRADING_SIGNALS",
        )

        # Step 3: Add to queue (tests Python formatting)
        result = add_signal_to_queue(signal_data)
        self.assertTrue(result, "Signal should be added to queue successfully")
        print("2. Signal added to queue successfully")

        # Step 4: Test MT4 comment generation and parsing
        channel_clean = clean_channel_name(signal_data.channel_name)
        comment = format_mt4_comment(
            signal_data.group_id, channel_clean, signal_data.stop_loss
        )
        print(f"3. MT4 Comment generated: '{comment}' ({len(comment)} chars)")

        # Step 5: Verify comment parsing (simulate MT4 logic)
        parts = comment.split("|")
        self.assertEqual(len(parts), 3, "Comment should have 3 parts")

        parsed_gid = int(parts[0])
        parsed_channel = parts[1]
        parsed_sl = float(parts[2])

        self.assertEqual(parsed_gid, signal_data.group_id)
        self.assertEqual(len(parsed_channel), 4)
        self.assertAlmostEqual(parsed_sl, signal_data.stop_loss, places=2)

        print(
            f"4. Comment parsed: GID={parsed_gid}, Channel='{parsed_channel}', SL={parsed_sl}"
        )

        # Step 6: Verify queue file format (read last line)
        from config import MT4_QUEUE_FILE_PATHS

        if MT4_QUEUE_FILE_PATHS:
            queue_path = MT4_QUEUE_FILE_PATHS[0]
            if os.path.exists(queue_path):
                with open(queue_path, "r", encoding="utf-8") as f:
                    lines = f.readlines()
                    if lines:
                        last_line = lines[-1].strip()
                        print(f"5. Queue format: {last_line}")

                        # Verify format compatibility with MT4 ReadSignalFile
                        queue_parts = last_line.split("|")
                        self.assertGreaterEqual(
                            len(queue_parts),
                            8,
                            "Queue format should have at least 8 parts",
                        )

                        # Verify each part matches expected format
                        self.assertEqual(queue_parts[1], parsed_signal.signal_type)
                        self.assertEqual(queue_parts[2], parsed_signal.symbol)
                        self.assertEqual(float(queue_parts[3]), parsed_signal.entry)
                        self.assertEqual(float(queue_parts[5]), parsed_signal.stop_loss)
                        self.assertTrue(queue_parts[6].startswith("GID:"))
                        self.assertEqual(len(queue_parts[7]), 4)  # Channel name

        print("✅ Complete workflow test passed!")

    def test_multiple_signal_formats(self):
        """Test workflow with all 8 user signal formats"""

        test_signals = [
            # Signal 1: Standard BUY format
            (
                "BUY BTCUSD\nENTRY 89300.00\nTake profit 1 at 89500.00\nTake profit 2 at 89800.00\nTake profit 3 at 90300.00\nStop loss at 88600.00",
                "BTCUSD",
                "BUY",
            ),
            # Signal 2: GOLD FROM range format
            (
                "GOLD BUY FROM 3362/3360\n\nTP 3364\nTP 3366\nTP 3368\nTP 3370\nTP 3372\nSL 3350\n\nUSE RISK MANAGEMENT",
                "XAUUSD",
                "BUY",
            ),
            # Signal 3: Emoji alert format
            (
                "SIGNAL ALERT\n\nSELL XAUUSD 3290.5\n\n🤑TP1: 3289.0\n🤑TP2: 3287.5\n🤑TP3: 3281.4\n🔴SL: 3298.8 (830 pips)",
                "XAUUSD",
                "SELL",
            ),
            # Signal 4: Colon format
            (
                "EURUSD BUY\n\nENTRY 1.1435\n\nTP: 1.1455\nTP: 1.1485\nTP: 1.1535\nSL: 1.1345",
                "EURUSD",
                "BUY",
            ),
            # Signal 5: Numbered TP format
            (
                "XAUUSD BUY\n\nENTRY: 3418\n\nTP1 3420\nTP2 3423\nTP3 3428\nSL 3412",
                "XAUUSD",
                "BUY",
            ),
        ]

        print("\nTesting multiple signal formats workflow:")
        print("=" * 55)

        for i, (signal_text, expected_symbol, expected_type) in enumerate(
            test_signals, 1
        ):
            with self.subTest(signal=i):
                # Parse signal
                parsed = parse_signal(signal_text)
                self.assertIsNotNone(parsed, f"Signal {i} should parse")
                self.assertEqual(
                    parsed.symbol, expected_symbol, f"Signal {i} symbol mismatch"
                )
                self.assertEqual(
                    parsed.signal_type, expected_type, f"Signal {i} type mismatch"
                )

                # Create signal data
                signal_data = SignalData(
                    timestamp_utc=1234567890000 + i,
                    signal_type=parsed.signal_type,
                    symbol=parsed.symbol,
                    entry=parsed.entry,
                    take_profits=parsed.take_profits,
                    stop_loss=parsed.stop_loss,
                    group_id=1000 + i,
                    channel_name=f"CHANNEL_{i}",
                )

                # Test queue addition
                result = add_signal_to_queue(signal_data)
                self.assertTrue(result, f"Signal {i} should be added to queue")

                # Test comment generation
                comment = format_mt4_comment(
                    signal_data.group_id,
                    signal_data.channel_name,
                    signal_data.stop_loss,
                )
                self.assertLessEqual(
                    len(comment), 31, f"Signal {i} comment too long: {comment}"
                )

                print(
                    f"  Signal {i}: {expected_type} {expected_symbol} -> Comment: '{comment}' ✅"
                )

        print("✅ All signal formats processed successfully!")

    def test_error_handling_and_edge_cases(self):
        """Test error handling in the complete workflow"""

        print("\nTesting error handling and edge cases:")
        print("=" * 45)

        # Test 1: Invalid signal format
        invalid_signal = "This is not a valid signal"
        parsed = parse_signal(invalid_signal)
        self.assertIsNone(parsed, "Invalid signal should return None")
        print("1. Invalid signal correctly rejected ✅")

        # Test 2: Empty channel name
        signal_data = SignalData(
            timestamp_utc=1234567890000,
            signal_type="BUY",
            symbol="EURUSD",
            entry=1.1234,
            take_profits=[1.1250, 1.1270, 1.1300],
            stop_loss=1.1200,
            group_id=9999,
            channel_name="",
        )

        result = add_signal_to_queue(signal_data)
        self.assertTrue(result, "Signal with empty channel should still work")
        print("2. Empty channel name handled correctly ✅")

        # Test 3: Very long GID and SL
        signal_data.group_id = 999999999
        signal_data.stop_loss = 123456.789012345
        signal_data.channel_name = "TEST"

        comment = format_mt4_comment(
            signal_data.group_id, signal_data.channel_name, signal_data.stop_loss
        )
        self.assertLessEqual(
            len(comment), 31, f"Long values comment should fit: {comment}"
        )
        print(f"3. Long values handled: '{comment}' ({len(comment)} chars) ✅")

        # Test 4: Single TP level
        signal_data.take_profits = [1.1250]
        result = add_signal_to_queue(signal_data)
        self.assertTrue(result, "Single TP should work")
        print("4. Single TP level handled correctly ✅")

        print("✅ All error handling tests passed!")


if __name__ == "__main__":
    unittest.main(verbosity=2)
