#!/usr/bin/env python3
# Extended test to verify all existing functionality still works

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from signal_parser import parse_signal

def test_existing_functionality():
    """Test all existing signal formats to ensure nothing is broken"""
    print("=== Testing All Existing Signal Formats ===")
    
    test_cases = [
        # Multi-line format
        """BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Take profit 3 at 90300.00
Stop loss at 88600.00""",
        
        # Pipe format
        "BTCUSD | BUY 109500 ❌ Stop Loss 109000 ✅TP1 109700",
        
        # FROM format
        "GOLD SELL FROM 3313/3315.3 TP1: 3289.0 TP2: 3282.5 SL: 3329.5",
        
        # Symbol first format
        "XAUUSD BUY 3417 TP1: 3420 TP2: 3423 SL: 3413",
        
        # Regular single line
        "BUY EURUSD 1.1455 TP: 1.1465 SL: 1.1445",
        
        # Range entry format
        "SELL GOLD 2670/2675 TP1: 2650 TP2: 2640 SL: 2685",
        
        # Multiple TP format
        "BUY XAUUSD 2660 TP1: 2665 TP2: 2670 TP3: 2675 SL: 2655"
    ]
    
    for i, test_case in enumerate(test_cases, 1):
        print(f"\nExisting Format Test {i}:")
        print(f"Input: {test_case[:60]}...")
        result = parse_signal(test_case)
        if result:
            print(f"✅ SUCCESS - Type: {result.get('signal_type')}, "
                  f"Symbol: {result.get('symbol')}, "
                  f"Entry: {result.get('entry')}, "
                  f"TPs: {len(result.get('take_profits', []))}, "
                  f"SL: {result.get('stop_loss')}")
            
            # Verify it's not a 0 entry (since none of these should be immediate)
            if result.get('entry') != 0:
                print("   ✅ Entry preserved correctly (not immediate signal)")
            else:
                print("   ❌ ERROR: Entry should not be 0 for regular signal!")
        else:
            print("❌ FAILED - Signal parsing incomplete")

def test_comprehensive_now_signals():
    """Test various NOW signal formats"""
    print("\n=== Comprehensive NOW Signal Testing ===")
    
    now_cases = [
        "GOLD SELL NOW TP1: 2650 TP2: 2645 SL: 2665",
        "🚨 XAUUSD BUY NOW 🚨 TP 2670 SL 2655", 
        "BUY GOLD NOW TP1: 2675 TP2: 2680 SL: 2660",
        "SELL XAUUSD NOW TP: 2640 SL: 2670",
        "EURUSD NOW SELL TP: 1.1445 SL: 1.1465",
        "NOW BUY BTCUSD TP: 91000 SL: 89000",  # This might not work - edge case
        "BUY XAUUSD 2660 NOW TP: 2670 SL: 2650"  # Entry price + NOW
    ]
    
    for i, test_case in enumerate(now_cases, 1):
        print(f"\nNOW Test {i}: {test_case}")
        result = parse_signal(test_case)
        if result:
            is_correct = result.get('entry') == 0
            print(f"✅ Entry: {result.get('entry')} {'✅' if is_correct else '❌'}")
            print(f"   Type: {result.get('signal_type')}, Symbol: {result.get('symbol')}")
            print(f"   TPs: {result.get('take_profits')}, SL: {result.get('stop_loss')}")
        else:
            print("❌ Failed to parse")

if __name__ == "__main__":
    test_existing_functionality()
    test_comprehensive_now_signals()
    print("\n=== All Tests Complete ===")
