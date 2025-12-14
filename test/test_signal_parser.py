#!/usr/bin/env python3
"""
Simple test suite for the signal parser - tests all 22 user-provided signal formats
"""

import unittest
import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from signal_parser import parse_signal


class TestSignalParser(unittest.TestCase):
    
    def test_all_29_user_signals(self):
        """Test all 29 signal formats including symbol auto-detection"""
        
        signals = [
            # Signal 1: Standard BUY format
            ("BUY BTCUSD\nENTRY 89300.00\nTake profit 1 at 89500.00\nTake profit 2 at 89800.00\nTake profit 3 at 90300.00\nStop loss at 88600.00",
             "BUY", "BTCUSD", 89300.0, [89500.0, 89800.0, 90300.0], 88600.0),
            
            # Signal 2: GOLD FROM range format
            ("GOLD BUY FROM 3362/3360\n\nTP 3364\nTP 3366\nTP 3368\nTP 3370\nTP 3372\nSL 3350\n\nUSE RISK MANAGEMENT",
             "BUY", "XAUUSD", 3362.0, [3364.0, 3366.0, 3368.0, 3370.0, 3372.0], 3350.0),
            
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
             "SELL", "XAUUSD", 3334.0, [3332.0, 3330.0, 3328.0, 3325.0], 3345.0),
            
            # Signal 10: NOW signal with multiple TPs (no range = immediate)
            ("GOLD SELL NOW\n\nTP 3307\nTP 3305\nTP 3303\nTP 3300\nTP 3298\n\nSL 3322",
             "SELL", "XAUUSD", 0, [3307.0, 3305.0, 3303.0, 3300.0, 3298.0], 3322.0),
            
            # Signal 11: Slash-separated TPs format (NEW TEST CASE)
            ("GOLD BUY 3330/3327\n\nTP 3332/3334/3336/3338/3340\n\nSL 3317\n\nUSE RISK MANAGEMENT",
             "BUY", "XAUUSD", 3330.0, [3332.0, 3334.0, 3336.0, 3338.0, 3340.0], 3317.0),
            
            # Signal 12: NEW - @ range format
            ("Sell Gold @3339-3344\n\nSl :3346\n\nTp1 :3337\nTp2 :3335\n\nEnter Slowly-Layer with proper money management\n\nDo not rush your entries",
             "SELL", "XAUUSD", 3339.0, [3337.0, 3335.0], 3346.0),
            
            # Signal 13: NEW - dash range format
            ("Gold Sell 3341-3346\n\nSl :3348\n\nTp1 :3339\nTp2 :3336\n\nEnter Slowly-Layer with proper money management\n\nDo not rush your entries",
             "SELL", "XAUUSD", 3341.0, [3339.0, 3336.0], 3348.0),
            
            # Signal 14: NEW - I'M SELLING with parentheses range (NOW with range should use range as entry)
            ("I'M SELLING XAUUSD NOW (3337 - 3340)\n\n💰TP1: 3334\n💰TP2: 3331\n\n🛑 STOP LOSS: 3343",
             "SELL", "XAUUSD", 3337.0, [3334.0, 3331.0], 3343.0),
            
            # Signal 15: NEW - Colon entry format with "open" TP
            ("Gold buy : 3340.5 -3338\n\nSl 3335\n\nTp 1 : 3346\nTp 2 : open",
             "BUY", "XAUUSD", 3340.5, [3346.0, 3350.0], 3335.0),
            
            # Signal 16: NEW - T.P format with numbered take profits
            ("BTCUSD SELL 115000\nT.P1 1146000\nT.P2 1145000\nT.P3 1144000\nT.P4 1143000\nS.L   1159000",
             "SELL", "BTCUSD", 115000.0, [1146000.0, 1145000.0, 1144000.0, 1143000.0], 1159000.0),
             
            # Signal 17: NEW - Multi-line GOLD/XAUUSD with entry range and slash-separated TPs
            ("XAUUSD / GOLD SELL\n 3367/3370\n\n3365/3363/3360/3357/3355\n\n\n             SL 3385",
             "SELL", "XAUUSD", 3367.0, [3365.0, 3363.0, 3360.0, 3357.0, 3355.0], 3385.0),
             
            # Signal 18: NEW - I'M SELLING with range and emoji TPs/SL (NOW with range should use range as entry)
            ("I'M SELLING XAUUSD NOW (3330 - 3333)\n\n💰TP1: 3327\n💰TP2: 3324\n\n🛑 STOP LOSS: 3336",
             "SELL", "XAUUSD", 3330.0, [3327.0, 3324.0], 3336.0),
             
            # Signal 19: NEW - Gold buy with range entry and only "open" TP (open-only TP = [0])
            ("Gold buy : 3397-3394\n\nSl 3391\nTp open",
             "BUY", "XAUUSD", 3397.0, [0], 3391.0),
             
            # Signal 20: NEW - Typographic apostrophe in I'M BUYING NOW format
            ("I'M BUYING XAUUSD NOW (3473.5 - 3470.5)\n\n💰TP1: 3476.5\n💰TP2: 3479.5\n\n🛑 STOP LOSS: 3467.5",
             "BUY", "XAUUSD", 3473.5, [3476.5, 3479.5], 3467.5),
             
            # Signal 21: NEW - Unicode apostrophe in I'M BUYING NOW format (user-provided example)
            ("I'M BUYING XAUUSD NOW (3572.5 - 3569.5)\n\n💰TP1: 3575.5\n💰TP2: 3578.5\n\n🛑 STOP LOSS: 3566.5",
             "BUY", "XAUUSD", 3572.5, [3575.5, 3578.5], 3566.5),
             
            # Signal 22: NEW - Space in slash-separated TPs (flexible spacing handling)
            ("GOLD BUY 3578/3575\n\n3580/3582/3585/3587/3590/ 3595 \n\n\n            SL 3565",
             "BUY", "XAUUSD", 3578.0, [3580.0, 3582.0, 3585.0, 3587.0, 3590.0, 3595.0], 3565.0),
             
            # Signal 23: NEW - Abbreviated price format (4207/04 -> 4207/4204)
            ("GOLD BUY 4207/04\n\nTP 4210\nTP 4213\nTP 4216\nTP 4219\nTP 4222\nTP Open\n\nSL 4199",
             "BUY", "XAUUSD", 4207.0, [4210.0, 4213.0, 4216.0, 4219.0, 4222.0, 4226.0], 4199.0),
             
            # Signal 24: NEW - Gold Sell @ range format
            ("Gold Sell @ 4231 - 4235\n\nSl: 4238\n\nTP1: 4228",
             "SELL", "XAUUSD", 4231.0, [4228.0], 4238.0),
             
            # Signal 25: NEW - Sell gold price @ range format with open-only TP
            ("Sell gold price @ 4355-4358\n\nSl 4361\nTp open",
             "SELL", "XAUUSD", 4355.0, [0], 4361.0),
            
            # Signal 26: Multi-line individual TP format 
            ("GOLD BUY 4272/4270\n\n4275\n4277\n4280\n4282\n4285\n4290\n4295\n4300\n\nSL 4255",
             "BUY", "XAUUSD", 4272.0, [4275.0, 4277.0, 4280.0, 4282.0, 4285.0, 4290.0, 4295.0, 4300.0], 4255.0),
             
            # Signal 27: GOLD BUY with extra blank lines
            ("GOLD BUY 4192/4190\n\n\n4195\n4197\n4200\n4202\n4205\n4210\n4215\n\nSL 4185",
             "BUY", "XAUUSD", 4192.0, [4195.0, 4197.0, 4200.0, 4202.0, 4205.0, 4210.0, 4215.0], 4185.0),
             
            # Signal 28: Hash prefix with em-dash entry range
            ("#XAUUSD SELL\nENTRY: 4229–4232\nSL: 4239\nTP: 4226\nTP: 4223\nTP: 4220\nTP: 4217\nTP: 4214\n\nStay focused and trust the setup—precision beats speed in volatile markets.",
             "SELL", "XAUUSD", 4229.0, [4226.0, 4223.0, 4220.0, 4217.0, 4214.0], 4239.0),             
            # Signal 29: Symbol-less SELL FROM with auto-detection based on price range
            ("SELL FROM 4210/4215\n\n4205/4203/4200/4198/4195/4195/4190/4185/4180\n\nSL 4225",
             "SELL", "XAUUSD", 4210.0, [4205.0, 4203.0, 4200.0, 4198.0, 4195.0, 4195.0, 4190.0, 4185.0, 4180.0], 4225.0),        ]
        
        for i, (signal_text, expected_type, expected_symbol, expected_entry, expected_tps, expected_sl) in enumerate(signals, 1):
            with self.subTest(signal=i):
                result = parse_signal(signal_text)
                self.assertIsNotNone(result, f"Signal {i} should parse successfully")
                self.assertEqual(result.signal_type, expected_type, f"Signal {i} type mismatch")
                self.assertEqual(result.symbol, expected_symbol, f"Signal {i} symbol mismatch")
                self.assertEqual(result.entry, expected_entry, f"Signal {i} entry mismatch")
                self.assertIsNotNone(result.take_profits, f"Signal {i} take_profits should not be None")
                self.assertIsNotNone(result.stop_loss, f"Signal {i} stop_loss should not be None")
                self.assertGreater(len(result.take_profits), 0, f"Signal {i} should have take_profits")
                self.assertEqual(result.take_profits, expected_tps, f"Signal {i} take_profits mismatch")
                self.assertEqual(result.stop_loss, expected_sl, f"Signal {i} stop_loss mismatch")
                
                # Note: Open-only TP signals have take_profits = [0] which is now valid

        print("✅ All 29 user-provided signal formats passed!")


if __name__ == '__main__':
    unittest.main(verbosity=2)
