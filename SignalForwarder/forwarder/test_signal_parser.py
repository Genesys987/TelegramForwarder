#!/usr/bin/env python3
"""
Simple test suite for the signal parser - tests all 15 user-provided signal formats
"""

import unittest
from signal_parser import parse_signal


class TestSignalParser(unittest.TestCase):
    
    def test_all_15_user_signals(self):
        """Test all 15 signal formats provided by the user (including 4 new ones)"""
        
        signals = [
            # Signal 1: Standard BUY format
            ("BUY BTCUSD\nENTRY 89300.00\nTake profit 1 at 89500.00\nTake profit 2 at 89800.00\nTake profit 3 at 90300.00\nStop loss at 88600.00",
             "BUY", "BTCUSD", 89300.0, [89500.0, 89800.0, 90300.0], 88600.0),
            
            # Signal 2: GOLD FROM range format
            ("GOLD BUY FROM 3362/3360\n\nTP 3364\nTP 3366\nTP 3368\nTP 3370\nTP 3372\nSL 3350\n\nUSE RISK MANAGEMENT",
             "BUY", "XAUUSD", 3360.0, [3364.0, 3366.0, 3368.0, 3370.0, 3372.0], 3350.0),
            
            # Signal 3: Emoji alert format
            ("SIGNAL ALERT\n\nSELL XAUUSD 3290.5\n\n🤑TP1: 3289.0\n🤑TP2: 3287.5\n🤑TP3: 3281.4\n🔴SL: 3298.8 (830 pips)",
             "SELL", "XAUUSD", 3290.5, [3289.0, 3287.5, 3281.4], 3298.8),
            
            # Signal 4: Colon format
            ("EURUSD BUY\n\nENTRY 1.1435\n\nTP: 1.1455\nTP: 1.1485\nTP: 1.1535\nSL: 1.1345",
             "BUY", "EURUSD", 1.1435, [1.1455, 1.1485, 1.1535], 1.1345),
            
            # Signal 5: Numbered TP format
            ("XAUUSD BUY\n\nENTRY: 3418\n\nTP1 3420\nTP2 3423\nTP3 3428\nSL 3412",
             "BUY", "XAUUSD", 3418.0, [3420.0, 3423.0, 3428.0], 3412.0),
            
            # Signal 6: Pipe format with emojis
            ("BTCUSD | BUY 109500\n\n❌ Stop Loss 109000 (500 pips)\n\n✅TP1 109700\n✅TP2 109900\n✅TP3 110500",
             "BUY", "BTCUSD", 109500.0, [109700.0, 109900.0, 110500.0], 109000.0),
            
            # Signal 7: Same as Signal 6
            ("BTCUSD | BUY 109500\n\n❌ Stop Loss 109000 (500 pips)\n\n✅TP1 109700\n✅TP2 109900\n✅TP3 110500",
             "BUY", "BTCUSD", 109500.0, [109700.0, 109900.0, 110500.0], 109000.0),
            
            # Signal 8: NEW FORMAT - Simple symbol buy price
            ("XAUUSD BUY 3417\n\nSL:  3411.68\nTP:  3443.68\n--Trade by Matthew",
             "BUY", "XAUUSD", 3417.0, [3443.68], 3411.68),
            
            # Signal 9: Range entry with slashed TPs format
            ("GOLD SELL 3334/3337\n\n3332/3330/3328/3325\n\n        SL 3345",
             "SELL", "XAUUSD", 3337.0, [3332.0, 3330.0, 3328.0, 3325.0], 3345.0),
            
            # Signal 10: NOW signal with multiple TPs
            ("GOLD SELL NOW\n\nTP 3307\nTP 3305\nTP 3303\nTP 3300\nTP 3298\n\nSL 3322",
             "SELL", "XAUUSD", 0, [3307.0, 3305.0, 3303.0, 3300.0, 3298.0], 3322.0),
            
            # Signal 11: Slash-separated TPs format (NEW TEST CASE)
            ("GOLD BUY 3330/3327\n\nTP 3332/3334/3336/3338/3340\n\nSL 3317\n\nUSE RISK MANAGEMENT",
             "BUY", "XAUUSD", 3327.0, [3332.0, 3334.0, 3336.0, 3338.0, 3340.0], 3317.0),
            
            # Signal 12: NEW - @ range format
            ("Sell Gold @3339-3344\n\nSl :3346\n\nTp1 :3337\nTp2 :3335\n\nEnter Slowly-Layer with proper money management\n\nDo not rush your entries",
             "SELL", "XAUUSD", 3344.0, [3337.0, 3335.0], 3346.0),
            
            # Signal 13: NEW - dash range format
            ("Gold Sell 3341-3346\n\nSl :3348\n\nTp1 :3339\nTp2 :3336\n\nEnter Slowly-Layer with proper money management\n\nDo not rush your entries",
             "SELL", "XAUUSD", 3346.0, [3339.0, 3336.0], 3348.0),
            
            # Signal 14: NEW - I'M SELLING with parentheses range
            ("I'M SELLING XAUUSD NOW (3337 - 3340)\n\n💰TP1: 3334\n💰TP2: 3331\n\n🛑 STOP LOSS: 3343",
             "SELL", "XAUUSD", 0, [3334.0, 3331.0], 3343.0),
            
            # Signal 15: NEW - Colon entry format with "open" TP
            ("Gold buy : 3340.5 -3338\n\nSl 3335\n\nTp 1 : 3346\nTp 2 : open",
             "BUY", "XAUUSD", 3338.0, [3346.0, 3350.0], 3335.0),
        ]
        
        for i, (signal_text, expected_type, expected_symbol, expected_entry, expected_tps, expected_sl) in enumerate(signals, 1):
            with self.subTest(signal=i):
                result = parse_signal(signal_text)
                self.assertIsNotNone(result, f"Signal {i} should parse successfully")
                self.assertEqual(result["signal_type"], expected_type)
                self.assertEqual(result["symbol"], expected_symbol)
                self.assertEqual(result["entry"], expected_entry)
                self.assertIsNotNone(result["take_profits"])
                self.assertIsNotNone(result["stop_loss"])
                self.assertGreater(len(result["take_profits"]), 0)
                self.assertEqual(result["take_profits"], expected_tps)
                self.assertEqual(result["stop_loss"], expected_sl)
        
        print("✅ All 15 user-provided signal formats passed!")


if __name__ == '__main__':
    unittest.main(verbosity=2)
