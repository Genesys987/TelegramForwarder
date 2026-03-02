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
    def test_all_51_user_signals(self):
        """Test all 55 signal formats provided by the user including new formats with unicode dashes and hash prefixes"""

        signals = [
            # Signal 1: Standard BUY format
            (
                "BUY BTCUSD\nENTRY 89300.00\nTake profit 1 at 89500.00\nTake profit 2 at 89800.00\nTake profit 3 at 90300.00\nStop loss at 88600.00",
                "BUY",
                "BTCUSD",
                89300.0,
                [89500.0, 89800.0, 90300.0],
                88600.0,
            ),
            # Signal 2: GOLD FROM range format
            (
                "GOLD BUY FROM 3362/3360\n\nTP 3364\nTP 3366\nTP 3368\nTP 3370\nTP 3372\nSL 3350\n\nUSE RISK MANAGEMENT",
                "BUY",
                "XAUUSD",
                3362.0,
                [3364.0, 3366.0, 3368.0, 3370.0, 3372.0],
                3350.0,
            ),
            # Signal 3: Emoji alert format
            (
                "SIGNAL ALERT\n\nSELL XAUUSD 3290.5\n\n🤑TP1: 3289.0\n🤑TP2: 3287.5\n🤑TP3: 3281.4\n🔴SL: 3298.8 (830 pips)",
                "SELL",
                "XAUUSD",
                3290.5,
                [3289.0, 3287.5, 3281.4],
                3298.8,
            ),
            # Signal 4: Colon format
            (
                "EURUSD BUY\n\nENTRY 1.1435\n\nTP: 1.1455\nTP: 1.1485\nTP: 1.1535\nSL: 1.1345",
                "BUY",
                "EURUSD",
                1.1435,
                [1.1455, 1.1485, 1.1535],
                1.1345,
            ),
            # Signal 5: Numbered TP format
            (
                "XAUUSD BUY\n\nENTRY: 3418\n\nTP1 3420\nTP2 3423\nTP3 3428\nSL 3412",
                "BUY",
                "XAUUSD",
                3418.0,
                [3420.0, 3423.0, 3428.0],
                3412.0,
            ),
            # Signal 6: Pipe format with emojis
            (
                "BTCUSD | BUY 109500\n\n❌ Stop Loss 109000 (500 pips)\n\n✅TP1 109700\n✅TP2 109900\n✅TP3 110500",
                "BUY",
                "BTCUSD",
                109500.0,
                [109700.0, 109900.0, 110500.0],
                109000.0,
            ),
            # Signal 7: Same as Signal 6
            (
                "BTCUSD | BUY 109500\n\n❌ Stop Loss 109000 (500 pips)\n\n✅TP1 109700\n✅TP2 109900\n✅TP3 110500",
                "BUY",
                "BTCUSD",
                109500.0,
                [109700.0, 109900.0, 110500.0],
                109000.0,
            ),
            # Signal 8: NEW FORMAT - Simple symbol buy price
            (
                "XAUUSD BUY 3417\n\nSL:  3411.68\nTP:  3443.68\n--Trade by Matthew",
                "BUY",
                "XAUUSD",
                3417.0,
                [3443.68],
                3411.68,
            ),
            # Signal 9: Range entry with slashed TPs format
            (
                "GOLD SELL 3334/3337\n\n3332/3330/3328/3325\n\n        SL 3345",
                "SELL",
                "XAUUSD",
                3334.0,
                [3332.0, 3330.0, 3328.0, 3325.0],
                3345.0,
            ),
            # Signal 10: NOW signal with multiple TPs (no range = immediate)
            (
                "GOLD SELL NOW\n\nTP 3307\nTP 3305\nTP 3303\nTP 3300\nTP 3298\n\nSL 3322",
                "SELL",
                "XAUUSD",
                0,
                [3307.0, 3305.0, 3303.0, 3300.0, 3298.0],
                3322.0,
            ),
            # Signal 11: Slash-separated TPs format (NEW TEST CASE)
            (
                "GOLD BUY 3330/3327\n\nTP 3332/3334/3336/3338/3340\n\nSL 3317\n\nUSE RISK MANAGEMENT",
                "BUY",
                "XAUUSD",
                3330.0,
                [3332.0, 3334.0, 3336.0, 3338.0, 3340.0],
                3317.0,
            ),
            # Signal 12: NEW - @ range format
            (
                "Sell Gold @3339-3344\n\nSl :3346\n\nTp1 :3337\nTp2 :3335\n\nEnter Slowly-Layer with proper money management\n\nDo not rush your entries",
                "SELL",
                "XAUUSD",
                3339.0,
                [3337.0, 3335.0],
                3346.0,
            ),
            # Signal 13: NEW - dash range format
            (
                "Gold Sell 3341-3346\n\nSl :3348\n\nTp1 :3339\nTp2 :3336\n\nEnter Slowly-Layer with proper money management\n\nDo not rush your entries",
                "SELL",
                "XAUUSD",
                3341.0,
                [3339.0, 3336.0],
                3348.0,
            ),
            # Signal 14: NEW - I'M SELLING with parentheses range (NOW with range should use range as entry)
            (
                "I'M SELLING XAUUSD NOW (3337 - 3340)\n\n💰TP1: 3334\n💰TP2: 3331\n\n🛑 STOP LOSS: 3343",
                "SELL",
                "XAUUSD",
                3337.0,
                [3334.0, 3331.0],
                3343.0,
            ),
            # Signal 15: NEW - Colon entry format with "open" TP
            (
                "Gold buy : 3340.5 -3338\n\nSl 3335\n\nTp 1 : 3346\nTp 2 : open",
                "BUY",
                "XAUUSD",
                3340.5,
                [3346.0, 3350.0],
                3335.0,
            ),
            # Signal 16: NEW - T.P format with numbered take profits
            (
                "BTCUSD SELL 115000\nT.P1 1146000\nT.P2 1145000\nT.P3 1144000\nT.P4 1143000\nS.L   1159000",
                "SELL",
                "BTCUSD",
                115000.0,
                [1146000.0, 1145000.0, 1144000.0, 1143000.0],
                1159000.0,
            ),
            # Signal 17: NEW - Multi-line GOLD/XAUUSD with entry range and slash-separated TPs
            (
                "XAUUSD / GOLD SELL\n 3367/3370\n\n3365/3363/3360/3357/3355\n\n\n             SL 3385",
                "SELL",
                "XAUUSD",
                3367.0,
                [3365.0, 3363.0, 3360.0, 3357.0, 3355.0],
                3385.0,
            ),
            # Signal 18: NEW - I'M SELLING with range and emoji TPs/SL (NOW with range should use range as entry)
            (
                "I'M SELLING XAUUSD NOW (3330 - 3333)\n\n💰TP1: 3327\n💰TP2: 3324\n\n🛑 STOP LOSS: 3336",
                "SELL",
                "XAUUSD",
                3330.0,
                [3327.0, 3324.0],
                3336.0,
            ),
            # Signal 19: NEW - Gold buy with range entry and only "open" TP (open-only TP = [0])
            (
                "Gold buy : 3397-3394\n\nSl 3391\nTp open",
                "BUY",
                "XAUUSD",
                3397.0,
                [0],
                3391.0,
            ),
            # Signal 20: NEW - Typographic apostrophe in I'M BUYING NOW format
            (
                "I'M BUYING XAUUSD NOW (3473.5 - 3470.5)\n\n💰TP1: 3476.5\n💰TP2: 3479.5\n\n🛑 STOP LOSS: 3467.5",
                "BUY",
                "XAUUSD",
                3473.5,
                [3476.5, 3479.5],
                3467.5,
            ),
            # Signal 21: NEW - Unicode apostrophe in I'M BUYING NOW format (user-provided example)
            (
                "I'M BUYING XAUUSD NOW (3572.5 - 3569.5)\n\n💰TP1: 3575.5\n💰TP2: 3578.5\n\n🛑 STOP LOSS: 3566.5",
                "BUY",
                "XAUUSD",
                3572.5,
                [3575.5, 3578.5],
                3566.5,
            ),
            # Signal 22: NEW - Space in slash-separated TPs (flexible spacing handling)
            (
                "GOLD BUY 3578/3575\n\n3580/3582/3585/3587/3590/ 3595 \n\n\n            SL 3565",
                "BUY",
                "XAUUSD",
                3578.0,
                [3580.0, 3582.0, 3585.0, 3587.0, 3590.0, 3595.0],
                3565.0,
            ),
            # Signal 23: NEW - Abbreviated price format (4207/04 -> 4207/4204)
            (
                "GOLD BUY 4207/04\n\nTP 4210\nTP 4213\nTP 4216\nTP 4219\nTP 4222\nTP Open\n\nSL 4199",
                "BUY",
                "XAUUSD",
                4207.0,
                [4210.0, 4213.0, 4216.0, 4219.0, 4222.0, 4226.0],
                4199.0,
            ),
            # Signal 24: NEW - Gold Sell @ range format
            (
                "Gold Sell @ 4231 - 4235\n\nSl: 4238\n\nTP1: 4228",
                "SELL",
                "XAUUSD",
                4231.0,
                [4228.0],
                4238.0,
            ),
            # Signal 25: NEW - Sell gold price @ range format with open-only TP
            (
                "Sell gold price @ 4355-4358\n\nSl 4361\nTp open",
                "SELL",
                "XAUUSD",
                4355.0,
                [0],
                4361.0,
            ),
            # Signal 26: Gold buy now with range and open TP
            (
                "Gold buy now 4017.1 - 4014\n\nSL: 4011\n\nTP: 4019\nTP: 4021\nTP: 4023\nTP: open",
                "BUY",
                "XAUUSD",
                4017.1,
                [4019.0, 4021.0, 4023.0, 4027.0],
                4011.0,
            ),
            # Signal 27: Buy Gold @4013.3-4008.3 with two TPs
            (
                "Buy Gold @4013.3-4008.3\n\nSl :4006.3\n\nTp1 :4015.3\nTp2 :40018.3",
                "BUY",
                "XAUUSD",
                4013.3,
                [4015.3, 40018.3],
                4006.3,
            ),
            # Signal 28: Hash prefixed SELL NOW with standard TPs
            (
                "#EURAUD SELL NOW\n\nTP:  1.77120\nTP:  1.76300\nTP:  1.75300\n\nSL:  1.79450",
                "SELL",
                "EURAUD",
                0,
                [1.77120, 1.76300, 1.75300],
                1.79450,
            ),
            # Signal 29: GOLD Sell Now with range and Target Profit format
            (
                "GOLD Sell Now 4086 - 4090\n\nStop loss 4092\n\nTarget Profit : 4081\nTarget Profit : 4078",
                "SELL",
                "XAUUSD",
                4086.0,
                [4081.0, 4078.0],
                4092.0,
            ),
            # Signal 30: Multi-line GOLD SELL NOW with range and numbered TPs
            (
                "GOLD SELL NOW\n4084 - 4087\n\nTP 1 4081\nTP 2 4078\nTP 3 4075\nTP 4 4070\nTP 5 4064\n\nSL 4097",
                "SELL",
                "XAUUSD",
                4084.0,
                [4081.0, 4078.0, 4075.0, 4070.0, 4064.0],
                4097.0,
            ),
            # Signal 31: GOLD BUY with range and separate TP lines
            (
                "GOLD BUY 4192/4190\n\n4195\n4197\n4200\n4202\n4205\n4210\n4215\n\nSL 4185",
                "BUY",
                "XAUUSD",
                4192.0,
                [4195.0, 4197.0, 4200.0, 4202.0, 4205.0, 4210.0, 4215.0],
                4185.0,
            ),
            # Signal 32: Hash-prefixed XAUUSD SELL with unicode dash in ENTRY
            (
                "#XAUUSD SELL\nENTRY: 4229–4232\nSL: 4239\nTP: 4226\nTP: 4223\nTP: 4220\nTP: 4217\nTP: 4214\n\nStay focused and trust the setup—precision beats speed in volatile markets.",
                "SELL",
                "XAUUSD",
                4229.0,
                [4226.0, 4223.0, 4220.0, 4217.0, 4214.0],
                4239.0,
            ),
            # Signal 33: Another GOLD BUY with range and separate TP lines
            (
                "GOLD BUY 4272/4270\n\n4275\n4277\n4280\n4282\n4285\n4290\n4295\n4300\n\nSL 4255",
                "BUY",
                "XAUUSD",
                4272.0,
                [4275.0, 4277.0, 4280.0, 4282.0, 4285.0, 4290.0, 4295.0, 4300.0],
                4255.0,
            ),
            # Signal 34: SELL FROM without symbol (should auto-detect XAUUSD from price range)
            (
                "SELL FROM 4210/4215\n\n4205/4203/4200/4198/4195/4195/4190/4185/4180\n\nSL 4225",
                "SELL",
                "XAUUSD",
                4210.0,
                [
                    4205.0,
                    4203.0,
                    4200.0,
                    4198.0,
                    4195.0,
                    4195.0,
                    4190.0,
                    4185.0,
                    4180.0,
                ],
                4225.0,
            ),
            # Signal 35: NEW - "Entered at" format
            (
                "XAUUSD buy\nEntered at 4588\nSL at 4560\nTP1 4595\nTP2 4601\nTP3 4627\nTP4 4701",
                "BUY",
                "XAUUSD",
                4588.0,
                [4595.0, 4601.0, 4627.0, 4701.0],
                4560.0,
            ),
            # Signal 36: NEW - "Enter" with "Buy now" format
            (
                "XAUUSD Buy now\nEnter 4585\nSL 4570\nTP1 4588\nTP2 4593\nTP3 4600\nTP4 4627\n\nSL entry at TP1",
                "BUY",
                "XAUUSD",
                4585.0,
                [4588.0, 4593.0, 4600.0, 4627.0],
                4570.0,
            ),
            # Signal 37: NEW - "Enter" with additional text to ignore
            (
                "XAUUSD buy now\nEnter 4582\nSL 4569\nTP1 4585\nTP2 4592\nTP3 4600\nTP4 4612\n\nHalf risk\n\nSL entry at TP1",
                "BUY",
                "XAUUSD",
                4582.0,
                [4585.0, 4592.0, 4600.0, 4612.0],
                4569.0,
            ),
            # Signal 38: NEW - SL with parentheses (ignore numbers in parentheses)
            (
                "XAUUSD buy now\nEnter 4590\nSL 4575 (150)\nTP1 4595\nTP2 4601\nTP3 4617\nTP4 4625\n\nHalf risk\n\nFor those looking to hold a bit longer into a swinger TP5 4701",
                "BUY",
                "XAUUSD",
                4590.0,
                [4595.0, 4601.0, 4617.0, 4625.0, 4701.0],
                4575.0,
            ),
            # Signal 39: NEW - USDJPY SELL format with "Enter"
            (
                "Usdjpy sell now\nEnter 157.630\nSL 158.630\nTP1 157.400\nTp2 157.130\nTp3 156.130\nTP4 152.130\n\nHalf risk\n\nThis is a very risk swing\n\nSL entry at TP1",
                "SELL",
                "USDJPY",
                157.630,
                [157.400, 157.130, 156.130, 152.130],
                158.630,
            ),
            # Signal 40: NEW - "Buy here around" format
            (
                "XAUUSD Buy here around 4485\nSL 4467\nTP1 4490\nTP2 4497\nTP3 4503\nTP4 4517",
                "BUY",
                "XAUUSD",
                4485.0,
                [4490.0, 4497.0, 4503.0, 4517.0],
                4467.0,
            ),
            # Signal 41: NEW - "Enter" format with additional ignored text
            (
                "XAUUSD Buy now\nEnter 4468\nSL 4457\nTP1 4471\nTP2 4474\nTP3 4480\nTP4 4490\n\nSL entry TP1\n\nNFP day so go half risk",
                "BUY",
                "XAUUSD",
                4468.0,
                [4471.0, 4474.0, 4480.0, 4490.0],
                4457.0,
            ),
            # Signal 42: NEW - BTC/USDT format with dollar signs and Target pattern
            (
                "BTC/USDT SELL NOW ✅\n\nEntry : $ 95033\n\nTarget1: $ 94800\nTarget2: $94300\n\nSL : $ 95300",
                "SELL",
                "BTCUSD",
                95033.0,
                [94800.0, 94300.0],
                95300.0,
            ),
            # Signal 43: NEW - XAUUSD format with decimal entry and spaced TP format
            (
                "XAUUSD BUY 4597.015\n\nTP 1 : 4604\nTP 2 : 4621\n\nSL : 4589.697",
                "BUY",
                "XAUUSD",
                4597.015,
                [4604.0, 4621.0],
                4589.697,
            ),
            # Signal 44: NEW - "I've entered" format with explicit entry and multiple TPs
            (
                "I'm trying something out on a 5k side account I set up to have some fun on…\n\nI've entered a gold buy at 4778 with SL 4725 and a TP 4800 and TP 4825\n\nI'm sharing as it could be something I introduce in future and not an official call to enter. This is YVM live trading.",
                "BUY",
                "XAUUSD",
                4778.0,
                [4800.0, 4825.0],
                4725.0,
            ),
            # Signal 45: NEW - 📣XAUUSD BUY NOW 📣 format with LEVEL entry and TP1-5
            (
                "📣XAUUSD BUY NOW 📣\n\n🔊LEVEL :2653\n\n✅TP1 : 2655 (+20 PIPS)\n\n✅TP2 2657 (+40 PIPS)\n\n✅TP3 : 2659 (+60 PIPS)\n\n✅TP4 : 2661 (+80 PIPS)\n\n✅TP5 : 2663 (+100 PIPS)\n\n❌SL: 2649 ( 40pips )\n\n🔷Take only 2% risk",
                "BUY",
                "XAUUSD",
                2653.0,
                [2655.0, 2657.0, 2659.0, 2661.0, 2663.0],
                2649.0,
            ),
            # Signal 46: NEW - XAUUSD BUY NOW format with Entry/SL/TP1-3
            (
                "XAUUSD BUY NOW\n\nEntry: 4388\nSL: 4384\nTP1: 4390\nTP2: 4392\nTP3: 4398\n\nWe recommend a max of 1% risk per trade",
                "BUY",
                "XAUUSD",
                4388.0,
                [4390.0, 4392.0, 4398.0],
                4384.0,
            ),
            # Signal 47: NEW - BTCUSD BUY NOW format with Entry/SL/TP1-3
            (
                "BTCUSD BUY NOW\n\nEntry: 90600\nSL: 90100\nTP1: 90850\nTP2: 91200\nTP3: 92000",
                "BUY",
                "BTCUSD",
                90600.0,
                [90850.0, 91200.0, 92000.0],
                90100.0,
            ),
            # Signal 48: NEW - GOLD BUY with multiple TP/SL using dots
            (
                "GOLD BUY 5218\n\nTP. 5220\nTP. 5222\nTP. 5224\nTP. 5226\nTP. 5228\nTP. 5230\n\nSL. 5208",
                "BUY",
                "XAUUSD",
                5218.0,
                [5220.0, 5222.0, 5224.0, 5226.0, 5228.0, 5230.0],
                5208.0,
            ),
            # Signal 49: NEW - GOLD BUY with multiple TP/SL using spaces (no dots)
            (
                "GOLD BUY 5218\n\nTP 5220\nTP 5222\nTP 5224\nTP 5226\nTP 5228\nTP 5230\n\nSL 5208",
                "BUY",
                "XAUUSD",
                5218.0,
                [5220.0, 5222.0, 5224.0, 5226.0, 5228.0, 5230.0],
                5208.0,
            ),
            # Signal 50: NEW - ♾GOLD BUY NOW @ price format with TP/SL and /OPEN ignore
            (
                "♾GOLD BUY NOW @ 4484.8\n\n💰TP 1: 4486.3\n💰TP 2: 4487.8\n💰TP 3: 4490.8/OPEN\n\n🚨SL: 4379.8",
                "BUY",
                "XAUUSD",
                4484.8,
                [4486.3, 4487.8, 4490.8],
                4379.8,
            ),
            # Signal 51: NEW - 🔽GOLD SELL format with direct entry price and multiple TPs
            (
                "🔽GOLD SELL 4766.00\n\n✅TP1 4763\n✅TP2 4756\n✅TP3 4750\n✅TP4 4745\n✅TP5 4740\n✅TP6 4736\n✅TP7 4730\n✅TP8 4700\n❌SL   4780",
                "SELL",
                "XAUUSD",
                4766.0,
                [4763.0, 4756.0, 4750.0, 4745.0, 4740.0, 4736.0, 4730.0, 4700.0],
                4780.0,
            ),
            # Signal 52: NEW - "XAUUSD: BUY NOW" colon-after-symbol format with separate ENTRY line
            (
                "XAUUSD: BUY NOW\n\nENTRY: 5338\nSL: 5333\nTP1: 5342\nTP2: 5345\nTP3: 5350\n\nWe recommend a max of 1% risk per trade",
                "BUY",
                "XAUUSD",
                5338.0,
                [5342.0, 5345.0, 5350.0],
                5333.0,
            ),
            # Signal 53: NEW - "GOLD BUY NOW @ price" with "Stop Loss (SL):" format and "/Open" TP suffix
            (
                "GOLD BUY NOW @ 5394.8\nStop Loss (SL): 5389.8\nTP1: 5396.3\nTP2: 5397.8\nTP3:  5400.8/ Open",
                "BUY",
                "XAUUSD",
                5394.8,
                [5396.3, 5397.8, 5400.8],
                5389.8,
            ),
            # Signal 54: NEW - "GOLD SELL NOW @ price Stop Loss (SL): sl" on one line, TPs on separate lines
            (
                "GOLD SELL NOW @ 5393.3 Stop Loss (SL): 5398.3\n\nTP1: 5391.8\nTP2: 5390.3\nTP3: 5387.3/ Open",
                "SELL",
                "XAUUSD",
                5393.3,
                [5391.8, 5390.3, 5387.3],
                5398.3,
            ),
            # Signal 55: NEW - ENTRY with + range separator (5360+5350, BUY uses higher)
            (
                "XAUUSD BUY\n\nENTRY 5360+5350\n\nSL 5340\n\nTP 5365\nTP 5370\nTP 5375\nTP 5380\nTP 5385",
                "BUY",
                "XAUUSD",
                5360.0,
                [5365.0, 5370.0, 5375.0, 5380.0, 5385.0],
                5340.0,
            ),
        ]

        for i, (
            signal_text,
            expected_type,
            expected_symbol,
            expected_entry,
            expected_tps,
            expected_sl,
        ) in enumerate(signals, 1):
            with self.subTest(signal=i):
                result = parse_signal(signal_text)
                self.assertIsNotNone(result, f"Signal {i} should parse successfully")
                self.assertEqual(
                    result.signal_type, expected_type, f"Signal {i} type mismatch"
                )
                self.assertEqual(
                    result.symbol, expected_symbol, f"Signal {i} symbol mismatch"
                )
                self.assertEqual(
                    result.entry, expected_entry, f"Signal {i} entry mismatch"
                )
                self.assertIsNotNone(
                    result.take_profits, f"Signal {i} take_profits should not be None"
                )
                self.assertIsNotNone(
                    result.stop_loss, f"Signal {i} stop_loss should not be None"
                )
                self.assertGreater(
                    len(result.take_profits), 0, f"Signal {i} should have take_profits"
                )
                self.assertEqual(
                    result.take_profits,
                    expected_tps,
                    f"Signal {i} take_profits mismatch",
                )
                self.assertEqual(
                    result.stop_loss, expected_sl, f"Signal {i} stop_loss mismatch"
                )

                # Note: Open-only TP signals have take_profits = [0] which is now valid

        print("✅ All 55 user-provided signal formats passed!")

    def test_invisible_characters(self):
        """Test signal parsing with invisible/hidden characters like non-breaking spaces, zero-width spaces, etc."""

        # Test signal with various invisible characters at the beginning
        test_signals = [
            # Non-breaking space (U+00A0) at the beginning
            (
                "\u00a0GOLD BUY 4323/4320\n\n4325\n4327\n4330\n4332\n4335\n4340\n4345\n4350\n\nSL 4310",
                "BUY",
                "XAUUSD",
                4323.0,
                [4325.0, 4327.0, 4330.0, 4332.0, 4335.0, 4340.0, 4345.0, 4350.0],
                4310.0,
            ),
            # Zero-width space (U+200B) at the beginning
            (
                "\u200bGOLD BUY 4323/4320\n\n4325\n4327\n4330\n4332\n4335\n4340\n4345\n4350\n\nSL 4310",
                "BUY",
                "XAUUSD",
                4323.0,
                [4325.0, 4327.0, 4330.0, 4332.0, 4335.0, 4340.0, 4345.0, 4350.0],
                4310.0,
            ),
            # Zero-width non-joiner (U+200C) at the beginning
            (
                "\u200cGOLD BUY 4323/4320\n\n4325\n4327\n4330\n4332\n4335\n4340\n4345\n4350\n\nSL 4310",
                "BUY",
                "XAUUSD",
                4323.0,
                [4325.0, 4327.0, 4330.0, 4332.0, 4335.0, 4340.0, 4345.0, 4350.0],
                4310.0,
            ),
            # Multiple invisible characters combined
            (
                "\u00a0\u200b\u200cGOLD BUY 4323/4320\n\n4325\n4327\n4330\n4332\n4335\n4340\n4345\n4350\n\nSL 4310",
                "BUY",
                "XAUUSD",
                4323.0,
                [4325.0, 4327.0, 4330.0, 4332.0, 4335.0, 4340.0, 4345.0, 4350.0],
                4310.0,
            ),
            # Invisible characters within the text with Markdown characters
            (
                "**GOLD\u00a0BUY\u200b4323/4320\n\n4325\n4327\n4330\n4332\n4335\n4340\n4345\n4350\n\nSL 4310**",
                "BUY",
                "XAUUSD",
                4323.0,
                [4325.0, 4327.0, 4330.0, 4332.0, 4335.0, 4340.0, 4345.0, 4350.0],
                4310.0,
            ),
        ]

        for i, (
            signal_text,
            expected_type,
            expected_symbol,
            expected_entry,
            expected_tps,
            expected_sl,
        ) in enumerate(test_signals, 1):
            print(f"Testing invisible characters signal {i}...")
            result = parse_signal(signal_text)

            self.assertIsNotNone(
                result, f"Invisible char signal {i} should parse successfully"
            )
            self.assertEqual(
                result.signal_type,
                expected_type,
                f"Invisible char signal {i} type mismatch",
            )
            self.assertEqual(
                result.symbol,
                expected_symbol,
                f"Invisible char signal {i} symbol mismatch",
            )
            self.assertEqual(
                result.entry,
                expected_entry,
                f"Invisible char signal {i} entry mismatch",
            )
            self.assertEqual(
                result.take_profits,
                expected_tps,
                f"Invisible char signal {i} take_profits mismatch",
            )
            self.assertEqual(
                result.stop_loss,
                expected_sl,
                f"Invisible char signal {i} stop_loss mismatch",
            )

        print("✅ All invisible character signals passed!")


if __name__ == "__main__":
    unittest.main(verbosity=2)
