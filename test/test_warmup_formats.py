import pytest
from warmup_signals import is_warmup_message, generate_warmup_signal
from signal_data import SignalData
from config import WARMUP_SIGNAL_CHANNEL


class TestWarmupSignalFormats:
    """Test all warmup signal formats to ensure proper recognition and signal generation."""

    def test_original_buy_patterns(self):
        """Test original BUY warmup patterns."""
        buy_patterns = [
            "I'm buying now",
            "Im buying now!",
            "ready buy",
            "ready buy now!",
            "Mid risk let's scalping buy gold slowly",
            "HIGH risk let's scalping buy gold slowly",
            "ANOTHER GOLD BUY READY"
        ]
        
        for pattern in buy_patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == "BUY", f"Pattern '{pattern}' should be BUY signal"
            assert price is None, f"Price should be None for warmup signals"

    def test_original_sell_patterns(self):
        """Test original SELL warmup patterns."""
        sell_patterns = [
            "I'm selling now",
            "Im selling now!",
            "Let's scalping sell gold slowly mid risk",
            "ready sell",
            "ready sell now!",
            "Double sell ready",
            "GOLD SELL READY"
        ]
        
        for pattern in sell_patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == "SELL", f"Pattern '{pattern}' should be SELL signal"
            assert price is None, f"Price should be None for warmup signals"

    def test_new_simple_buy_patterns(self):
        """Test new simple BUY warmup patterns."""
        buy_patterns = [
            "Gold buy now",
            "Gold buy now!",
            "Buy gold now scalping!",
            "Gold re-entry buy now",
            "Standby Gold buy"
        ]
        
        for pattern in buy_patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == "BUY", f"Pattern '{pattern}' should be BUY signal"
            assert price is None, f"Price should be None for warmup signals"

    def test_new_simple_sell_patterns(self):
        """Test new simple SELL warmup patterns."""
        sell_patterns = [
            "Gold sell now",
            "Sell gold now scalping!"
        ]
        
        for pattern in sell_patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == "SELL", f"Pattern '{pattern}' should be SELL signal"
            assert price is None, f"Price should be None for warmup signals"

    def test_new_complex_buy_patterns(self):
        """Test new complex BUY warmup patterns with risk levels and scalping annotations."""
        buy_patterns = [
            "HIGH risk let's scalping buy gold slowly",
            "Lets scalping buy gold slowly HIGH risk",
            "Lets scalping buy gold slowly mid risk\n\n(scalping)",
            "Lets scalping buy gold slowly mid risk\n\n(scalping",
            "Lets scalping buy gold slowly HIGH risk\n\n-scalping",
            "Lets scalping buy gold slowly high risk\n\n(scalping)",
            "Lets scalping buy gold slowly\n\n-scalping",
            "Lets scalping buy gold slowly mid risk\n\n(scalping",
            "Lets scalping buy gold slowly HIGH risk\n\n(scalping",
            "Let's re-enter scalping buy gold small lot high risk",  # Assuming this is BUY context
            "Lets scalping buy gold slowly\n\n(scalping"
        ]
        
        for pattern in buy_patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == "BUY", f"Pattern '{pattern}' should be BUY signal"
            assert price is None, f"Price should be None for warmup signals"

    def test_new_complex_sell_patterns(self):
        """Test new complex SELL warmup patterns with risk levels and scalping annotations."""
        sell_patterns = [
            "HIGH risk let's scalping sell gold slowly",
            "Lets scalping sell gold slowly HIGH risk",
            "Lets scalping sell gold slowly mid risk\n\n(scalping)",
            "Lets scalping sell gold slowly mid risk\n\n(scalping",
            "Lets scalping sell gold slowly HIGH risk\n\n-scalping",
            "Lets scalping sell gold slowly high risk\n\n(scalping)",
            "Lets scalping sell gold slowly\n\n-scalping",
            "Lets scalping sell gold slowly mid risk\n\n(scalping",
            "Lets scalping sell gold slowly HIGH risk\n\n(scalping",
            "Let's re-enter scalping sell gold small lot high risk",
            "Lets scalping sell gold slowly\n\n(scalping"
        ]
        
        for pattern in sell_patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == "SELL", f"Pattern '{pattern}' should be SELL signal"
            assert price is None, f"Price should be None for warmup signals"

    def test_case_insensitive_matching(self):
        """Test that warmup patterns work with different cases."""
        patterns = [
            ("gold buy now", "BUY"),
            ("GOLD BUY NOW", "BUY"), 
            ("Gold Buy Now", "BUY"),
            ("gold sell now", "SELL"),
            ("GOLD SELL NOW", "SELL"),
            ("Gold Sell Now", "SELL"),
            ("HIGH RISK LET'S SCALPING BUY GOLD SLOWLY", "BUY"),
            ("high risk let's scalping sell gold slowly", "SELL")
        ]
        
        for pattern, expected_type in patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == expected_type, f"Pattern '{pattern}' should be {expected_type} signal"

    def test_non_warmup_messages(self):
        """Test that non-warmup messages are not recognized."""
        non_warmup_patterns = [
            "BUY XAUUSD ENTRY 2600",
            "SELL GOLD FROM 2650",
            "TP1: 2700",
            "SL: 2500",
            "Random message",
            "Gold price is rising",
            "Market analysis shows...",
            "Gold analysis",
            "Buy signal coming soon",
            "Sell ready later"
        ]
        
        for pattern in non_warmup_patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert not is_ready, f"Pattern '{pattern}' should NOT be recognized as warmup"
            assert signal_type is None, f"Signal type should be None for non-warmup pattern '{pattern}'"

    def test_generate_warmup_buy_signal(self):
        """Test generation of BUY warmup signal."""
        signal = generate_warmup_signal("BUY")
        
        assert isinstance(signal, SignalData)
        assert signal.signal_type == "BUY"
        assert signal.symbol == "XAUUSD"
        assert signal.entry == 0
        assert signal.take_profits == [0, 0]
        assert signal.stop_loss == 0
        assert signal.channel_name == WARMUP_SIGNAL_CHANNEL
        assert signal.is_warmup == True

    def test_generate_warmup_sell_signal(self):
        """Test generation of SELL warmup signal."""
        signal = generate_warmup_signal("SELL")
        
        assert isinstance(signal, SignalData)
        assert signal.signal_type == "SELL"
        assert signal.symbol == "XAUUSD"
        assert signal.entry == 0
        assert signal.take_profits == [0, 0]
        assert signal.stop_loss == 0
        assert signal.channel_name == WARMUP_SIGNAL_CHANNEL
        assert signal.is_warmup == True

    def test_warmup_signal_validation(self):
        """Test that generated warmup signals are valid."""
        buy_signal = generate_warmup_signal("BUY")
        sell_signal = generate_warmup_signal("SELL")
        
        assert buy_signal.is_valid()
        assert sell_signal.is_valid()

    def test_full_warmup_workflow_buy(self):
        """Test complete workflow from message recognition to signal generation for BUY."""
        message = "Gold buy now"
        
        # Step 1: Recognize warmup message
        is_ready, signal_type, price = is_warmup_message(message)
        assert is_ready
        assert signal_type == "BUY"
        assert price is None
        
        # Step 2: Generate warmup signal
        signal = generate_warmup_signal(signal_type)
        assert signal.signal_type == "BUY"
        assert signal.is_warmup == True
        assert signal.is_valid()

    def test_full_warmup_workflow_sell(self):
        """Test complete workflow from message recognition to signal generation for SELL."""
        message = "Lets scalping sell gold slowly HIGH risk"
        
        # Step 1: Recognize warmup message
        is_ready, signal_type, price = is_warmup_message(message)
        assert is_ready
        assert signal_type == "SELL"
        assert price is None
        
        # Step 2: Generate warmup signal
        signal = generate_warmup_signal(signal_type)
        assert signal.signal_type == "SELL"
        assert signal.is_warmup == True
        assert signal.is_valid()

    def test_edge_cases_with_punctuation(self):
        """Test edge cases with various punctuation."""
        patterns = [
            ("Gold buy now!", "BUY"),
            ("Gold sell now.", "SELL"),
            ("Lets scalping buy gold slowly HIGH risk!", "BUY"),
            ("HIGH risk let's scalping sell gold slowly.", "SELL")
        ]
        
        for pattern, expected_type in patterns:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == expected_type, f"Pattern '{pattern}' should be {expected_type} signal"

    def test_patterns_with_newlines_and_annotations(self):
        """Test patterns that include newlines and annotations like (scalping) or -scalping."""
        patterns_with_annotations = [
            ("Lets scalping buy gold slowly mid risk\n\n(scalping)", "BUY"),
            ("Lets scalping sell gold slowly HIGH risk\n\n-scalping", "SELL"),
            ("Lets scalping buy gold slowly\n\n-scalping", "BUY"),
            ("Lets scalping sell gold slowly\n\n(scalping", "SELL")
        ]
        
        for pattern, expected_type in patterns_with_annotations:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == expected_type, f"Pattern '{pattern}' should be {expected_type} signal"

    def test_all_provided_new_formats(self):
        """Test all the specifically provided new formats from the user request."""
        new_formats = [
            ("Gold buy now", "BUY"),
            ("Gold sell now", "SELL"),
            ("HIGH risk let's scalping buy gold slowly", "BUY"),
            ("HIGH risk let's scalping sell gold slowly", "SELL"),
            ("Lets scalping sell gold slowly HIGH risk", "SELL"),
            ("Lets scalping buy gold slowly HIGH risk", "BUY"),
            ("Sell gold now scalping!", "SELL"),
            ("Buy gold now scalping!", "BUY"),
            ("Lets scalping sell gold slowly mid risk\n\n(scalping)", "SELL"),
            ("Lets scalping buy gold slowly mid risk\n\n(scalping", "BUY"),
            ("Lets scalping sell gold slowly HIGH risk\n\n-scalping", "SELL"),
            ("Lets scalping buy gold slowly HIGH risk\n\n-scalping", "BUY"),
            ("Lets scalping sell gold slowly high risk\n\n(scalping)", "SELL"),
            ("Lets scalping buy gold slowly high risk\n\n(scalping)", "BUY"),
            ("Gold re-entry buy now", "BUY"),
            ("Lets scalping sell gold slowly\n\n-scalping", "SELL"),
            ("Lets scalping buy gold slowly\n\n-scalping", "BUY"),
            ("Lets scalping sell gold slowly mid risk\n\n(scalping", "SELL"),
            ("Lets scalping sell gold slowly HIGH risk\n\n(scalping", "SELL"),
            ("Lets scalping buy gold slowly HIGH risk\n\n(scalping", "BUY"),
            ("Let's re-enter scalping sell gold small lot high risk", "SELL"),
            ("Gold buy now!", "BUY"),
            ("Standby Gold buy", "BUY"),
            ("Lets scalping sell gold slowly\n\n(scalping", "SELL"),
            ("Lets scalping buy gold slowly\n\n(scalping", "BUY")
        ]
        
        for pattern, expected_type in new_formats:
            is_ready, signal_type, price = is_warmup_message(pattern)
            assert is_ready, f"Pattern '{pattern}' should be recognized as warmup"
            assert signal_type == expected_type, f"Pattern '{pattern}' should be {expected_type} signal, got {signal_type}"
            assert price is None, f"Price should be None for warmup signals"


if __name__ == "__main__":
    pytest.main([__file__])
