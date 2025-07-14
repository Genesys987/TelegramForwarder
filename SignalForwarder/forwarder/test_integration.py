#!/usr/bin/env python3
# Test integration with signal processor

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from signal_parser import parse_signal

def test_integration():
    """Test integration flow to simulate the full pipeline"""
    
    test_signals = [
        # Original problem signal
        """GOLD SELL 3334/3337

3332/3330/3328/3325

        SL 3345""",
        
        # BUY variant
        """GOLD BUY 3334/3337

3340/3342/3345/3348

        SL 3330""",
        
        # NOW signal (should still work)
        "GOLD SELL NOW TP1: 2650 TP2: 2645 SL: 2665",
        
        # Traditional format (should still work)
        """BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Stop loss at 88600.00"""
    ]
    
    print("=== Testing Signal Integration ===")
    
    for i, signal_text in enumerate(test_signals, 1):
        print(f"\n--- Test Signal {i} ---")
        print(f"Input: {signal_text.split()[0:4]}...")  # First few words
        
        # Parse signal
        parsed = parse_signal(signal_text)
        
        if parsed:
            print("✅ Parsing: SUCCESS")
            
            # Simulate what signal_processor.py does
            signal_type = parsed["signal_type"]
            symbol = parsed["symbol"]
            entry_price = parsed["entry"]
            take_profits = parsed["take_profits"]
            stop_loss = parsed["stop_loss"]
            
            # Create signal_data like signal_processor.py
            signal_data = {
                "signal_type": signal_type,
                "symbol": symbol,
                "entry": entry_price,
                "take_profits": take_profits,
                "stop_loss": stop_loss,
            }
            
            print(f"✅ Signal Data: {signal_data}")
            
            # Validate that all required fields are present
            required_fields = ["signal_type", "symbol", "entry", "take_profits", "stop_loss"]
            all_present = all(field in signal_data and signal_data[field] is not None for field in required_fields)
            
            if all_present and len(take_profits) > 0:
                print("✅ Validation: PASS - Ready for queue")
            else:
                print("❌ Validation: FAIL - Missing required data")
                
        else:
            print("❌ Parsing: FAILED")

if __name__ == "__main__":
    test_integration()
