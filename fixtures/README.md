# fixtures/

Saved game-state messages from `lua/yellow.lua`, used to develop and test the GUI
without mGBA running. Capture one with:

```
python tools/peek_state.py --save overworld.json
```

(A bare file name is saved here; give a path to save somewhere else.)

The JSON files are gitignored because they contain your trainer name and ID. Only this
README is tracked, so the folder exists in every clone.
