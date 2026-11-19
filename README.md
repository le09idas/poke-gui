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

## Tabs

| Tab | Shows |
|---|---|
| Player | Name, trainer ID, rival, play time, money/coins, position, Pikachu happiness, options, Fly destinations, badges |
| Team | Party summary plus moves/PP, stats, DVs, Stat Exp, experience and OT for each Pokémon |
| Bag | Items, quantities and sell prices (or "invaluable" for key items/HMs) |
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

- [ ] Split data reading from display (getters return tables, renderers print them)
- [ ] JSON + small HTTP server on `127.0.0.1` using mGBA's `socket` API
- [ ] Web dashboard (`web/`) that polls the script and renders the data
- [ ] Sprites: battle sprites from VRAM, then a ROM decompressor for all Pokémon/trainer sprites
- [ ] Support for other games (Red/Blue, Gold/Silver/Crystal, Gen 3)

## Legal

This project contains only code. Pokémon, its sprites and other assets are the property of
Nintendo / Creatures Inc. / GAME FREAK inc. Any graphics shown by the tool are read from the
user's own ROM at runtime and are not distributed with this project.
