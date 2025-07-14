#!/usr/bin/env python3
# Comprehensive test for the new slash-separated TP format and all existing functionality

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from signal_parser import parse_signal

def test_new_slash_tp_format():
    """Test the new slash-separated TP format"""
    print("=== Testing New Slash-Separated TP Format ===")
    
    # The exact format from the user's request
    test_signal = """GOLD SELL 3334/3337

3332/3330/3328/3325

        SL 3345"""
    
    print("Testing user's exact format:")
    print(repr(test_signal))
    result = parse_signal(test_signal)
    
    if result:
        print("✅ Successfully parsed!")
        print(f"   Signal Type: {result.get('signal_type')}")
        print(f"   Symbol: {result.get('symbol')}")
        print(f"   Entry: {result.get('entry')} (should be 3337 for SELL)")
        print(f"   Take Profits: {result.get('take_profits')}")
        print(f"   Stop Loss: {result.get('stop_loss')}")
        
        # Validate specific requirements
        if result.get('signal_type') == 'SELL' and result.get('symbol') == 'XAUUSD':
            print("   ✅ Signal type and symbol correct")
        else:
            print("   ❌ Signal type or symbol incorrect")
            
        if result.get('entry') == 3337:
            print("   ✅ Entry price correct (higher value for SELL)")
        else:
            print(f"   ❌ Entry price should be 3337, got {result.get('entry')}")
            
        expected_tps = [3332.0, 3330.0, 3328.0, 3325.0]
        if result.get('take_profits') == expected_tps:
            print("   ✅ Take profits correct and properly sorted for SELL")
        else:
            print(f"   ❌ Take profits incorrect. Expected {expected_tps}, got {result.get('take_profits')}")
            
        if result.get('stop_loss') == 3345.0:
            print("   ✅ Stop loss correct")
        else:
            print(f"   ❌ Stop loss incorrect. Expected 3345.0, got {result.get('stop_loss')}")
    else:
        print("❌ Failed to parse")
    
    # Test BUY variant
    print("\n--- Testing BUY variant ---")
    buy_signal = """GOLD BUY 3334/3337

3340/3342/3345/3348

        SL 3330"""
    
    result_buy = parse_signal(buy_signal)
    if result_buy:
        print("✅ BUY variant parsed successfully")
        print(f"   Entry: {result_buy.get('entry')} (should be 3334 for BUY - lower value)")
        print(f"   TPs: {result_buy.get('take_profits')} (should be ascending for BUY)")
        
        if result_buy.get('entry') == 3334:
            print("   ✅ BUY entry correct (lower value)")
        else:
            print(f"   ❌ BUY entry should be 3334, got {result_buy.get('entry')}")
    else:
        print("❌ BUY variant failed to parse")

def test_all_existing_formats():
    """Test all existing formats to ensure nothing is broken"""
    print("\n=== Testing All Existing Formats ===")
    
    test_cases = [
        # Multi-line traditional format
        {
            "name": "Multi-line traditional",
            "signal": """BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Stop loss at 88600.00""",
            "expected_entry": 89300.0
        },
        
        # Single line with range
        {
            "name": "Single line with range",
            "signal": "SELL GOLD 2670/2675 TP1: 2650 TP2: 2640 SL: 2685",
            "expected_entry": 2675.0  # Higher for SELL
        },
        
        # FROM format
        {
            "name": "FROM format", 
            "signal": "GOLD SELL FROM 3313/3315.3 TP1: 3289.0 TP2: 3282.5 SL: 3329.5",
            "expected_entry": 3315.3  # Higher for SELL
        },
        
        # Pipe format
        {
            "name": "Pipe format",
            "signal": "BTCUSD | BUY 109500 ❌ Stop Loss 109000 ✅TP1 109700",
            "expected_entry": 109500.0
        },
        
        # Symbol first format with range
        {
            "name": "Symbol first with range",
            "signal": "XAUUSD BUY 3410/3417 TP1: 3420 TP2: 3423 SL: 3405",
            "expected_entry": 3410.0  # Lower for BUY
        },
        
        # NOW signal - should override entry to 0
        {
            "name": "NOW signal",
            "signal": "GOLD SELL NOW TP1: 2650 TP2: 2645 SL: 2665",
            "expected_entry": 0
        },
        
        # NOW signal with range (should still be 0)
        {
            "name": "NOW signal with range",
            "signal": "BUY XAUUSD 2660/2665 NOW TP: 2670 SL: 2650",
            "expected_entry": 0
        }
    ]
    
    for i, test_case in enumerate(test_cases, 1):
        print(f"\n{i}. {test_case['name']}:")
        result = parse_signal(test_case['signal'])
        
        if result:
            actual_entry = result.get('entry')
            expected_entry = test_case['expected_entry']
            
            if actual_entry == expected_entry:
                print(f"   ✅ Entry correct: {actual_entry}")
            else:
                print(f"   ❌ Entry incorrect. Expected {expected_entry}, got {actual_entry}")
                
            print(f"   Type: {result.get('signal_type')}, Symbol: {result.get('symbol')}")
            print(f"   TPs: {len(result.get('take_profits', []))}, SL: {result.get('stop_loss')}")
        else:
            print("   ❌ Failed to parse")

def test_edge_cases():
    """Test edge cases and potential issues"""
    print("\n=== Testing Edge Cases ===")
    
    edge_cases = [
        # Mixed formats
        "GOLD SELL 3334/3337\nTP1: 3332 TP2: 3330\n3328/3325\nSL 3345",
        
        # Empty lines and spacing
        """GOLD SELL 3334/3337

        3332/3330/3328/3325
        
        SL 3345
        """,
        
        # Single TP in slash format
        "GOLD BUY 3334/3337\n3340\nSL 3330",
        
        # Range with more than 2 values in entry
        "GOLD SELL 3334/3337/3340\n3332/3330\nSL 3345",
        
        # Invalid slash format
        "GOLD SELL 3334/\n3332/3330\nSL 3345"
    ]
    
    for i, test_case in enumerate(edge_cases, 1):
        print(f"\nEdge Case {i}:")
        print(f"Input: {repr(test_case[:50])}...")
        result = parse_signal(test_case)
        
        if result:
            print(f"✅ Parsed: Entry={result.get('entry')}, TPs={len(result.get('take_profits', []))}")
        else:
            print("❌ Failed to parse (may be expected for invalid cases)")

if __name__ == "__main__":
    test_new_slash_tp_format()
    test_all_existing_formats()
    test_edge_cases()
    print("\n=== All Tests Complete ===")
