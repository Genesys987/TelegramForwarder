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

if __name__ == '__main__':
    unittest.main()
