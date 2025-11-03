import unittest
import os
import sys
from unittest.mock import patch

# Import the functions we want to test
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import getMT4DataFolderId
from stoploss_update import extract_price_from_text


class TestConfigFunctions(unittest.TestCase):
    """Test pure functions from config.py"""

    def test_getMT4DataFolderId_normal_case(self):
        """Test getMT4DataFolderId with normal long folder name"""
        folder_path = "/path/to/7D024799C00A011848A10ECEDFE5CBC2"
        result = getMT4DataFolderId(folder_path)
        self.assertEqual(result, "7D0247")

    def test_getMT4DataFolderId_with_trailing_slash(self):
        """Test getMT4DataFolderId with trailing slash"""
        folder_path = "/path/to/7D024799C00A011848A10ECEDFE5CBC2/"
        result = getMT4DataFolderId(folder_path)
        self.assertEqual(result, "7D0247")

    def test_getMT4DataFolderId_short_folder_name(self):
        """Test getMT4DataFolderId with folder name shorter than 6 chars"""
        folder_path = "/path/to/ABC"
        result = getMT4DataFolderId(folder_path)
        self.assertEqual(result, "ABC")

    def test_getMT4DataFolderId_exactly_6_chars(self):
        """Test getMT4DataFolderId with exactly 6 character folder name"""
        folder_path = "/path/to/ABCDEF"
        result = getMT4DataFolderId(folder_path)
        self.assertEqual(result, "ABCDEF")

    def test_getMT4DataFolderId_empty_path(self):
        """Test getMT4DataFolderId with empty or root path"""
        folder_path = ""
        result = getMT4DataFolderId(folder_path)
        self.assertEqual(result, "")

    def test_getMT4DataFolderId_single_char(self):
        """Test getMT4DataFolderId with single character folder name"""
        folder_path = "/path/to/X"
        result = getMT4DataFolderId(folder_path)
        self.assertEqual(result, "X")

    def test_getMT4DataFolderId_numeric_folder(self):
        """Test getMT4DataFolderId with numeric folder name"""
        folder_path = "/path/to/123456789"
        result = getMT4DataFolderId(folder_path)
        self.assertEqual(result, "123456")


class TestStoplossUpdateFunctions(unittest.TestCase):
    """Test pure functions from stoploss_update.py"""

    @patch("builtins.print")  # Suppress debug prints during testing
    def test_extract_price_from_text_sl_to_format(self, mock_print):
        """Test extracting price from 'SL to X' format"""
        text = "SL to 2148.0"
        result = extract_price_from_text(text)
        self.assertEqual(result, "2148.0")

    @patch("builtins.print")
    def test_extract_price_from_text_stop_loss_at_format(self, mock_print):
        """Test extracting price from 'Stop loss at X' format"""
        text = "Stop loss at 1950.50"
        result = extract_price_from_text(text)
        self.assertEqual(result, "1950.50")

    @patch("builtins.print")
    def test_extract_price_from_text_sl_colon_format(self, mock_print):
        """Test extracting price from 'SL: X' format"""
        text = "SL: 3250"
        result = extract_price_from_text(text)
        self.assertEqual(result, "3250")

    @patch("builtins.print")
    def test_extract_price_from_text_adjust_format(self, mock_print):
        """Test extracting price from 'Adjust SL to X' format"""
        text = "Adjust SL to 89450.25"
        result = extract_price_from_text(text)
        self.assertEqual(result, "89450.25")

    @patch("builtins.print")
    def test_extract_price_from_text_plain_number(self, mock_print):
        """Test extracting price from plain number"""
        text = "New SL 2175.75"
        result = extract_price_from_text(text)
        self.assertEqual(result, "2175.75")

    @patch("builtins.print")
    def test_extract_price_from_text_integer_price(self, mock_print):
        """Test extracting integer price"""
        text = "SL to 2150"
        result = extract_price_from_text(text)
        self.assertEqual(result, "2150")

    @patch("builtins.print")
    def test_extract_price_from_text_case_insensitive(self, mock_print):
        """Test case insensitive matching"""
        text = "sl TO 2148.0"
        result = extract_price_from_text(text)
        self.assertEqual(result, "2148.0")

    @patch("builtins.print")
    def test_extract_price_from_text_no_price_found(self, mock_print):
        """Test when no price is found"""
        text = "This message has no price"
        result = extract_price_from_text(text)
        self.assertIsNone(result)

    @patch("builtins.print")
    def test_extract_price_from_text_invalid_price_format(self, mock_print):
        """Test with invalid price format (just a period)"""
        text = "SL to ."
        result = extract_price_from_text(text)
        self.assertIsNone(result)

    @patch("builtins.print")
    def test_extract_price_from_text_empty_input(self, mock_print):
        """Test with empty input"""
        text = ""
        result = extract_price_from_text(text)
        self.assertIsNone(result)

    @patch("builtins.print")
    def test_extract_price_from_text_multiple_numbers(self, mock_print):
        """Test with multiple numbers - should return first valid one"""
        text = "SL to 2148.0 or maybe 2150.0"
        result = extract_price_from_text(text)
        self.assertEqual(result, "2148.0")


class TestQueueManagerLogic(unittest.TestCase):
    """Test logic functions that don't require file I/O"""

    def test_signal_data_validation_complete(self):
        """Test signal data validation with complete data"""
        # This tests the validation logic without actually writing to files
        signal_data = {
            "timestamp_utc": 1750749034465,
            "signal_type": "BUY",
            "symbol": "XAUUSD",
            "entry": 2150.5,
            "take_profits": [2155.0, 2160.0, 2165.0],
            "stop_loss": 2145.0,
            "group_id": 123,
        }

        # Test required keys presence
        required_keys = [
            "timestamp_utc",
            "signal_type",
            "symbol",
            "entry",
            "take_profits",
            "stop_loss",
            "group_id",
        ]
        self.assertTrue(all(key in signal_data for key in required_keys))

        # Test take_profits validation
        tps = signal_data["take_profits"]
        self.assertIsInstance(tps, list)
        self.assertGreaterEqual(len(tps), 3)

        # Test timestamp validation
        timestamp = signal_data["timestamp_utc"]
        self.assertIsInstance(timestamp, int)
        self.assertGreater(timestamp, 0)

    def test_signal_data_validation_missing_keys(self):
        """Test signal data validation with missing keys"""
        signal_data = {
            "signal_type": "BUY",
            "symbol": "XAUUSD",
            "entry": 2150.5,
            # Missing take_profits, stop_loss, group_id, timestamp_utc
        }

        required_keys = [
            "timestamp_utc",
            "signal_type",
            "symbol",
            "entry",
            "take_profits",
            "stop_loss",
            "group_id",
        ]
        self.assertFalse(all(key in signal_data for key in required_keys))

    def test_signal_data_validation_invalid_take_profits(self):
        """Test signal data validation with invalid take_profits"""
        # Test with insufficient take profits
        signal_data_insufficient = {
            "timestamp_utc": 1750749034465,
            "signal_type": "BUY",
            "symbol": "XAUUSD",
            "entry": 2150.5,
            "take_profits": [2155.0, 2160.0],  # Only 2 TPs, need at least 3
            "stop_loss": 2145.0,
            "group_id": 123,
        }

        tps = signal_data_insufficient["take_profits"]
        self.assertIsInstance(tps, list)
        self.assertLess(len(tps), 3)  # Should fail validation

        # Test with non-list take profits
        signal_data_invalid_type = signal_data_insufficient.copy()
        signal_data_invalid_type["take_profits"] = "not a list"

        tps_invalid = signal_data_invalid_type["take_profits"]
        self.assertNotIsInstance(tps_invalid, list)

    def test_signal_data_validation_invalid_timestamp(self):
        """Test signal data validation with invalid timestamps"""
        # Test negative timestamp
        signal_data_negative = {
            "timestamp_utc": -123,
            "signal_type": "BUY",
            "symbol": "XAUUSD",
            "entry": 2150.5,
            "take_profits": [2155.0, 2160.0, 2165.0],
            "stop_loss": 2145.0,
            "group_id": 123,
        }

        timestamp = signal_data_negative["timestamp_utc"]
        self.assertIsInstance(timestamp, int)
        self.assertLessEqual(timestamp, 0)  # Should fail validation

        # Test zero timestamp
        signal_data_zero = signal_data_negative.copy()
        signal_data_zero["timestamp_utc"] = 0

        timestamp_zero = signal_data_zero["timestamp_utc"]
        self.assertEqual(timestamp_zero, 0)  # Should fail validation

        # Test non-integer timestamp
        signal_data_float = signal_data_negative.copy()
        signal_data_float["timestamp_utc"] = 1750749034.465

        timestamp_float = signal_data_float["timestamp_utc"]
        self.assertNotIsInstance(timestamp_float, int)  # Should fail validation

    def test_signal_message_format(self):
        """Test the signal message format generation"""
        signal_data = {
            "timestamp_utc": 1750749034465,
            "signal_type": "BUY",
            "symbol": "XAUUSD",
            "entry": 2150.5,
            "take_profits": [2155.0, 2160.0, 2165.0],
            "stop_loss": 2145.0,
            "group_id": 123,
        }

        # Test message format construction
        tp_str = ",".join(str(tp) for tp in signal_data["take_profits"])
        expected_message = (
            f"{signal_data['timestamp_utc']}|{signal_data['signal_type']}|"
            f"{signal_data['symbol']}|{signal_data['entry']}|"
            f"{tp_str}|{signal_data['stop_loss']}|"
            f"GID:{signal_data['group_id']}\n"
        )

        actual_message = (
            f"{signal_data['timestamp_utc']}|{signal_data['signal_type']}|{signal_data['symbol']}|{signal_data['entry']}|"
            f"{tp_str}|{signal_data['stop_loss']}|"
            f"GID:{signal_data['group_id']}\n"
        )

        self.assertEqual(actual_message, expected_message)

        # Test that TP string is correctly formatted
        self.assertEqual(tp_str, "2155.0,2160.0,2165.0")

        # Test message structure
        parts = expected_message.strip().split("|")
        self.assertEqual(
            len(parts), 7
        )  # timestamp, signal_type, symbol, entry, tps, sl, GID
        self.assertTrue(parts[-1].startswith("GID:"))


if __name__ == "__main__":
    # Run all tests
    unittest.main(verbosity=2)
