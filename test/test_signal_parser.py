#!/usr/bin/env python3
"""
Simple test suite for the signal parser - tests all 72 user-provided signal formats
"""

import unittest
import sys
import os

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from signal_parser import parse_signal


class TestSignalParser(unittest.TestCase):
    def test_all_72_user_signals(self):
        """Test all 81 signal formats provided by the user including new formats with unicode dashes and hash prefixes"""

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
                "BTCUSD | BUY 109500\n\n❌ Stop Loss 109000 (500 pips)\n\nTP1 109700\nTP2 109900\nTP3 110500",
                "BUY",
                "BTCUSD",
                109500.0,
                [109700.0, 109900.0, 110500.0],
                109000.0,
            ),
            # Signal 7: Same as Signal 6
            (
                "BTCUSD | BUY 109500\n\n❌ Stop Loss 109000 (500 pips)\n\nTP1 109700\nTP2 109900\nTP3 110500",
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
                "BTC/USDT SELL NOW\n\nEntry : $ 95033\n\nTarget1: $ 94800\nTarget2: $94300\n\nSL : $ 95300",
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
                "📣XAUUSD BUY NOW 📣\n\n🔊LEVEL :2653\n\nTP1 : 2655 (+20 PIPS)\n\nTP2 2657 (+40 PIPS)\n\nTP3 : 2659 (+60 PIPS)\n\nTP4 : 2661 (+80 PIPS)\n\nTP5 : 2663 (+100 PIPS)\n\n❌SL: 2649 ( 40pips )\n\n🔷Take only 2% risk",
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
                "🔽GOLD SELL 4766.00\n\nTP1 4763\nTP2 4756\nTP3 4750\nTP4 4745\nTP5 4740\nTP6 4736\nTP7 4730\nTP8 4700\n❌SL   4780",
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
            # Signal 56: Format 1 - emoji prefix + GOLD BUY NOW @ price, Stop Loss (SL): sl, TP.. entries
            (
                "\U0001f4ca GOLD BUY NOW @ 5189.2\n\u26a0\ufe0f Stop Loss (SL): 5182.2\nTP1: 5192.2\nTP2: 5195.2\nTP3: 5199.2/ Open",
                "BUY",
                "XAUUSD",
                5189.2,
                [5192.2, 5195.2, 5199.2],
                5182.2,
            ),
            # Signal 57: Format 2 - USDCHF BUY @ price, TP with parenthetical labels, SL:
            (
                "USDCHF BUY @ 0.7775\nTP: 0.7795 (scalper)\nTP: 0.7825 (intraday)\nTP: 0.7875 (swing)\nSL: 0.7707",
                "BUY",
                "USDCHF",
                0.7775,
                [0.7795, 0.7825, 0.7875],
                0.7707,
            ),
            # Signal 58: Format 3a - SELL SYMBOL NOW price, SL.. and TP.. double-dot patterns
            (
                "SELL GBPUSD NOW 1.3417\nSL..1.3487\nTP..1.3350\nTP..1.3253",
                "SELL",
                "GBPUSD",
                1.3417,
                [1.3350, 1.3253],
                1.3487,
            ),
            # Signal 59: Format 3b - SELL SYMBOL price, SL.. and TP.. double-dot
            (
                "SELL XAUUSD 5194\nSL..5212\nTP..5167\nTP..5125",
                "SELL",
                "XAUUSD",
                5194.0,
                [5167.0, 5125.0],
                5212.0,
            ),
            # Signal 60: Format 3c - SELL SYMBOL range__ separator, SL.. TP.. double-dot
            (
                "SELL XAUUSD 5185 __ 5196\nSL..5210\nTP..5156\nTP..5092",
                "SELL",
                "XAUUSD",
                5185.0,
                [5156.0, 5092.0],
                5210.0,
            ),
            # Signal 61: Format 4 - emoji symbol line (XAU/USD), Direction: BUY, Entry Price:
            (
                "\U0001f514XAU/USD\U0001f514\n\nDirection: BUY\nEntry Price: 5180.00\n\nTP1 5185.00\nTP2 5190.00\nTP3 5200.00\n\nSL 5160.00",
                "BUY",
                "XAUUSD",
                5180.0,
                [5185.0, 5190.0, 5200.0],
                5160.0,
            ),
            # Signal 62: Format 5a - emoji GOLD SELL @ range
            (
                "\U0001f534 GOLD SELL @ 5199-5204\n\nSL: 5207\n\nTP: 5196\nTP: 5179",
                "SELL",
                "XAUUSD",
                5199.0,
                [5196.0, 5179.0],
                5207.0,
            ),
            # Signal 63: Format 5b - emoji GOLD BUY @ range
            (
                "\U0001f535 GOLD BUY @ 5185-5180\n\nSL: 5177\n\nTP: 5188\nTP: 5205",
                "BUY",
                "XAUUSD",
                5185.0,
                [5188.0, 5205.0],
                5177.0,
            ),
            # Signal 64: Format 6 - XAUUSD SELL now at price
            (
                "XAUUSD SELL now at 5214\nSL 5227\nTP 5160",
                "SELL",
                "XAUUSD",
                5214.0,
                [5160.0],
                5227.0,
            ),
            # Signal 65: Format 7 - symbol-only first line, then BUY price, TPs, SL
            (
                "NZDUSD\n\nBUY 0.5938\n\nTP 0.5958\nTP 0.5988\nTP 0.6030\nSL 0.5868",
                "BUY",
                "NZDUSD",
                0.5938,
                [0.5958, 0.5988, 0.6030],
                0.5868,
            ),
            # Signal 66: Format 8 - emoji SELL SYMBOL (@ price) with Take profit N at TP
            (
                "\U0001f534SELL \U0001f4c9 GBPUSD (@ 1.3366)\nTake profit 1\u27a1\ufe0fat 1.3335\nTake profit 2\u27a1\ufe0fat 1.3280\nTake profit 3\u27a1\ufe0fat 1.3235\nStop loss at 1.3431\n\nSignal chance of success: 87%",
                "SELL",
                "GBPUSD",
                1.3366,
                [1.3335, 1.3280, 1.3235],
                1.3431,
            ),
            # Signal 67: Format 9 - heavily emoji-wrapped XAUUSD SELL, ENTRY: sl, TP:
            (
                "\U0001f525\U0001f43bXAUUSD SELL\U0001f43b\U0001f525\n\U0001f530ENTRY: 5190.08\nSL: 5202.00\nTP: 5170.00\n\nCopyright \u00a9 reserved from Metabear",
                "SELL",
                "XAUUSD",
                5190.08,
                [5170.0],
                5202.0,
            ),
            # Signal 68: Format 10 - NEW TRADE IDEA preamble, XAUUSD SELL price, TP N, SL @
            (
                "NEW TRADE IDEA\n\nXAUUSD SELL 5156\n\nTP 1 5153\nTP 2 5152\nTP 3 5151\nTP 4 5120\n\nSL @ 5190\n\nProfits are NOT guarenteed...",
                "SELL",
                "XAUUSD",
                5156.0,
                [5153.0, 5152.0, 5151.0, 5120.0],
                5190.0,
            ),
            # Signal 69: Format 11 - GOLD BUY + MORE BUY, superscript TP numbers, SL_
            (
                "GOLD BUY 5151\nMORE BUY 5148\n\nTP\u00b9 5154\nTP\u00b2 5157\nTP\u00b3 5160\nTP\u2074 5163\nTP\u2075 5166\nTP\u2076 5169\n\nSL_5140",
                "BUY",
                "XAUUSD",
                5151.0,
                [5154.0, 5157.0, 5160.0, 5163.0, 5166.0, 5169.0],
                5140.0,
            ),
            # Signal 70: Format 12a - Sell SYMBOL, Entry -, Stop -, Take -
            (
                "#GBPCHF: trade idea\n\U0001f534Sell GBPCHF\n\U0001f518Entry - 1.0468\n\U0001f7e3Stop - 1.0475\n\U0001f7e1Take - 1.0456\n\nRisk 1% only",
                "SELL",
                "GBPCHF",
                1.0468,
                [1.0456],
                1.0475,
            ),
            # Signal 71: Format 12b - Long SYMBOL, Entry Point -, Stop Loss -, Take Profit -
            (
                "\U0001f534Long NZDUSD\n\U0001f518Entry Point - 0.5912\n\U0001f7e3Stop Loss - 0.5902\n\U0001f7e1Take Profit - 0.5931\n\nRisk 1% only",
                "BUY",
                "NZDUSD",
                0.5912,
                [0.5931],
                0.5902,
            ),
            # Signal 72: Format 12c - Buy GOLD, Entry Level -, Sl -, Tp -
            (
                "\U0001f534Buy GOLD\n\U0001f518Entry Level - 5191.4\n\U0001f7e3Sl - 5182.4\n\U0001f7e1Tp - 5206.0\n\nManage your risk",
                "BUY",
                "XAUUSD",
                5191.4,
                [5206.0],
                5182.4,
            ),
            # Signal 73: "SYMBOL Free Signal!" header + standalone "⭕Sell!" + green-circle SL/TP/Entry
            (
                "\U0001f4c9EUR-USD Free Signal!\n\n\u2b55Sell!\n\u2014\n#EURUSD taps into a supply area after a liquidity sweep and shows rejection, signaling smart money distribution. Bearish continuation expected toward the imbalance below as downside pressure builds.\n\U0001f7e2Stop Loss: 1.1755\n\U0001f7e2Take Profit: 1.1697\n\U0001f7e2Entry: 1.1732\n\U0001f7e2Time Frame: 5H",
                "SELL",
                "EURUSD",
                1.1732,
                [1.1697],
                1.1755,
            ),
            # Signal 74: NEW - #XAUUSD standalone hash-prefixed symbol + "Trade Details:#BUY" + "Entry Point:" + "Take Profit N (TPN):"
            (
                "🚨 SIGNAL ALERT 🚨\n\n🌐 #XAUUSD\n\n📊 Trade Details:📈#BUY\n\n⚪️ Entry Point: 4698\n🔴 Stop Loss (SL): 4689\n\n🟢 Take Profit 1 (TP1): 4701\n🟢 Take Profit 2 (TP2): 4706\n🟢 Take Profit 3 (TP3): 4714\n\n⚠️ Keep in mind to not risk more then 1-2% of your balance on this trade\n\n• Sent via TeleFeed (http://t.me/tg_feedbot?start=atid-DBZDQBFREE)",
                "BUY",
                "XAUUSD",
                4698.0,
                [4701.0, 4706.0, 4714.0],
                4689.0,
            ),
            # Signal 75: NEW - BUY with hash-prefixed symbols "Buy #XAUUSD #GOLD price-range"
            (
                "Buy #XAUUSD #GOLD 4703-4797\n\nSL 4691\n\nTP 4705\nTP 4707\nTP 4711\nTP 4715\nTP 4723\n\nFollow Proper Money Management ‼️",
                "BUY",
                "XAUUSD",
                4797.0,
                [4705.0, 4707.0, 4711.0, 4715.0, 4723.0],
                4691.0,
            ),
            # Signal 76: NEW - Simple SYMBOL BUY price with SL/TP (US30)
            (
                "Today's free signal\n\nUS30 BUY 49560.2\n\nSL: 49450.2\nTP: 49860.2\nUpgrade now www.fxpremiere.com",
                "BUY",
                "US30",
                49560.2,
                [49860.2],
                49450.2,
            ),
            # Signal 77: NEW - AUDCAD BUY simple format
            (
                "AUDCAD BUY 0.986\n\nSL: 0.981\nTP: 1.001",
                "BUY",
                "AUDCAD",
                0.986,
                [1.001],
                0.981,
            ),
            # Signal 78: NEW - GOLD buy Now with Zone: entry format
            (
                "🥇 GOLD buy🔥 Now\n📊Zone:4703-4701\n❌SL:4698\nTP1:4713\nTP2:4720\n\nUSE PROPER MONEY MANAGEMENT",
                "BUY",
                "XAUUSD",
                4703.0,
                [4713.0, 4720.0],
                4698.0,
            ),
            # Signal 79: NEW - SIGNAL ALERT header, SELL XAUUSD price, emoji TP/SL
            (
                "SIGNAL ALERT\n\nSELL XAUUSD 4706.2\n\n🤑TP1: 4704.2\n🤑TP2: 4701.2\n🤑TP3: 4692.2\n🔴SL: 4720.2 (1400 pips)",
                "SELL",
                "XAUUSD",
                4706.2,
                [4704.2, 4701.2, 4692.2],
                4720.2,
            ),
            # Signal 80: NEW - "Buy EURUSD at any price between X till Y" range format with "Target N:" TPs
            (
                "🔼Forex Signal\n\nBuy EURUSD at any price between 1.1748 till 1.1720\n\n📊 EURUSD Analysis - EURUSD is rebounding from the higher low area of the Ascending Channel\n\nTarget 1: 1.1795\n\nTarget 2: 1.1865\n\nTarget 3: 1.1940\n\nTarget 4: 1.2040\n\nStop loss: 1.1660",
                "BUY",
                "EURUSD",
                1.1748,
                [1.1795, 1.1865, 1.194, 1.204],
                1.166,
            ),
            # Signal 81: NEW - SELL POSITION SYMBOL format with OPEN: entry range
            (
                "SELL POSITION XAUUSD\U0001f6a8\n\nOPEN : 4134-4136\nSL : 4139\nTP1 : 4128\nTP2 : 4120\nTP3 : 4112\nTP4 : 4065",
                "SELL",
                "XAUUSD",
                4134.0,
                [4128.0, 4120.0, 4112.0, 4065.0],
                4139.0,
            ),
            # Signal 82: NEW - ✅ used decoratively inline with buy action and as ✅TP prefix
            (
                "\U0001f947 GOLD buy\U0001f525 \u2705 Now\n\U0001f4ca Zone:4703-4701\n\u274cSL:4698\n\u2705TP1:4713\n\u2705TP2:4720",
                "BUY",
                "XAUUSD",
                4703.0,
                [4713.0, 4720.0],
                4698.0,
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

        print("✅ All 82 user-provided signal formats passed!")

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

    def test_limit_order_signal_types(self):
        """Limit-order entry lines should map SELL/BUY to SELLLIMIT/BUYLIMIT."""
        sell_signal_text = """NQ – SELL

        • Entry: 1.0870 – 1.0880 (limit sell zone)
        • SL: 1.0915
        • TP1: 1.0830
        • TP2: 1.0785
        • TP3: 1.0740"""

        result = parse_signal(sell_signal_text)

        self.assertIsNotNone(result)
        self.assertEqual(result.symbol, "NAS100")
        self.assertEqual(result.signal_type, "SELLLIMIT")
        self.assertEqual(result.entry, 1.0870)

        buy_signal_text = """NQ – BUY

        • Entry: 1.0870 – 1.0880 (limit buy zone)
        • SL: 1.0915
        • TP1: 1.0830
        • TP2: 1.0785
        • TP3: 1.0740"""

        result = parse_signal(buy_signal_text)

        self.assertIsNotNone(result)
        self.assertEqual(result.symbol, "NAS100")
        self.assertEqual(result.signal_type, "BUYLIMIT")
        self.assertEqual(result.entry, 1.0870)

    def test_new_signal_formats(self):
        """Test new signal formats from user specification (signals 1-10)."""

        cases = [
            # Signal 1: High risk prefix + standalone range entry
            (
                "High risk xauusd buy\n4034-4030\nSl 4024\nTp-s;\n4040\n4050\n4060\n4070",
                "BUY", "XAUUSD", 4034.0, [4040.0, 4050.0, 4060.0, 4070.0], 4024.0,
            ),
            # Signal 2: Standalone SELL + "High risk PRICE" entry line + explicit SL
            (
                "XAUUSD SELL\nHigh risk 4018-4021.5\nSl 4015\nTps:\n4011\n4000\n3970\n3950",
                "SELL", "XAUUSD", 4018.0, [4011.0, 4000.0, 3970.0, 3950.0], 4015.0,
            ),
            # Signal 3: "Very high risk" preamble line – ignored before actual signal
            (
                "Very high risk (1/4 of normal lotsize)\n\nXauusd sell 4042-4046\nSl 4055\nTps:\n4037\n4030\n4020\n4010\n4000",
                "SELL", "XAUUSD", 4042.0, [4037.0, 4030.0, 4020.0, 4010.0, 4000.0], 4055.0,
            ),
            # Signal 4: Multiple preamble lines + "Tps-" separator
            (
                "Leaving us with current position of:\nHigh risk:\nXauusd sell 4034-4036\nSl 4046\nTps-\n4026\n4020\n4010\n4000",
                "SELL", "XAUUSD", 4034.0, [4026.0, 4020.0, 4010.0, 4000.0], 4046.0,
            ),
            # Signal 5: SYMBOL ACTION on line 1, standalone range on line 2, "Tp-s;" separator
            (
                "Nas100 sell\n29505-29525\nSl 29569\nTp-s;\n29469\n29429\n29399\n29359",
                "SELL", "NAS100", 29505.0, [29469.0, 29429.0, 29399.0, 29359.0], 29569.0,
            ),
            # Signal 6: Inline price + "Tp-s:" separator
            (
                "Nas100 sell 29655\nSl 29705\nTp-s:\n29580\n29560\n29520",
                "SELL", "NAS100", 29655.0, [29580.0, 29560.0, 29520.0], 29705.0,
            ),
            # Signal 7: "High risk SYMBOL BUY price" format + "Tps:" separator
            (
                "High risk nas100 buy 29040\nSl: 28888\nTps:\n29100\n29270\n29400\n29666",
                "BUY", "NAS100", 29040.0, [29100.0, 29270.0, 29400.0, 29666.0], 28888.0,
            ),
            # Signal 8: "Tp-s:" followed by explicit TP1:/TP2:/TP3: labels
            (
                "Nas100 sell 29655\nSl 29705\nTp-s:\nTP1: 29580\nTP2: 29560\nTP3: 29520",
                "SELL", "NAS100", 29655.0, [29580.0, 29560.0, 29520.0], 29705.0,
            ),
            # Signal 9: "SYMBOL sell limit" → SELLLIMIT with standalone range entry
            (
                "High risk;\n\nNas100 sell limit\n29630-29660\n\nSl 29720\n\nTP-s\n29605\n29587\n29566\n29544",
                "SELLLIMIT", "NAS100", 29630.0, [29605.0, 29587.0, 29566.0, 29544.0], 29720.0,
            ),
            # Signal 10: "SYMBOL Sell Limit" → SELLLIMIT; "Sl entry at X" line is ignored
            (
                "Very high risk:\nXauUsd Sell Limit\n4058-4066\nSl 4072\nSl entry at 4055.5\nTp-s:\n4054\n4048\n4042\n4034",
                "SELLLIMIT", "XAUUSD", 4058.0, [4054.0, 4048.0, 4042.0, 4034.0], 4072.0,
            ),
        ]

        for i, (text, exp_type, exp_symbol, exp_entry, exp_tps, exp_sl) in enumerate(cases, 1):
            with self.subTest(signal=i):
                result = parse_signal(text)
                self.assertIsNotNone(result, f"New signal {i} should parse")
                self.assertEqual(result.signal_type, exp_type, f"Signal {i} type")
                self.assertEqual(result.symbol, exp_symbol, f"Signal {i} symbol")
                self.assertEqual(result.entry, exp_entry, f"Signal {i} entry")
                self.assertEqual(result.take_profits, exp_tps, f"Signal {i} TPs")
                self.assertEqual(result.stop_loss, exp_sl, f"Signal {i} SL")

        print("✅ All 10 new signal formats passed!")


if __name__ == "__main__":
    unittest.main(verbosity=2)
