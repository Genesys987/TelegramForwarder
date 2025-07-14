#!/usr/bin/env python3
# Quick test for NOW and all formats

from signal_parser import parse_signal

def quick_test():
    print("=== Quick Test: GOLD SELL NOW + All Formats ===\n")
    
    # 1. Test GOLD SELL NOW
    print("1. GOLD SELL NOW:")
    now_signal = 'GOLD SELL NOW TP1: 2650 TP2: 2645 SL: 2665'
    result = parse_signal(now_signal)
    if result:
        print(f"   ✅ SUCCESS - Entry: {result.get('entry')} (should be 0)")
        print(f"   Type: {result.get('signal_type')}, Symbol: {result.get('symbol')}")
    else:
        print("   ❌ FAILED")
    
    # 2. Test new slash format
    print("\n2. New Slash Format:")
    slash_signal = '''GOLD SELL 3334/3337

3332/3330/3328/3325

        SL 3345'''
    result2 = parse_signal(slash_signal)
    if result2:
        print(f"   ✅ SUCCESS - Entry: {result2.get('entry')} (should be 3337)")
        print(f"   TPs: {result2.get('take_profits')}")
    else:
        print("   ❌ FAILED")
    
    # 3. Test traditional format
    print("\n3. Traditional Format:")
    trad_signal = '''BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Stop loss at 88600.00'''
    result3 = parse_signal(trad_signal)
    if result3:
        print(f"   ✅ SUCCESS - Entry: {result3.get('entry')} (should be 89300)")
    else:
        print("   ❌ FAILED")
    
    # 4. Test emoji NOW
    print("\n4. Emoji NOW:")
    emoji_signal = '🚨 XAUUSD BUY NOW 🚨 TP 2670 SL 2655'
    result4 = parse_signal(emoji_signal)
    if result4:
        print(f"   ✅ SUCCESS - Entry: {result4.get('entry')} (should be 0)")
    else:
        print("   ❌ FAILED")
    
    # 5. Test pipe format
    print("\n5. Pipe Format:")
    pipe_signal = 'BTCUSD | BUY 109500 ❌ Stop Loss 109000 ✅TP1 109700'
    result5 = parse_signal(pipe_signal)
    if result5:
        print(f"   ✅ SUCCESS - Entry: {result5.get('entry')} (should be 109500)")
    else:
        print("   ❌ FAILED")
        
    print("\n=== Summary ===")
    results = [result, result2, result3, result4, result5]
    working = sum(1 for r in results if r is not None)
    print(f"Working formats: {working}/5")
    
    if working == 5:
        print("🎉 ALL FORMATS WORKING PERFECTLY!")
    else:
        print("⚠️ Some formats have issues")

if __name__ == "__main__":
    quick_test()
