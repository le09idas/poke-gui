# CLAUDE.md

Handoff notes for Claude Code sessions working in this repo.

## History

- This repo (`poke-gui`, remote `git@github.com:le09idas/poke-gui.git`) used to hold a
  Go/Fyne GUI prototype (`main.go`, `go.mod`, `FyneApp.toml`). That code was **deleted**
  and replaced with the Pokémon Dashboard project, which was developed in
  `../pokemon-dashboard` (that folder had no commits; this is now the canonical location).
- The old Go code is still recoverable from git history (commit `3356e13`).
- At handoff time the replacement was **not yet committed** — check `git status`.

## What the project is

An mGBA Lua script (`lua/yellow.lua`) that reads Pokémon Yellow (USA) RAM/ROM every 15
frames and prints live info into mGBA scripting-window tabs: Player, Team, Bag, Pokedex,
Location, Wild, Battle. See `README.md` for usage, tab contents and the roadmap.

## Code layout (`lua/yellow.lua`, single file)

- Top: `console:createBuffer(...)` tabs + `setSize` (buffers have fixed rows; overflow
  pushes lines off the top, so size them for the max content).
- Address constants (`w...` names match pret/pokeyellow `pokeyellow.sym` labels), then
  lookup tables (species, moves, items, maps, etc.).
- Helpers: `read16BE`, `read24BE`, `readBCD`, `romBCD`, `decode` (Gen 1 text charset),
  `speciesName`, `dexNumber`, `internalFromDex`, `testFlag`, `itemName`, `moveName`, ...
- One `update*()` function per tab (`update` = Wild tab), each clearing and reprinting its
  buffer. `readMon(addr, ofs, statExpAddr)` reads a mon from either the party struct
  (`PARTY_OFS`) or battle struct (`BATTLE_OFS`).
- Bottom: `callbacks:add("frame", ...)` calls all updaters every 15 frames.

## Conventions / gotchas

- All addresses and layouts come from the pret/pokeyellow disassembly — cite the symbol
  name in a comment when adding one. ROM labels convert as `bank * 0x4000 + (addr - 0x4000)`.
- Gen 1: species bytes are internal IDs (not dex numbers), multi-byte values are
  big-endian, money/coins are BCD, text uses a custom encoding (0x50 terminator).
- The active battler's live values come from the battle struct; other party members from
  the party struct.
- Never commit ROMs, saves, or extracted sprites (see `.gitignore`). The project ships code
  only; graphics must be read from the user's own ROM at runtime.
- Target: mGBA 0.10+ (developed on 0.10.5).

## Next steps

Follow the README roadmap: first split data reading from rendering (getters return
tables, renderers print), then a JSON/HTTP server on 127.0.0.1 via mGBA's `socket` API,
then a `web/` dashboard.
