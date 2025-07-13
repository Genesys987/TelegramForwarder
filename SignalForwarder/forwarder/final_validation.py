#!/usr/bin/env python3
# Final comprehensive validation of all functionality

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from signal_parser import parse_signal

def final_validation():
    """Complete validation of all supported signal formats"""
    
    print("🚀 FINAL COMPREHENSIVE VALIDATION")
    print("=" * 50)
    
    # All supported formats with expected results
    test_suite = [
        {
            "name": "1. Original Problem - Slash TP Format (SELL)",
            "signal": """GOLD SELL 3334/3337

3332/3330/3328/3325

        SL 3345""",
            "expected": {
                "signal_type": "SELL",
                "symbol": "XAUUSD", 
                "entry": 3337.0,
                "take_profits": [3332.0, 3330.0, 3328.0, 3325.0],
                "stop_loss": 3345.0
            }
        },
        {
            "name": "2. Slash TP Format (BUY)",
            "signal": """GOLD BUY 3334/3337

3340/3342/3345/3348

        SL 3330""",
            "expected": {
                "signal_type": "BUY",
                "symbol": "XAUUSD",
                "entry": 3334.0,  # Lower for BUY
                "take_profits": [3340.0, 3342.0, 3345.0, 3348.0],
                "stop_loss": 3330.0
            }
        },
        {
            "name": "3. NOW Signal (Immediate Entry)",
            "signal": "GOLD SELL NOW TP1: 2650 TP2: 2645 SL: 2665",
            "expected": {
                "signal_type": "SELL",
                "symbol": "XAUUSD",
                "entry": 0,  # NOW override
                "take_profits": [2650.0, 2645.0],
                "stop_loss": 2665.0
            }
        },
        {
            "name": "4. Traditional Multi-line",
            "signal": """BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Stop loss at 88600.00""",
            "expected": {
                "signal_type": "BUY",
                "symbol": "BTCUSD",
                "entry": 89300.0,
                "take_profits": [89500.0, 89800.0],
                "stop_loss": 88600.0
            }
        },
        {
            "name": "5. Single Line with Range",
            "signal": "SELL GOLD 2670/2675 TP1: 2650 TP2: 2640 SL: 2685",
            "expected": {
                "signal_type": "SELL",
                "symbol": "XAUUSD",
                "entry": 2675.0,  # Higher for SELL
                "take_profits": [2650.0, 2640.0],
                "stop_loss": 2685.0
            }
        },
        {
            "name": "6. FROM Format",
            "signal": "GOLD SELL FROM 3313/3315.3 TP1: 3289.0 TP2: 3282.5 SL: 3329.5",
            "expected": {
                "signal_type": "SELL",
                "symbol": "XAUUSD",
                "entry": 3315.3,
                "take_profits": [3289.0, 3282.5],
                "stop_loss": 3329.5
            }
        },
        {
            "name": "7. Pipe Format",
            "signal": "BTCUSD | BUY 109500 ❌ Stop Loss 109000 ✅TP1 109700",
            "expected": {
                "signal_type": "BUY",
                "symbol": "BTCUSD",
                "entry": 109500.0,
                "take_profits": [109700.0],
                "stop_loss": 109000.0
            }
        },
        {
            "name": "8. Emoji NOW Signal",
            "signal": "🚨 XAUUSD BUY NOW 🚨 TP 2670 SL 2655",
            "expected": {
                "signal_type": "BUY",
                "symbol": "XAUUSD",
                "entry": 0,
                "take_profits": [2670.0],
                "stop_loss": 2655.0
            }
        },
        {
            "name": "9. NOW + Range (Entry Override)",
            "signal": "BUY XAUUSD 2660/2665 NOW TP: 2670 SL: 2650",
            "expected": {
                "signal_type": "BUY",
                "symbol": "XAUUSD",
                "entry": 0,  # NOW overrides range
                "take_profits": [2670.0],
                "stop_loss": 2650.0
            }
        }
    ]
    
    passed = 0
    total = len(test_suite)
    
    for test_case in test_suite:
        print(f"\n{test_case['name']}")
        print("-" * len(test_case['name']))
        
        result = parse_signal(test_case['signal'])
        expected = test_case['expected']
        
        if result:
            # Check each expected field
            all_correct = True
            for field, expected_value in expected.items():
                actual_value = result.get(field)
                if actual_value == expected_value:
                    print(f"  ✅ {field}: {actual_value}")
                else:
                    print(f"  ❌ {field}: Expected {expected_value}, got {actual_value}")
                    all_correct = False
            
            if all_correct:
                print("  🎉 PASS")
                passed += 1
            else:
                print("  💥 FAIL")
        else:
            print("  💥 PARSE FAILED")
    
    print(f"\n{'='*50}")
    print(f"📊 RESULTS: {passed}/{total} tests passed")
    
    if passed == total:
        print("🏆 ALL TESTS PASSED! Implementation is complete and robust.")
        print("\n✅ Supported formats:")
        print("   • Traditional multi-line signals")
        print("   • Single-line signals with ranges")
        print("   • FROM format signals")
        print("   • Pipe format signals")
        print("   • NOW (immediate entry) signals")
        print("   • Emoji-enhanced signals")
        print("   • NEW: Slash-separated TP format")
        print("   • Mixed format combinations")
        print("\n🔧 Key features:")
        print("   • Range entry parsing (BUY=lower, SELL=higher)")
        print("   • NOW keyword entry override (sets entry=0)")
        print("   • Multiple TP formats including slash-separated")
        print("   • Robust emoji support")
        print("   • Symbol mapping (GOLD→XAUUSD)")
        print("   • Proper TP sorting (BUY=asc, SELL=desc)")
    else:
        print("❌ Some tests failed. Review implementation.")
    
    return passed == total

if __name__ == "__main__":
    final_validation()
