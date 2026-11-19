# Pokémon Dashboard

A Lua script for the [mGBA](https://mgba.io) emulator that reads Pokémon Yellow's memory
while you play and shows live game info in the scripting window.

## Requirements

- mGBA 0.10 or newer (developed on 0.10.5)
- Pokémon Yellow (USA) ROM — **not included**; use your own copy

## Usage

1. Load the ROM in mGBA.
2. Open **Tools → Scripting…**, then **File → Load script…** and choose `lua/yellow.lua`.

Loading the script before or after the ROM both work.

### Reading the data from another program

The script also runs a small TCP server on `127.0.0.1:8765` (localhost only; if the port
is busy it tries the next few and logs which one it used in the Console tab). Every 15
frames it sends each connected client one line of JSON:

```json
{"protocol":1,"game":"yellow","frame":1234,"state":{"player":{...},"team":{...},"bag":{...},...}}
```

`state` has one key per tab (`player`, `team`, `bag`, `pcBoxes`, `pcItems`, `pokedex`,
`location`, `wild`, `battle`). To check it's working:

```
python tools/peek_state.py          # summary of one message
python tools/peek_state.py --raw    # the whole thing
```

## Tabs

| Tab | Shows |
|---|---|
| Player | Name, trainer ID, rival, play time, money/coins, position, Pikachu happiness, options, Fly destinations, badges |
| Team | Party summary plus moves/PP, stats, DVs, Stat Exp, experience and OT for each Pokémon |
| Bag | Items, quantities and sell prices (or "invaluable" for key items/HMs) |
| PC Boxes | All 12 boxes: each stored Pokémon's level, HP, status, type, stats, DVs and moves |
| PC Items | Items stored in the PC, same format as the Bag |
| Pokedex | Seen/owned counts and the full 151 list |
| Location | Current map, position, and the map's items (visible/hidden, obtained or not) |
| Wild | The wild Pokémon you're fighting and the map's grass encounter table |
| Battle | Both sides during a battle: HP, fainted/status, stats, DVs, Stat Exp, moves |

## How the addresses were found

All memory addresses and data layouts come from the
[pret/pokeyellow](https://github.com/pret/pokeyellow) disassembly:

- **Addresses:** `pokeyellow.sym` on the repo's `symbols` branch
  (RAM labels like `00:d162 wPartyCount`; ROM labels as `bank:addr`,
  converted with `bank * 0x4000 + (addr - 0x4000)`).
- **Layouts and meanings:** `macros/ram.asm` (Pokémon structs), `constants/` (bit flags,
  map IDs, items) and `data/` (hidden items, prices, key items).

Gen 1 quirks to know: species bytes are internal IDs (not Pokédex numbers), multi-byte
numbers are big-endian, money/coins are BCD, and text uses its own character encoding.

## Roadmap

- [x] Split data reading from display (getters return tables, renderers print them)
- [x] Stream the data as newline-delimited JSON over TCP on `127.0.0.1:8765` (mGBA `socket` API)
- [ ] Desktop GUI in Python + PySide6 that connects to the script and renders the data
- [ ] Sprites: battle sprites from VRAM, then a ROM decompressor for all Pokémon/trainer sprites
- [ ] Support for other games (Red/Blue, Gold/Silver/Crystal, Gen 3)

## Legal

This project contains only code. Pokémon, its sprites and other assets are the property of
Nintendo / Creatures Inc. / GAME FREAK inc. Any graphics shown by the tool are read from the
user's own ROM at runtime and are not distributed with this project.
