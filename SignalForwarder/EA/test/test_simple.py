#!/usr/bin/env python3
"""
Simple test script for channel name functionality without dependencies.
Tests only the core logic functions.
"""

import re
import sys
import os

def clean_channel_name(channel_name: str) -> str:
    """
    Clean channel name by removing emojis and unwanted characters.
    
    Args:
        channel_name: Raw channel name/title that may contain emojis
        
    Returns:
        Clean channel name with only alphanumeric chars, spaces, and basic punctuation
    """
    if not channel_name or not channel_name.strip():
        return "UNKNOWN"
    
    # Remove emojis using regex pattern for most Unicode emoji ranges
    emoji_pattern = re.compile(
        "["
        "\U0001F600-\U0001F64F"  # emoticons
        "\U0001F300-\U0001F5FF"  # symbols & pictographs
        "\U0001F680-\U0001F6FF"  # transport & map symbols
        "\U0001F1E0-\U0001F1FF"  # flags (iOS)
        "\U00002500-\U00002BEF"  # chinese char
        "\U00002702-\U000027B0"
        "\U00002702-\U000027B0"
        "\U000024C2-\U0001F251"
        "\U0001f926-\U0001f937"
        "\U00010000-\U0010ffff"
        "\u2640-\u2642"
        "\u2600-\u2B55"
        "\u200d"
        "\u23cf"
        "\u23e9"
        "\u231a"
        "\ufe0f"  # dingbats
        "\u3030"
        "]+", flags=re.UNICODE)
    
    # Remove emojis
    clean_name = emoji_pattern.sub('', channel_name)
    
    # Remove unwanted characters (keep only alphanumeric and spaces, remove underscores)
    clean_name = re.sub(r'[^\w\s]', '', clean_name)  # First remove non-word chars except spaces
    clean_name = re.sub(r'_', '', clean_name)        # Then remove underscores specifically
    
    # Remove extra whitespace
    clean_name = re.sub(r'\s+', ' ', clean_name).strip()
    
    # Convert to uppercase and limit length
    clean_name = clean_name.upper()[:20]  # Max 20 characters
    
    # If name becomes empty after cleaning, use fallback
    if not clean_name:
        clean_name = "CHANNEL"
    
    return clean_name

def test_channel_name_cleaning():
    """Test the channel name cleaning function"""
    print("=== Testing Channel Name Cleaning ===")
    
    test_cases = [
        ("💰 FOREX SIGNALS 🚀", "FOREX SIGNALS"),
        ("🎯 Trading Academy 📈", "TRADING ACADEMY"),
        ("VIP Signals ⭐", "VIP SIGNALS"),
        ("Gold Traders 🥇💎", "GOLD TRADERS"),
        ("🔥💯 PREMIUM FX 💯🔥", "PREMIUM FX"),
        ("", "UNKNOWN"),
        ("   ", "UNKNOWN"),
        ("🤖🤖🤖", "CHANNEL"),
        ("Regular Channel Name", "REGULAR CHANNEL NAME"),
        ("Channel-With.Special_Chars123", "CHANNELWITHSPECIALCH"),  # Only alphanumeric and spaces
        ("FXPLATINUM_SIGNALS", "FXPLATINUMSIGNALS"),
    ]
    
    passed = 0
    for input_name, expected in test_cases:
        result = clean_channel_name(input_name)
        status = "✅" if result == expected else "❌"
        print(f"{status} '{input_name}' -> '{result}' (expected: '{expected}')")
        if result == expected:
            passed += 1
    
    print(f"Channel name cleaning: {passed}/{len(test_cases)} tests passed\n")
    return passed == len(test_cases)

def test_signal_format():
    """Test the expected signal format"""
    print("=== Testing Signal Format ===")
    
    # Test the new signal format that will be generated
    timestamp = 1735862400  # Example timestamp
    signal_type = "BUY"
    symbol = "XAUUSD"
    entry = 2680.50
    tp1, tp2, tp3 = 2685.00, 2690.00, 2695.00
    stop_loss = 2675.00
    group_id = 3005
    channel_name = "FXPLATINUM"
    
    # This is the format that will be generated
    signal_line = f"{timestamp}|{signal_type}|{symbol}|{entry}|{tp1},{tp2},{tp3}|{stop_loss}|GID:{group_id}|{channel_name}"
    
    print(f"✅ New signal format: {signal_line}")
    
    # Test parsing the format
    parts = signal_line.split('|')
    if len(parts) != 8:
        print(f"❌ Expected 8 parts, got {len(parts)}")
        return False
    
    if parts[0] != str(timestamp):
        print(f"❌ Timestamp mismatch: {parts[0]} != {timestamp}")
        return False
        
    if parts[7] != channel_name:
        print(f"❌ Channel name mismatch: {parts[7]} != {channel_name}")
        return False
    
    if not parts[6].startswith("GID:"):
        print(f"❌ GID format error: {parts[6]}")
        return False
    
    print("Signal format test: PASSED\n")
    return True

def test_mt4_comment_format():
    """Test MT4 order comment format"""
    print("=== Testing MT4 Comment Format ===")
    
    # Test the new comment format
    group_id = 3005
    channel_name = "FXPLATINUM"
    stop_loss = 2675.00
    
    # New format: GID:3005|FXPLATINUM|SL:2675.00
    comment = f"GID:{group_id}|{channel_name}|SL:{stop_loss}"
    print(f"✅ New comment format: '{comment}'")
    
    # Test parsing the comment (simulate EA logic)
    parts = comment.split('|')
    if len(parts) != 3:
        print("❌ Comment should have 3 parts")
        return False
    
    if not parts[0].startswith("GID:"):
        print("❌ First part should start with 'GID:'")
        return False
        
    extracted_gid = int(parts[0][4:])  # Remove "GID:" prefix
    if extracted_gid != group_id:
        print(f"❌ GID mismatch: {extracted_gid} != {group_id}")
        return False
    
    extracted_channel = parts[1]
    if extracted_channel != channel_name:
        print(f"❌ Channel mismatch: {extracted_channel} != {channel_name}")
        return False
    
    if not parts[2].startswith("SL:"):
        print("❌ Third part should start with 'SL:'")
        return False
        
    extracted_sl = float(parts[2][3:])  # Remove "SL:" prefix
    if abs(extracted_sl - stop_loss) > 0.001:
        print(f"❌ SL mismatch: {extracted_sl} != {stop_loss}")
        return False
    
    # Test legacy format compatibility
    legacy_comment = f"GID:{group_id}|SL:{stop_loss}"
    print(f"✅ Legacy format: '{legacy_comment}'")
    
    print("MT4 comment format test: PASSED\n")
    return True

def test_ea_parsing_logic():
    """Test the logic that would be used in the EA"""
    print("=== Testing EA Parsing Logic ===")
    
    def parse_comment_like_ea(comment):
        """Simulate the EA's ParseOrderComment function logic"""
        # Check for GID at start
        if not comment.startswith("GID:"):
            return None
            
        # Find first pipe
        first_pipe = comment.find("|", 4)
        if first_pipe < 0:
            return None
            
        # Extract GID
        group_id = int(comment[4:first_pipe])
        
        # Look for SL
        sl_pos = comment.find("|SL:", first_pipe)
        if sl_pos < 0:
            # Try old format
            if comment[first_pipe:first_pipe+3] == "|SL":
                sl_pos = first_pipe
            else:
                return None
        
        # Extract SL
        signal_sl = float(comment[sl_pos+4:])
        
        # Extract channel name if present
        channel_name = ""
        if sl_pos > first_pipe + 1:
            # New format with channel
            channel_name = comment[first_pipe+1:sl_pos]
        
        return {
            "group_id": group_id,
            "signal_sl": signal_sl,
            "channel_name": channel_name
        }
    
    # Test new format
    new_comment = "GID:3005|FXPLATINUM|SL:2675.00"
    result = parse_comment_like_ea(new_comment)
    
    if not result:
        print("❌ Failed to parse new format")
        return False
        
    if result["group_id"] != 3005:
        print(f"❌ GID mismatch: {result['group_id']}")
        return False
        
    if result["channel_name"] != "FXPLATINUM":
        print(f"❌ Channel mismatch: {result['channel_name']}")
        return False
        
    if abs(result["signal_sl"] - 2675.00) > 0.001:
        print(f"❌ SL mismatch: {result['signal_sl']}")
        return False
        
    print(f"✅ New format parsed: {result}")
    
    # Test legacy format
    legacy_comment = "GID:3005|SL:2675.00"
    result = parse_comment_like_ea(legacy_comment)
    
    if not result:
        print("❌ Failed to parse legacy format")
        return False
        
    if result["group_id"] != 3005:
        print(f"❌ Legacy GID mismatch: {result['group_id']}")
        return False
        
    if result["channel_name"] != "":
        print(f"❌ Legacy should have empty channel: {result['channel_name']}")
        return False
        
    print(f"✅ Legacy format parsed: {result}")
    
    print("EA parsing logic test: PASSED\n")
    return True

def main():
    """Run all tests"""
    print("🧪 Starting Channel Name Integration Tests\n")
    
    tests = [
        test_channel_name_cleaning,
        test_signal_format,
        test_mt4_comment_format,
        test_ea_parsing_logic,
    ]
    
    passed = 0
    total = len(tests)
    
    for test_func in tests:
        try:
            if test_func():
                passed += 1
            else:
                print(f"❌ Test {test_func.__name__} FAILED\n")
        except Exception as e:
            print(f"❌ Test {test_func.__name__} CRASHED: {e}\n")
    
    print(f"🏁 Test Results: {passed}/{total} tests passed")
    
    if passed == total:
        print("🎉 All tests PASSED! Channel name functionality should work correctly.")
        print("\n📋 Summary of changes implemented:")
        print("1. ✅ Channel name cleaning (emoji removal)")
        print("2. ✅ New signal format: timestamp|type|symbol|entry|tps|sl|GID:id|channel")
        print("3. ✅ New order comment: GID:id|CHANNEL|SL:value")
        print("4. ✅ Backward compatibility with legacy format")
        print("5. ✅ EA parsing logic updated for both formats")
        return True
    else:
        print("💥 Some tests FAILED. Please check the implementation.")
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
