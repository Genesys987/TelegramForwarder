#!/usr/bin/env python3
# Test the exact original signal that was failing

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from signal_parser import parse_signal

def test_original_problem():
    """Test the exact signal that was causing the original error"""
    
    original_signal = """GOLD SELL 3334/3337

3332/3330/3328/3325

        SL 3345"""
    
    print("=== Testing Original Problem Signal ===")
    print("Signal text:")
    print(repr(original_signal))
    print("\nParsing...")
    
    result = parse_signal(original_signal)
    
    if result:
        print("✅ SUCCESS! Signal parsed correctly")
        print(f"Signal Type: {result.get('signal_type')}")
        print(f"Symbol: {result.get('symbol')}")
        print(f"Entry: {result.get('entry')}")
        print(f"Take Profits: {result.get('take_profits')}")
        print(f"Stop Loss: {result.get('stop_loss')}")
        
        # Verify all requirements
        checks = []
        checks.append(("Signal Type is SELL", result.get('signal_type') == 'SELL'))
        checks.append(("Symbol is XAUUSD (GOLD mapped)", result.get('symbol') == 'XAUUSD'))
        checks.append(("Entry is 3337 (higher for SELL)", result.get('entry') == 3337.0))
        checks.append(("Has 4 take profits", len(result.get('take_profits', [])) == 4))
        checks.append(("TPs correctly sorted for SELL", result.get('take_profits') == [3332.0, 3330.0, 3328.0, 3325.0]))
        checks.append(("Stop Loss is 3345", result.get('stop_loss') == 3345.0))
        
        print("\n--- Validation Checks ---")
        all_passed = True
        for check_name, passed in checks:
            status = "✅" if passed else "❌"
            print(f"{status} {check_name}")
            if not passed:
                all_passed = False
        
        if all_passed:
            print("\n🎉 ALL CHECKS PASSED! The implementation is correct.")
        else:
            print("\n❌ Some checks failed.")
            
    else:
        print("❌ FAILED - Could not parse the signal")
        print("This means the implementation still has issues")

if __name__ == "__main__":
    test_original_problem()
