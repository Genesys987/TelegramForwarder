#!/usr/bin/env python3
"""
Final comprehensive test to verify all components work together correctly.
This test checks ALL critical aspects of the system in one comprehensive run.
"""

import unittest
import os
import tempfile
import shutil
from signal_parser import parse_signal, clean_channel_name, format_mt4_comment
from queue_manager import add_signal_to_queue, process_signal_queue
import config
from config import MT4_QUEUE_FILE_PATHS, MT4_SIGNAL_FILE_PATHS
import time
from signal_data import SignalData


class TestFinalComprehensive(unittest.TestCase):
    def setUp(self):
        """Set up test environment with isolated temp files"""
        self.test_dir = tempfile.mkdtemp()
        self._orig_queue_paths = list(config.MT4_QUEUE_FILE_PATHS)
        self._orig_signal_paths = list(config.MT4_SIGNAL_FILE_PATHS)
        config.MT4_QUEUE_FILE_PATHS.clear()
        config.MT4_QUEUE_FILE_PATHS.append(os.path.join(self.test_dir, "test_queue.txt"))
        config.MT4_SIGNAL_FILE_PATHS.clear()
        config.MT4_SIGNAL_FILE_PATHS.append(os.path.join(self.test_dir, "test_signals.txt"))

    def tearDown(self):
        """Restore original file paths and clean up temp dir"""
        config.MT4_QUEUE_FILE_PATHS.clear()
        config.MT4_QUEUE_FILE_PATHS.extend(self._orig_queue_paths)
        config.MT4_SIGNAL_FILE_PATHS.clear()
        config.MT4_SIGNAL_FILE_PATHS.extend(self._orig_signal_paths)
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_complete_system_integration(self):
        """Test complete system integration with all components"""
        print("\n" + "=" * 80)
        print("FINAL COMPREHENSIVE SYSTEM INTEGRATION TEST")
        print("=" * 80)

        # Test signals covering all edge cases
        test_signals = [
            # Basic signals
            {
                "text": """BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Take profit 3 at 90300.00
Stop loss at 88600.00""",
                "channel": "CRYPTO_MASTER_SIGNALS",
                "expected_symbol": "BTCUSD",
                "expected_type": "BUY",
            },
            # GOLD mapping + FROM format
            {
                "text": "GOLD SELL FROM 3313/3315.3\n\nTP1 3289.0\nTP2 3287.5\nTP3 3281.4\nSL 3298.8",
                "channel": "GOLD & FOREX VIP",
                "expected_symbol": "XAUUSD",
                "expected_type": "SELL",
            },
            # Many TPs
            {
                "text": """BUY EURUSD
ENTRY 1.1435
TP1 1.1455
TP2 1.1465
TP3 1.1475
TP4 1.1485
TP5 1.1495
TP6 1.1505
TP7 1.1515
TP8 1.1525
TP9 1.1535
SL 1.1345""",
                "channel": "PREMIUM_TRADING_SIGNALS",
                "expected_symbol": "EURUSD",
                "expected_type": "BUY",
            },
            # Single TP
            {
                "text": "XAUUSD BUY 3417\nTP 3420\nSL 3412",
                "channel": "SIMPLE_CHANNEL",
                "expected_symbol": "XAUUSD",
                "expected_type": "BUY",
            },
        ]

        processed_signals = []

        for i, test_case in enumerate(test_signals):
            print(
                f"\n--- Test Signal {i + 1}: {test_case['expected_type']} {test_case['expected_symbol']} ---"
            )

            # 1. Parse signal
            parsed = parse_signal(test_case["text"])
            self.assertIsNotNone(parsed, f"Signal {i + 1} failed to parse")
            self.assertEqual(parsed.signal_type, test_case["expected_type"])
            self.assertEqual(parsed.symbol, test_case["expected_symbol"])

            # 2. Create signal data for queue
            signal_data = SignalData(
                timestamp_utc=int(time.time() * 1000) + i,  # Unique timestamps
                signal_type=parsed.signal_type,
                symbol=parsed.symbol,
                entry=parsed.entry,
                take_profits=parsed.take_profits,
                stop_loss=parsed.stop_loss,
                group_id=1000 + i,
                channel_name=test_case["channel"],
            )

            # 3. Add to queue
            success = add_signal_to_queue(signal_data)
            self.assertTrue(success, f"Failed to add signal {i + 1} to queue")

            # 4. Test channel name cleaning
            clean_channel = clean_channel_name(test_case["channel"])
            self.assertEqual(
                len(clean_channel), 4, f"Channel name not 4 chars: {clean_channel}"
            )

            # 5. Test MT4 comment generation
            comment = format_mt4_comment(
                signal_data.group_id, clean_channel, signal_data.stop_loss
            )
            self.assertLessEqual(len(comment), 31, f"Comment too long: {comment}")

            # 6. Test comment parsing (simulate MT4 logic)
            parts = comment.split("|")
            self.assertEqual(len(parts), 3, f"Comment format invalid: {comment}")
            parsed_gid = int(parts[0])
            parsed_channel = parts[1]
            parsed_sl = float(parts[2])

            self.assertEqual(parsed_gid, signal_data.group_id)
            self.assertEqual(parsed_channel, clean_channel)
            self.assertAlmostEqual(parsed_sl, signal_data.stop_loss, places=4)

            processed_signals.append(
                {
                    "signal_data": signal_data,
                    "clean_channel": clean_channel,
                    "comment": comment,
                    "tp_count": len(parsed.take_profits),
                }
            )

            print(f"  ✅ Parsed: {parsed.signal_type} {parsed.symbol} @ {parsed.entry}")
            print(f"  ✅ TPs: {len(parsed.take_profits)} levels")
            print(f"  ✅ Channel: '{test_case['channel']}' -> '{clean_channel}'")
            print(f"  ✅ Comment: '{comment}' ({len(comment)} chars)")

        print("\n--- Summary ---")
        print(f"✅ {len(processed_signals)} signals processed successfully")
        print("✅ All comment formats within 31 character limit")
        print("✅ All channel names cleaned to 4 characters")
        print("✅ All signals added to queue successfully")

        # 7. Test queue processing
        print("\n--- Queue Processing Test ---")

        # Check queue files exist and have content
        for queue_path in MT4_QUEUE_FILE_PATHS:
            self.assertTrue(
                os.path.exists(queue_path), f"Queue file missing: {queue_path}"
            )
            with open(queue_path, "r", encoding="utf-8") as f:
                content = f.read()
                self.assertGreater(len(content), 0, f"Queue file empty: {queue_path}")
                lines = [line for line in content.strip().split("\n") if line.strip()]
                self.assertEqual(
                    len(lines),
                    len(test_signals),
                    f"Wrong number of signals in queue: {len(lines)} != {len(test_signals)}",
                )

        # Process queue (simulate MT4 not running)
        process_signal_queue()

        # Check signal files were created
        for signal_path in MT4_SIGNAL_FILE_PATHS:
            self.assertTrue(
                os.path.exists(signal_path), f"Signal file not created: {signal_path}"
            )
            with open(signal_path, "r", encoding="utf-8") as f:
                content = f.read().strip()
                self.assertGreater(len(content), 0, f"Signal file empty: {signal_path}")
                print(f"  ✅ Signal file created: {os.path.basename(signal_path)}")

        print("✅ Queue processing successful")

        # 8. Test edge cases
        print("\n--- Edge Cases Test ---")

        # Very long GID and SL
        long_gid = 999999999
        long_sl = 123456.789012345
        long_comment = format_mt4_comment(long_gid, "TEST", long_sl)
        self.assertLessEqual(
            len(long_comment), 31, f"Long comment too long: {long_comment}"
        )
        print(f"  ✅ Long values handled: '{long_comment}' ({len(long_comment)} chars)")

        # Empty channel name
        empty_channel = clean_channel_name("")
        self.assertEqual(
            empty_channel, "UNKN", f"Empty channel not handled: {empty_channel}"
        )
        print(f"  ✅ Empty channel handled: '{empty_channel}'")

        # Non-alphabetic channel name
        numeric_channel = clean_channel_name("123456")
        self.assertEqual(
            numeric_channel, "UNKN", f"Numeric channel not handled: {numeric_channel}"
        )
        print(f"  ✅ Numeric channel handled: '{numeric_channel}'")

        # Very long channel name
        long_channel_name = "VeryLongChannelNameThatExceedsNormalLimits"
        short_channel = clean_channel_name(long_channel_name)
        self.assertEqual(
            len(short_channel), 4, f"Long channel not truncated: {short_channel}"
        )
        print(
            f"  ✅ Long channel truncated: '{long_channel_name}' -> '{short_channel}'"
        )

        print("\n" + "=" * 80)
        print("✅ ALL COMPREHENSIVE TESTS PASSED!")
        print("✅ System is fully functional and production-ready")
        print("=" * 80)


if __name__ == "__main__":
    unittest.main()
