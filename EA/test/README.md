# Test scenario

1. Move `signals.txt` to `<Metatrader folder>/tester/files`
2. Move `testing.set` to `<Metatrader folder>/tester`
3. Set up MT4 strategy tester
     - Date: from 2025.06.25. to 2025.06.26.
     - Symbol: EURUSD
     - Time frame: H1
     - Model: Every tick
     - Use visual mode: checked
     - Expert properties: load from `testing.set` file
4. Start the strategy tester, it should read the signals from `signals.txt` and execute trades accordingly.
