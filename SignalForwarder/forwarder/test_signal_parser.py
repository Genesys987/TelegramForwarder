import unittest
from signal_parser import parse_signal


class TestSignalParser(unittest.TestCase):
    
    def test_parse_signal_buy_format_complete(self):
        """Test parsing a complete BUY signal with all required fields"""
        signal_text = """
        BUY BTCUSD
        ENTRY 89300.00
        Take profit 1 at 89500.00
        Take profit 2 at 89800.00
        Take profit 3 at 90300.00
        Stop loss at 88600.00
        """
        
        result = parse_signal(signal_text)
        
        # Test that parsing succeeded
        self.assertIsNotNone(result)
        
        # Test all expected keys are present
        expected_keys = {"signal_type", "symbol", "entry", "take_profits", "stop_loss"}
        self.assertEqual(set(result.keys()), expected_keys)
        
        # Test values
        self.assertEqual(result["signal_type"], "BUY")
        self.assertEqual(result["symbol"], "BTCUSD")
        self.assertEqual(result["entry"], 89300.00)
        self.assertEqual(result["take_profits"], [89500.00, 89800.00, 90300.00])
        self.assertEqual(result["stop_loss"], 88600.00)
    
    def test_parse_signal_empty_input(self):
        """Test parsing empty or None input"""
        self.assertIsNone(parse_signal(""))
    
    def test_parse_signal_gold_sell_format(self):
        """Test parsing GOLD SELL signal with entry range and multiple TPs"""
        signal_text = """
        GOLD SELL FROM 3313/3315.3
        
        TP 3310
        TP 3308
        TP 3305
        TP 3303
        TP 3300
        SL 3323
        """
        
        result = parse_signal(signal_text)
        
        # Test that parsing succeeded
        self.assertIsNotNone(result)
        
        # Test all expected keys are present
        expected_keys = {"signal_type", "symbol", "entry", "take_profits", "stop_loss"}
        self.assertEqual(set(result.keys()), expected_keys)
        
        # Test values
        self.assertEqual(result["signal_type"], "SELL")
        self.assertEqual(result["symbol"], "XAUUSD")  # GOLD maps to XAUUSD
        self.assertEqual(result["entry"], 3315.3)  # because it's a SELL, we take the higher of the range
        self.assertEqual(result["take_profits"], [3310, 3308, 3305, 3303, 3300])
        self.assertEqual(result["stop_loss"], 3323)

    def test_parse_signal_sell_xauusd_with_emojis(self):
        """Test parsing SELL XAUUSD signal with emoji prefixes"""
        signal_text = """
        SIGNAL ALERT

        SELL XAUUSD 3290.5

        🤑TP1: 3289.0
        🤑TP2: 3287.5
        🤑TP3: 3281.4
        🔴SL: 3298.8 (830 pips)
        """
        
        result = parse_signal(signal_text)
        
        # Test that parsing succeeded
        self.assertIsNotNone(result)
        
        # Test all expected keys are present
        expected_keys = {"signal_type", "symbol", "entry", "take_profits", "stop_loss"}
        self.assertEqual(set(result.keys()), expected_keys)
        
        # Test values
        self.assertEqual(result["signal_type"], "SELL")
        self.assertEqual(result["symbol"], "XAUUSD")
        self.assertEqual(result["entry"], 3290.5)
        self.assertEqual(result["take_profits"], [3289.0, 3287.5, 3281.4])  # Sorted descending for SELL
        self.assertEqual(result["stop_loss"], 3298.8)

    def test_parse_signal_buy_chfjpy_with_emojis(self):
        """Test parsing BUY CHFJPY signal with emoji prefixes"""
        signal_text = """
        SIGNAL ALERT

        BUY CHFJPY 180.430

        🤑 TP1 180.580
        🤑 TP2 180.730
        🤑 TP3 180.950
        🛑 SL 179.930 (50 PIPS)
        """
        
        result = parse_signal(signal_text)
        
        # Test that parsing succeeded
        self.assertIsNotNone(result)
        
        # Test all expected keys are present
        expected_keys = {"signal_type", "symbol", "entry", "take_profits", "stop_loss"}
        self.assertEqual(set(result.keys()), expected_keys)
        
        # Test values
        self.assertEqual(result["signal_type"], "BUY")
        self.assertEqual(result["symbol"], "CHFJPY")
        self.assertEqual(result["entry"], 180.430)
        self.assertEqual(result["take_profits"], [180.580, 180.730, 180.950])  # Sorted ascending for BUY
        self.assertEqual(result["stop_loss"], 179.930)

if __name__ == '__main__':
    # Run just one test first to debug
    test = TestSignalParser()
    try:
        test.test_parse_signal_sell_xauusd_with_emojis()
        print("SELL XAUUSD test passed!")
    except Exception as e:
        print(f"SELL XAUUSD test failed: {e}")
    
    try:
        test.test_parse_signal_buy_chfjpy_with_emojis()
        print("BUY CHFJPY test passed!")
    except Exception as e:
        print(f"BUY CHFJPY test failed: {e}")
    
    # Now run all tests
    unittest.main()
