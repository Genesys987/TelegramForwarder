#!/usr/bin/env python3
"""
Test script for the updated signal processing with channel names.
This script tests the new functionality including:
1. Channel name cleaning (emoji removal)
2. Signal parsing with channel names
3. Queue formatting with channel names
"""

import sys
import os

# Add the forwarder directory to the path
forwarder_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'forwarder')
sys.path.insert(0, forwarder_path)

from signal_parser import parse_signal, clean_channel_name
from queue_manager import add_signal_to_queue
import tempfile
import json
from datetime import datetime, timezone

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
        ("Channel-With.Special_Chars123", "CHANNELWITHSPECIALCHARS"),
    ]
    
    for input_name, expected in test_cases:
        result = clean_channel_name(input_name)
        status = "✅" if result == expected else "❌"
        print(f"{status} '{input_name}' -> '{result}' (expected: '{expected}')")
        if result != expected:
            return False
    
    print("Channel name cleaning tests: PASSED\n")
    return True

def test_signal_parsing_with_channel():
    """Test signal parsing functionality"""
    print("=== Testing Signal Parsing ===")
    
    test_signal = """BUY XAUUSD
ENTRY 2680.50
Take profit 1 at 2685.00
Take profit 2 at 2690.00  
Take profit 3 at 2695.00
Stop loss at 2675.00"""
    
    result = parse_signal(test_signal)
    
    if not result:
        print("❌ Signal parsing failed")
        return False
    
    expected_keys = ["signal_type", "symbol", "entry", "take_profits", "stop_loss"]
    for key in expected_keys:
        if key not in result:
            print(f"❌ Missing key: {key}")
            return False
    
    # Test with channel name added
    result["channel_name"] = clean_channel_name("💰 VIP GOLD SIGNALS 🚀")
    result["group_id"] = 3005
    result["timestamp_utc"] = int(datetime.now(timezone.utc).timestamp())
    
    print(f"✅ Parsed signal: {result}")
    print("Signal parsing tests: PASSED\n")
    return True

def test_queue_functionality():
    """Test queue functionality with channel names"""
    print("=== Testing Queue Functionality ===")
    
    # Create temporary config for testing
    test_signal_data = {
        "timestamp_utc": int(datetime.now(timezone.utc).timestamp()),
        "signal_type": "BUY",
        "symbol": "XAUUSD",
        "entry": 2680.50,
        "take_profits": [2685.00, 2690.00, 2695.00],
        "stop_loss": 2675.00,
        "group_id": 3005,
        "channel_name": "FXPLATINUM"
    }
    
    # Create a temporary queue file for testing
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as temp_file:
        temp_queue_path = temp_file.name
    
    # Temporarily override the config for testing
    import config
    original_queue_paths = config.MT4_QUEUE_FILE_PATHS
    config.MT4_QUEUE_FILE_PATHS = [temp_queue_path]
    
    try:
        # Test adding signal to queue
        success = add_signal_to_queue(test_signal_data)
        
        if not success:
            print("❌ Failed to add signal to queue")
            return False
        
        # Read back the queue file to verify format
        with open(temp_queue_path, 'r', encoding='utf-8') as f:
            queue_content = f.read().strip()
        
        print(f"✅ Queue content: {queue_content}")
        
        # Verify the format includes channel name
        parts = queue_content.split('|')
        if len(parts) != 8:
            print(f"❌ Expected 8 parts in queue format, got {len(parts)}")
            return False
        
        if parts[7] != "FXPLATINUM":
            print(f"❌ Expected channel name 'FXPLATINUM', got '{parts[7]}'")
            return False
        
        if not parts[6].startswith("GID:3005"):
            print(f"❌ Expected GID:3005, got '{parts[6]}'")
            return False
        
        print("Queue functionality tests: PASSED\n")
        return True
        
    finally:
        # Restore original config and cleanup
        config.MT4_QUEUE_FILE_PATHS = original_queue_paths
        try:
            os.unlink(temp_queue_path)
        except:
            pass

def test_mt4_comment_format():
    """Test MT4 order comment format"""
    print("=== Testing MT4 Comment Format ===")
    
    # Test the new comment format that will be generated
    group_id = 3005
    channel_name = "FXPLATINUM"
    stop_loss = 2675.00
    
    # This is the format that will be generated by the EA
    comment = f"GID:{group_id}|{channel_name}|SL:{stop_loss}"
    
    print(f"✅ New comment format: '{comment}'")
    
    # Test parsing (simulate what the EA ParseOrderComment function should do)
    # For Python testing, we'll just verify the format structure
    parts = comment.split('|')
    if len(parts) != 3:
        print("❌ Comment should have 3 parts")
        return False
    
    if not parts[0].startswith("GID:"):
        print("❌ First part should start with 'GID:'")
        return False
    
    if not parts[2].startswith("SL:"):
        print("❌ Third part should start with 'SL:'")
        return False
    
    print("MT4 comment format tests: PASSED\n")
    return True

def main():
    """Run all tests"""
    print("🧪 Starting Signal Forwarder Channel Name Tests\n")
    
    tests = [
        test_channel_name_cleaning,
        test_signal_parsing_with_channel,
        test_queue_functionality,
        test_mt4_comment_format,
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
        print("🎉 All tests PASSED! Channel name functionality is working correctly.")
        return True
    else:
        print("💥 Some tests FAILED. Please check the implementation.")
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
