#!/usr/bin/env python3
# Test script to verify signal parsing logic

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from signal_parser import parse_signal

def test_immediate_entry_signals():
    """Test immediate entry (NOW) signals"""
    print("=== Testing Immediate Entry Signals ===")
    
    test_cases = [
        "GOLD SELL NOW TP1: 2650 TP2: 2645 SL: 2665",
        "🚨 XAUUSD BUY NOW 🚨 TP 2670 SL 2655",
        "BUY GOLD NOW TP1: 2675 TP2: 2680 SL: 2660",
        "SELL XAUUSD NOW TP: 2640 SL: 2670"
    ]
    
    for i, test_case in enumerate(test_cases, 1):
        print(f"\nTest {i}: {test_case}")
        result = parse_signal(test_case)
        if result:
            print(f"✅ Parsed successfully:")
            print(f"   Signal Type: {result.get('signal_type')}")
            print(f"   Symbol: {result.get('symbol')}")
            print(f"   Entry: {result.get('entry')} (should be 0 for NOW signals)")
            print(f"   TPs: {result.get('take_profits')}")
            print(f"   SL: {result.get('stop_loss')}")
            
            # Verify entry is 0 for NOW signals
            if result.get('entry') == 0:
                print("   ✅ Entry correctly set to 0 for immediate entry")
            else:
                print("   ❌ Entry should be 0 for immediate entry")
        else:
            print("❌ Failed to parse")

def test_regular_signals():
    """Test regular signals to ensure they still work"""
    print("\n=== Testing Regular Signals ===")
    
    test_cases = [
        "BUY XAUUSD 2660 TP1: 2665 TP2: 2670 SL: 2655",
        "SELL GOLD 2670 TP: 2650 SL: 2680",
        """BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Stop loss at 88600.00""",
        "XAUUSD | BUY 2660 ✅TP1 2665 ❌Stop Loss 2655"
    ]
    
    for i, test_case in enumerate(test_cases, 1):
        print(f"\nTest {i}: {test_case[:50]}...")
        result = parse_signal(test_case)
        if result:
            print(f"✅ Parsed successfully:")
            print(f"   Signal Type: {result.get('signal_type')}")
            print(f"   Symbol: {result.get('symbol')}")
            print(f"   Entry: {result.get('entry')} (should NOT be 0 for regular signals)")
            print(f"   TPs: {result.get('take_profits')}")
            print(f"   SL: {result.get('stop_loss')}")
            
            # Verify entry is not 0 for regular signals
            if result.get('entry') != 0 and result.get('entry') is not None:
                print("   ✅ Entry correctly preserved for regular signal")
            else:
                print("   ❌ Entry should not be 0 for regular signal")
        else:
            print("❌ Failed to parse")

def test_edge_cases():
    """Test edge cases"""
    print("\n=== Testing Edge Cases ===")
    
    test_cases = [
        # Signal with NOW but also has entry price - should override to 0
        "BUY XAUUSD 2660 NOW TP: 2670 SL: 2650",
        # Signal without NOW - should keep normal entry
        "SELL GOLD 2670 TP: 2650 SL: 2680",
        # Empty/invalid signals
        "",
        "NOW",
        "GOLD NOW"
    ]
    
    for i, test_case in enumerate(test_cases, 1):
        print(f"\nEdge Test {i}: '{test_case}'")
        result = parse_signal(test_case)
        if result:
            print(f"✅ Parsed: Entry={result.get('entry')}, Type={result.get('signal_type')}")
            if 'NOW' in test_case.upper() and result.get('signal_type'):
                if result.get('entry') == 0:
                    print("   ✅ NOW signal correctly set entry to 0")
                else:
                    print("   ❌ NOW signal should have entry = 0")
        else:
            print("❌ Failed to parse (expected for invalid signals)")

if __name__ == "__main__":
    test_immediate_entry_signals()
    test_regular_signals() 
    test_edge_cases()
    print("\n=== Test Complete ===")
