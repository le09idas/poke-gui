-- Pokemon Yellow (USA) info panels for mGBA:
--   Player   - name, ID, rival, play time, money/coins, position, Pikachu, options, Fly spots, badges
--   Team     - party summary + moves, stats, DVs, stat exp, OT for each Pokemon
--   Bag      - items, quantities and sell prices
--   Pokedex  - seen/owned counts and the full list
--   Location - current map, position, and items (visible/hidden, obtained or not)
--   Wild     - the wild Pokemon you're fighting + this map's grass encounters
--   Battle   - both sides' Pokemon during a battle: HP, fainted/status, stats, moves
-- Addresses come from pret/pokeyellow's pokeyellow.sym (symbols branch).
--
-- Layout: addresses + lookup tables -> helpers -> get*() functions (read the game,
-- return plain tables) -> render*() functions (print a table into a tab) -> TABS
-- list + frame loop, which keeps the latest data for every tab in `state`.

-- Tabs appear in the scripting window in the order they're created
local bufPlayer   = console:createBuffer("Player")
local bufTeam     = console:createBuffer("Team")
local bufBag      = console:createBuffer("Bag")
local bufPCBoxes  = console:createBuffer("PC Boxes")
local bufPCItems  = console:createBuffer("PC Items")
local bufPokedex  = console:createBuffer("Pokedex")
local bufLocation = console:createBuffer("Location")
local bufWild     = console:createBuffer("Wild")
local bufBattle   = console:createBuffer("Battle")
bufBattle:setSize(80, 90)   -- up to 6 + 6 Pokemon x 6 lines + headers

-- Buffers have a fixed number of rows; anything printed past the last row pushes
-- the top lines off for good. Make room for 2 header lines + a blank + 151 entries.
bufPokedex:setSize(40, 160)

bufPlayer:setSize(100, 30)  -- long "Fly destinations" line + 9 badge lines
bufTeam:setSize(60, 90)   -- up to 6 Pokemon x ~12 lines each
bufBag:setSize(60, 30)    -- up to 20 items + header
bufPCItems:setSize(60, 60)    -- up to 50 items + header
bufPCBoxes:setSize(100, 770)  -- 12 boxes x (header + up to 20 Pokemon x 3 lines)

-- The GUI connects to this TCP port on 127.0.0.1 (localhost only). If it's taken,
-- the next few ports are tried; the Console tab says which one was used.
local SERVER_PORT = 8765

-- RAM (WRAM) addresses
local wIsInBattle    = 0xD056  -- 0 = no battle, 1 = wild, 2 = trainer
local wEnemyMonNick  = 0xCFD9  -- 11 bytes, 0x50-terminated
local wEnemyMon      = 0xCFE4  -- start of the active enemy's battle struct
local wGrassRate     = 0xD886  -- encounter rate for grass on this map (0 = none)
local wGrassMons     = 0xD887  -- 10 entries of {level, species}
local wPlayerMoney   = 0xD346  -- 3 bytes, BCD (¥3175 is stored as 00 31 75)
local wObtainedBadges = 0xD355 -- 1 byte, one bit per badge (bit 0 = Boulder ... bit 7 = Earth)

local wCurMap        = 0xD35D  -- 1 byte, current map ID
local wYCoord        = 0xD360  -- player's Y position on the map
local wXCoord        = 0xD361  -- player's X position on the map
local wLastMap       = 0xD364  -- the outdoor map you'll return to when you leave a building

-- Item data
local wNumSprites               = 0xD4E0  -- number of objects (people, item balls...) on this map
local wMapSpriteExtraData       = 0xD503  -- 2 bytes per object: {item ID, 0} for item balls,
                                          -- {class, number} for trainers, {0, 0} for everything else
local wSprite01StateData2       = 0xC210  -- 16 bytes per object; +4 = Y + 4, +5 = X + 4
local wToggleableObjectList     = 0xD5CD  -- this map's {object number, global flag index} pairs, 0xFF-terminated
local wToggleableObjectFlags    = 0xD5A5  -- bit set = object removed from the map (item ball picked up)
local wObtainedHiddenItemsFlags = 0xD6EF  -- bit set = hidden item found
local ItemNames                 = 0x45B7  -- ROM 01:45B7, names back to back, each ending in 0x50

-- Player info
local wPlayerName       = 0xD157  -- 11 bytes, 0x50-terminated
local wRivalName        = 0xD349  -- 11 bytes
local wPlayerID         = 0xD358  -- 2 bytes, big-endian
local wPlayerCoins      = 0xD5A3  -- 2 bytes, BCD (Game Corner coins)
local wOptions          = 0xD354  -- bits 0-3 text speed, 4-5 sound, 6 battle style, 7 animations off
local wPikachuHappiness = 0xD46F  -- 0-255
local wPikachuMood      = 0xD470
local wTownVisitedFlag  = 0xD70A  -- one bit per town/city map ID (0x00-0x0A): visited = can Fly there
local wPlayTimeHours    = 0xDA40  -- play time is stored as plain numbers (not BCD)
local wPlayTimeMaxed    = 0xDA41  -- non-zero once the clock hits 255:59:59 and stops
local wPlayTimeMinutes  = 0xDA42
local wPlayTimeSeconds  = 0xDA43

-- Team (party)
local wPartyCount    = 0xD162  -- number of Pokemon in the party
local wPartyMons     = 0xD16A  -- 6 x 44-byte party_struct (layout in macros/ram.asm)
local wPartyMonOT    = 0xD272  -- 6 x 11-byte original trainer names
local wPartyMonNicks = 0xD2B4  -- 6 x 11-byte nicknames
local PARTY_MON_SIZE = 44
local NAME_LENGTH    = 11
local PARTY_DATA_END = 0xD2F6  -- end of the nicknames (used to detect changes)

-- Bag
local wNumBagItems   = 0xD31C  -- number of different items
local wBagItems      = 0xD31D  -- {item ID, quantity} pairs, 0xFF-terminated, max 20
local BAG_ITEM_CAPACITY = 20

-- PC (Bill's PC)
local wNumBoxItems     = 0xD539  -- number of different items stored in the PC
local wBoxItems        = 0xD53A  -- {item ID, quantity} pairs, 0xFF-terminated, max 50
local PC_ITEM_CAPACITY = 50
local wCurrentBoxNum   = 0xD59F  -- bits 0-6: box number (0-11); bit 7: player has changed boxes before
-- Only the current box lives in WRAM (wBoxDataStart-wBoxDataEnd). All 12 boxes are kept in
-- cartridge SRAM (sBox1-sBox12) with the same layout; the current box's SRAM copy is only
-- updated when the game saves, so the WRAM copy is the live one.
local wBoxDataStart    = 0xDA7F  -- wBoxCount (1 byte), then wBoxSpecies (21 bytes)
local wBoxMons         = 0xDA95  -- 20 x 33-byte box_struct
local wBoxMonOT        = 0xDD29  -- 20 x 11-byte original trainer names
local wBoxMonNicks     = 0xDE05  -- 20 x 11-byte nicknames
local wBoxDataEnd      = 0xDEE1
local BOX_SIZE         = wBoxDataEnd - wBoxDataStart   -- 0x462
local BOX_MON_SIZE     = 33      -- BOXMON_STRUCT_LENGTH
local MONS_PER_BOX     = 20
local NUM_BOXES        = 12
-- sBox1-sBox6 are at 02:A000, 02:A462, ... and sBox7-sBox12 at the same addresses in bank 3.
-- mGBA's "sram" memory domain lays the 8 KiB banks out back to back (bank n at n * 0x2000).
local function sBoxOffset(box)   -- box = 1-12
    local bank = box <= 6 and 2 or 3
    return bank * 0x2000 + ((box - 1) % 6) * BOX_SIZE
end

-- Read from cartridge SRAM. The game keeps SRAM switched off except while saving
-- (EnableSRAM/DisableSRAM write to rRAMG), and while it's off every read returns 0xFF.
-- So: switch it on, read, switch it back off. This all happens inside one frame callback,
-- so the game never sees the change. If SRAM is already on (the game is mid-save), the
-- switch is left alone. Only call this once the game has been saved at least once
-- (the probe byte is meaningless before that).
local readSRAM
do
    local rRAMG             = 0x0000  -- MBC RAM enable register (constants/hardware.inc)
    local RAMG_SRAM_ENABLE  = 0x0A
    local RAMG_SRAM_DISABLE = 0x00
    local SRAM_PROBE        = 0x2598  -- sPlayerName (01:A598): first letter, never 0xFF in a saved game

    function readSRAM(offset, length)
        local sram = emu.memory.sram
        if not sram then return nil end
        if sram:read8(SRAM_PROBE) ~= 0xFF then        -- already on: just read
            return sram:readRange(offset, length)
        end
        emu:write8(rRAMG, RAMG_SRAM_ENABLE)
        local data = sram:readRange(offset, length)
        emu:write8(rRAMG, RAMG_SRAM_DISABLE)
        return data
    end
end

-- ROM tables (bank:addr -> bank * 0x4000 + (addr - 0x4000))
local MoveNames      = 0xBC000 -- 2F:4000, names back to back, each ending in 0x50
local Moves          = 0x38000 -- 0E:4000, 6 bytes per move: anim, effect, power, type, accuracy, PP
local BaseStats      = 0x383DE -- 0E:43DE, BASE_DATA_SIZE bytes per Pokemon in Pokedex order (Mew included):
                               --   dex, hp, atk, def, spd, spc, type1, type2, catch rate, ...
local BASE_DATA_SIZE = 28
local ItemPrices     = 0x4494  -- 01:4494, 3-byte BCD price per item
local TMPrices       = 0xF65F5 -- 3D:65F5, one nybble per TM, in thousands
local KeyItemFlags   = 0xE6DD  -- 03:66DD, one bit per item: 1 = key item (can't be sold)

local TYPE_NAMES = {
    [0x00] = "NORMAL", [0x01] = "FIGHTING", [0x02] = "FLYING", [0x03] = "POISON",
    [0x04] = "GROUND", [0x05] = "ROCK",     [0x07] = "BUG",    [0x08] = "GHOST",
    [0x14] = "FIRE",   [0x15] = "WATER",    [0x16] = "GRASS",  [0x17] = "ELECTRIC",
    [0x18] = "PSYCHIC", [0x19] = "ICE",     [0x1A] = "DRAGON",
}

-- Pokedex: one bit per species, bit (dex number - 1), 19 bytes each
local wPokedexOwned  = 0xD2F6
local wPokedexSeen   = 0xD309
local POKEDEX_BYTES  = 19
local NUM_POKEMON    = 151

-- Hidden items per map, generated from pret/pokeyellow:
--   data/events/hidden_events.asm      (position + item)
--   data/events/hidden_item_coords.asm (order = flag index in wObtainedHiddenItemsFlags)
local HIDDEN_ITEMS = {
    [0xD2] = { -- SILPH_CO_5F
        { x = 12, y =   3, item = 0x52, flag =  0 }, -- ELIXER
    },
    [0xE9] = { -- SILPH_CO_9F
        { x =  2, y =  15, item = 0x11, flag =  1 }, -- MAX_POTION
    },
    [0xD7] = { -- POKEMON_MANSION_3F
        { x =  1, y =   9, item = 0x36, flag =  2 }, -- MAX_REVIVE
    },
    [0xD8] = { -- POKEMON_MANSION_B1F
        { x =  1, y =   9, item = 0x28, flag =  3 }, -- RARE_CANDY
    },
    [0xDB] = { -- SAFARI_ZONE_WEST
        { x =  6, y =   5, item = 0x35, flag =  4 }, -- REVIVE
    },
    [0xE2] = { -- CERULEAN_CAVE_2F
        { x = 16, y =  13, item = 0x4F, flag =  5 }, -- PP_UP
    },
    [0xE3] = { -- CERULEAN_CAVE_B1F
        { x =  8, y =  14, item = 0x4F, flag =  6 }, -- PP_UP
    },
    [0x6F] = { -- UNUSED_MAP_6F
        { x = 14, y =  11, item = 0x53, flag =  7 }, -- MAX_ELIXER
    },
    [0xA0] = { -- SEAFOAM_ISLANDS_B2F
        { x = 15, y =  15, item = 0x31, flag =  8 }, -- NUGGET
    },
    [0xA1] = { -- SEAFOAM_ISLANDS_B3F
        { x =  9, y =  16, item = 0x53, flag =  9 }, -- MAX_ELIXER
    },
    [0xA2] = { -- SEAFOAM_ISLANDS_B4F
        { x = 25, y =  17, item = 0x02, flag = 10 }, -- ULTRA_BALL
    },
    [0x33] = { -- VIRIDIAN_FOREST
        { x =  1, y =  18, item = 0x14, flag = 11 }, -- POTION
        { x = 16, y =  42, item = 0x0B, flag = 12 }, -- ANTIDOTE
    },
    [0x3D] = { -- MT_MOON_B2F
        { x = 18, y =  12, item = 0x0A, flag = 13 }, -- MOON_STONE
        { x = 33, y =   9, item = 0x50, flag = 14 }, -- ETHER
    },
    [0x68] = { -- SS_ANNE_B1F_ROOMS
        { x =  3, y =   1, item = 0x12, flag = 15 }, -- HYPER_POTION
    },
    [0x64] = { -- SS_ANNE_KITCHEN
        { x = 13, y =   9, item = 0x03, flag = 16 }, -- GREAT_BALL
    },
    [0x77] = { -- UNDERGROUND_PATH_NORTH_SOUTH
        { x =  3, y =   4, item = 0x10, flag = 17 }, -- FULL_RESTORE
        { x =  4, y =  34, item = 0x44, flag = 18 }, -- X_SPECIAL
    },
    [0x79] = { -- UNDERGROUND_PATH_WEST_EAST
        { x = 12, y =   2, item = 0x31, flag = 19 }, -- NUGGET
        { x = 21, y =   5, item = 0x52, flag = 20 }, -- ELIXER
    },
    [0xC7] = { -- ROCKET_HIDEOUT_B1F
        { x = 21, y =  15, item = 0x4F, flag = 21 }, -- PP_UP
    },
    [0xC9] = { -- ROCKET_HIDEOUT_B3F
        { x = 27, y =  17, item = 0x31, flag = 22 }, -- NUGGET
    },
    [0xCA] = { -- ROCKET_HIDEOUT_B4F
        { x = 25, y =   1, item = 0x13, flag = 23 }, -- SUPER_POTION
    },
    [0x15] = { -- ROUTE_10
        { x =  9, y =  17, item = 0x13, flag = 24 }, -- SUPER_POTION
        { x = 16, y =  53, item = 0x51, flag = 25 }, -- MAX_ETHER
    },
    [0x53] = { -- POWER_PLANT
        { x = 17, y =  16, item = 0x53, flag = 26 }, -- MAX_ELIXER
        { x = 12, y =   1, item = 0x4F, flag = 27 }, -- PP_UP
    },
    [0x16] = { -- ROUTE_11
        { x = 48, y =   5, item = 0x1D, flag = 28 }, -- ESCAPE_ROPE
    },
    [0x17] = { -- ROUTE_12
        { x =  2, y =  63, item = 0x12, flag = 29 }, -- HYPER_POTION
    },
    [0x18] = { -- ROUTE_13
        { x =  1, y =  14, item = 0x4F, flag = 30 }, -- PP_UP
        { x = 16, y =  13, item = 0x27, flag = 31 }, -- CALCIUM
    },
    [0x1C] = { -- ROUTE_17
        { x = 15, y =  14, item = 0x28, flag = 32 }, -- RARE_CANDY
        { x =  8, y =  45, item = 0x10, flag = 33 }, -- FULL_RESTORE
        { x = 17, y =  72, item = 0x4F, flag = 34 }, -- PP_UP
        { x =  4, y =  91, item = 0x36, flag = 35 }, -- MAX_REVIVE
        { x =  8, y = 121, item = 0x53, flag = 36 }, -- MAX_ELIXER
    },
    [0x22] = { -- ROUTE_23
        { x =  9, y =  44, item = 0x10, flag = 37 }, -- FULL_RESTORE
        { x = 19, y =  70, item = 0x02, flag = 38 }, -- ULTRA_BALL
        { x =  8, y =  90, item = 0x51, flag = 39 }, -- MAX_ETHER
    },
    [0xC2] = { -- VICTORY_ROAD_2F
        { x =  5, y =   2, item = 0x02, flag = 40 }, -- ULTRA_BALL
        { x = 26, y =   7, item = 0x10, flag = 41 }, -- FULL_RESTORE
    },
    [0x24] = { -- ROUTE_25
        { x = 38, y =   3, item = 0x50, flag = 42 }, -- ETHER
        { x = 10, y =   1, item = 0x52, flag = 43 }, -- ELIXER
    },
    [0x0F] = { -- ROUTE_4
        { x = 40, y =   3, item = 0x03, flag = 44 }, -- GREAT_BALL
    },
    [0x14] = { -- ROUTE_9
        { x = 14, y =   7, item = 0x50, flag = 45 }, -- ETHER
    },
    [0xB0] = { -- COPYCATS_HOUSE_2F
        { x =  1, y =   1, item = 0x31, flag = 46 }, -- NUGGET
    },
    [0x01] = { -- VIRIDIAN_CITY
        { x = 14, y =   4, item = 0x14, flag = 47 }, -- POTION
    },
    [0x03] = { -- CERULEAN_CITY
        { x = 15, y =   8, item = 0x28, flag = 48 }, -- RARE_CANDY
    },
    [0xE4] = { -- CERULEAN_CAVE_1F
        { x = 18, y =   7, item = 0x4F, flag = 49 }, -- PP_UP
    },
    [0x92] = { -- POKEMON_TOWER_5F
        { x =  4, y =  12, item = 0x52, flag = 50 }, -- ELIXER
    },
    [0x05] = { -- VERMILION_CITY
        { x = 14, y =  11, item = 0x51, flag = 51 }, -- MAX_ETHER
    },
    [0x06] = { -- CELADON_CITY
        { x = 48, y =  15, item = 0x4F, flag = 52 }, -- PP_UP
    },
    [0x9C] = { -- SAFARI_ZONE_GATE
        { x = 10, y =   1, item = 0x31, flag = 53 }, -- NUGGET
    },
    [0xA5] = { -- POKEMON_MANSION_1F
        { x =  8, y =  16, item = 0x0A, flag = 54 }, -- MOON_STONE
    },
}

-- Map ID -> name, generated from constants/map_constants.asm in pret/pokeyellow
local MAP_NAMES = {
    [0x00] = "Pallet Town",
    [0x01] = "Viridian City",
    [0x02] = "Pewter City",
    [0x03] = "Cerulean City",
    [0x04] = "Lavender Town",
    [0x05] = "Vermilion City",
    [0x06] = "Celadon City",
    [0x07] = "Fuchsia City",
    [0x08] = "Cinnabar Island",
    [0x09] = "Indigo Plateau",
    [0x0A] = "Saffron City",
    [0x0B] = "Unused Map 0B",
    [0x0C] = "Route 1",
    [0x0D] = "Route 2",
    [0x0E] = "Route 3",
    [0x0F] = "Route 4",
    [0x10] = "Route 5",
    [0x11] = "Route 6",
    [0x12] = "Route 7",
    [0x13] = "Route 8",
    [0x14] = "Route 9",
    [0x15] = "Route 10",
    [0x16] = "Route 11",
    [0x17] = "Route 12",
    [0x18] = "Route 13",
    [0x19] = "Route 14",
    [0x1A] = "Route 15",
    [0x1B] = "Route 16",
    [0x1C] = "Route 17",
    [0x1D] = "Route 18",
    [0x1E] = "Route 19",
    [0x1F] = "Route 20",
    [0x20] = "Route 21",
    [0x21] = "Route 22",
    [0x22] = "Route 23",
    [0x23] = "Route 24",
    [0x24] = "Route 25",
    [0x25] = "Reds House 1F",
    [0x26] = "Reds House 2F",
    [0x27] = "Blues House",
    [0x28] = "Oaks Lab",
    [0x29] = "Viridian Pokecenter",
    [0x2A] = "Viridian Mart",
    [0x2B] = "Viridian School House",
    [0x2C] = "Viridian Nickname House",
    [0x2D] = "Viridian Gym",
    [0x2E] = "Digletts Cave Route 2",
    [0x2F] = "Viridian Forest North Gate",
    [0x30] = "Route 2 Trade House",
    [0x31] = "Route 2 Gate",
    [0x32] = "Viridian Forest South Gate",
    [0x33] = "Viridian Forest",
    [0x34] = "Museum 1F",
    [0x35] = "Museum 2F",
    [0x36] = "Pewter Gym",
    [0x37] = "Pewter Nidoran House",
    [0x38] = "Pewter Mart",
    [0x39] = "Pewter Speech House",
    [0x3A] = "Pewter Pokecenter",
    [0x3B] = "Mt. Moon 1F",
    [0x3C] = "Mt. Moon B1F",
    [0x3D] = "Mt. Moon B2F",
    [0x3E] = "Cerulean Trashed House",
    [0x3F] = "Cerulean Melanies House",
    [0x40] = "Cerulean Pokecenter",
    [0x41] = "Cerulean Gym",
    [0x42] = "Bike Shop",
    [0x43] = "Cerulean Mart",
    [0x44] = "Mt. Moon Pokecenter",
    [0x45] = "Cerulean Trashed House Copy",
    [0x46] = "Route 5 Gate",
    [0x47] = "Underground Path Route 5",
    [0x48] = "Daycare",
    [0x49] = "Route 6 Gate",
    [0x4A] = "Underground Path Route 6",
    [0x4B] = "Underground Path Route 6 Copy",
    [0x4C] = "Route 7 Gate",
    [0x4D] = "Underground Path Route 7",
    [0x4E] = "Underground Path Route 7 Copy",
    [0x4F] = "Route 8 Gate",
    [0x50] = "Underground Path Route 8",
    [0x51] = "Rock Tunnel Pokecenter",
    [0x52] = "Rock Tunnel 1F",
    [0x53] = "Power Plant",
    [0x54] = "Route 11 Gate 1F",
    [0x55] = "Digletts Cave Route 11",
    [0x56] = "Route 11 Gate 2F",
    [0x57] = "Route 12 Gate 1F",
    [0x58] = "Bills House",
    [0x59] = "Vermilion Pokecenter",
    [0x5A] = "Pokemon Fan Club",
    [0x5B] = "Vermilion Mart",
    [0x5C] = "Vermilion Gym",
    [0x5D] = "Vermilion Pidgey House",
    [0x5E] = "Vermilion Dock",
    [0x5F] = "S.S. Anne 1F",
    [0x60] = "S.S. Anne 2F",
    [0x61] = "S.S. Anne 3F",
    [0x62] = "S.S. Anne B1F",
    [0x63] = "S.S. Anne Bow",
    [0x64] = "S.S. Anne Kitchen",
    [0x65] = "S.S. Anne Captains Room",
    [0x66] = "S.S. Anne 1F Rooms",
    [0x67] = "S.S. Anne 2F Rooms",
    [0x68] = "S.S. Anne B1F Rooms",
    [0x69] = "Unused Map 69",
    [0x6A] = "Unused Map 6A",
    [0x6B] = "Unused Map 6B",
    [0x6C] = "Victory Road 1F",
    [0x6D] = "Unused Map 6D",
    [0x6E] = "Unused Map 6E",
    [0x6F] = "Unused Map 6F",
    [0x70] = "Unused Map 70",
    [0x71] = "Lances Room",
    [0x72] = "Unused Map 72",
    [0x73] = "Unused Map 73",
    [0x74] = "Unused Map 74",
    [0x75] = "Unused Map 75",
    [0x76] = "Hall Of Fame",
    [0x77] = "Underground Path North South",
    [0x78] = "Champions Room",
    [0x79] = "Underground Path West East",
    [0x7A] = "Celadon Mart 1F",
    [0x7B] = "Celadon Mart 2F",
    [0x7C] = "Celadon Mart 3F",
    [0x7D] = "Celadon Mart 4F",
    [0x7E] = "Celadon Mart Roof",
    [0x7F] = "Celadon Mart Elevator",
    [0x80] = "Celadon Mansion 1F",
    [0x81] = "Celadon Mansion 2F",
    [0x82] = "Celadon Mansion 3F",
    [0x83] = "Celadon Mansion Roof",
    [0x84] = "Celadon Mansion Roof House",
    [0x85] = "Celadon Pokecenter",
    [0x86] = "Celadon Gym",
    [0x87] = "Game Corner",
    [0x88] = "Celadon Mart 5F",
    [0x89] = "Game Corner Prize Room",
    [0x8A] = "Celadon Diner",
    [0x8B] = "Celadon Chief House",
    [0x8C] = "Celadon Hotel",
    [0x8D] = "Lavender Pokecenter",
    [0x8E] = "Pokemon Tower 1F",
    [0x8F] = "Pokemon Tower 2F",
    [0x90] = "Pokemon Tower 3F",
    [0x91] = "Pokemon Tower 4F",
    [0x92] = "Pokemon Tower 5F",
    [0x93] = "Pokemon Tower 6F",
    [0x94] = "Pokemon Tower 7F",
    [0x95] = "Mr Fujis House",
    [0x96] = "Lavender Mart",
    [0x97] = "Lavender Cubone House",
    [0x98] = "Fuchsia Mart",
    [0x99] = "Fuchsia Bills Grandpas House",
    [0x9A] = "Fuchsia Pokecenter",
    [0x9B] = "Wardens House",
    [0x9C] = "Safari Zone Gate",
    [0x9D] = "Fuchsia Gym",
    [0x9E] = "Fuchsia Meeting Room",
    [0x9F] = "Seafoam Islands B1F",
    [0xA0] = "Seafoam Islands B2F",
    [0xA1] = "Seafoam Islands B3F",
    [0xA2] = "Seafoam Islands B4F",
    [0xA3] = "Vermilion Old Rod House",
    [0xA4] = "Fuchsia Good Rod House",
    [0xA5] = "Pokemon Mansion 1F",
    [0xA6] = "Cinnabar Gym",
    [0xA7] = "Cinnabar Lab",
    [0xA8] = "Cinnabar Lab Trade Room",
    [0xA9] = "Cinnabar Lab Metronome Room",
    [0xAA] = "Cinnabar Lab Fossil Room",
    [0xAB] = "Cinnabar Pokecenter",
    [0xAC] = "Cinnabar Mart",
    [0xAD] = "Cinnabar Mart Copy",
    [0xAE] = "Indigo Plateau Lobby",
    [0xAF] = "Copycats House 1F",
    [0xB0] = "Copycats House 2F",
    [0xB1] = "Fighting Dojo",
    [0xB2] = "Saffron Gym",
    [0xB3] = "Saffron Pidgey House",
    [0xB4] = "Saffron Mart",
    [0xB5] = "Silph Co 1F",
    [0xB6] = "Saffron Pokecenter",
    [0xB7] = "Mr Psychics House",
    [0xB8] = "Route 15 Gate 1F",
    [0xB9] = "Route 15 Gate 2F",
    [0xBA] = "Route 16 Gate 1F",
    [0xBB] = "Route 16 Gate 2F",
    [0xBC] = "Route 16 Fly House",
    [0xBD] = "Route 12 Super Rod House",
    [0xBE] = "Route 18 Gate 1F",
    [0xBF] = "Route 18 Gate 2F",
    [0xC0] = "Seafoam Islands 1F",
    [0xC1] = "Route 22 Gate",
    [0xC2] = "Victory Road 2F",
    [0xC3] = "Route 12 Gate 2F",
    [0xC4] = "Vermilion Trade House",
    [0xC5] = "Digletts Cave",
    [0xC6] = "Victory Road 3F",
    [0xC7] = "Rocket Hideout B1F",
    [0xC8] = "Rocket Hideout B2F",
    [0xC9] = "Rocket Hideout B3F",
    [0xCA] = "Rocket Hideout B4F",
    [0xCB] = "Rocket Hideout Elevator",
    [0xCC] = "Unused Map Cc",
    [0xCD] = "Unused Map Cd",
    [0xCE] = "Unused Map Ce",
    [0xCF] = "Silph Co 2F",
    [0xD0] = "Silph Co 3F",
    [0xD1] = "Silph Co 4F",
    [0xD2] = "Silph Co 5F",
    [0xD3] = "Silph Co 6F",
    [0xD4] = "Silph Co 7F",
    [0xD5] = "Silph Co 8F",
    [0xD6] = "Pokemon Mansion 2F",
    [0xD7] = "Pokemon Mansion 3F",
    [0xD8] = "Pokemon Mansion B1F",
    [0xD9] = "Safari Zone East",
    [0xDA] = "Safari Zone North",
    [0xDB] = "Safari Zone West",
    [0xDC] = "Safari Zone Center",
    [0xDD] = "Safari Zone Center Rest House",
    [0xDE] = "Safari Zone Secret House",
    [0xDF] = "Safari Zone West Rest House",
    [0xE0] = "Safari Zone East Rest House",
    [0xE1] = "Safari Zone North Rest House",
    [0xE2] = "Cerulean Cave 2F",
    [0xE3] = "Cerulean Cave B1F",
    [0xE4] = "Cerulean Cave 1F",
    [0xE5] = "Name Raters House",
    [0xE6] = "Cerulean Badge House",
    [0xE7] = "Unused Map E7",
    [0xE8] = "Rock Tunnel B1F",
    [0xE9] = "Silph Co 9F",
    [0xEA] = "Silph Co 10F",
    [0xEB] = "Silph Co 11F",
    [0xEC] = "Silph Co Elevator",
    [0xED] = "Unused Map Ed",
    [0xEE] = "Unused Map Ee",
    [0xEF] = "Trade Center",
    [0xF0] = "Colosseum",
    [0xF1] = "Unused Map F1",
    [0xF2] = "Unused Map F2",
    [0xF3] = "Unused Map F3",
    [0xF4] = "Unused Map F4",
    [0xF5] = "Loreleis Room",
    [0xF6] = "Brunos Room",
    [0xF7] = "Agathas Room",
    [0xF8] = "Summer Beach House",
}
local LAST_OUTDOOR_MAP = 0x24  -- IDs 0x00-0x24 are towns and routes; higher IDs are indoors/dungeons

-- Badge names in bit order (constants/ram_constants.asm, BIT_BOULDERBADGE etc.)
local BADGE_NAMES = {
    [0] = "Boulder", "Cascade", "Thunder", "Rainbow",
          "Soul",    "Marsh",   "Volcano", "Earth",
}

-- ROM addresses (bank:addr from the sym file -> bank * 0x4000 + (addr - 0x4000))
local MonsterNames   = 0xE8000 -- 3A:4000, 10 bytes per name, in internal-ID order
local PokedexOrder   = 0x410B1 -- 10:50B1, internal ID -> Pokedex number

-- Game Boy Pokemon stores 16-bit numbers big-endian
local function read16BE(addr)
    return (emu:read8(addr) << 8) | emu:read8(addr + 1)
end

-- Minimal Gen 1 text decoder (enough for names)
local function decode(bytes)
    local out = {}
    for i = 1, #bytes do
        local b = bytes:byte(i)
        if b == 0x50 then break                                     -- terminator
        elseif b >= 0x80 and b <= 0x99 then out[#out + 1] = string.char(b - 0x80 + 65) -- A-Z
        elseif b >= 0xA0 and b <= 0xB9 then out[#out + 1] = string.char(b - 0xA0 + 97) -- a-z
        elseif b >= 0xF6 then out[#out + 1] = string.char(b - 0xF6 + 48)              -- 0-9
        elseif b == 0xBA then out[#out + 1] = "é"                                    -- POKé BALL
        elseif b == 0x7F then out[#out + 1] = " "
        elseif b == 0xE3 then out[#out + 1] = "-"
        elseif b == 0xE8 then out[#out + 1] = "."
        elseif b == 0xEF then out[#out + 1] = "(M)"
        elseif b == 0xF5 then out[#out + 1] = "(F)"
        else out[#out + 1] = "?" end
    end
    return table.concat(out)
end

-- Species bytes in RAM are *internal* IDs (Rhydon = 1), not Pokedex numbers
local function speciesName(id)
    if id == 0 then return "-" end
    return decode(emu.memory.cart0:readRange(MonsterNames + (id - 1) * 10, 10))
end

local function dexNumber(id)
    if id == 0 then return 0 end
    return emu.memory.cart0:read8(PokedexOrder + id - 1)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Read a BCD number: each byte holds two decimal digits (0x31 -> 31)
local function readBCD(addr, length)
    local value = 0
    for i = 0, length - 1 do
        local b = emu:read8(addr + i)
        value = value * 100 + (b >> 4) * 10 + (b & 0xF)
    end
    return value
end

-- BCD read from the ROM (emu:read8 only sees whichever ROM bank is switched in)
local function romBCD(addr, length)
    local value = 0
    for i = 0, length - 1 do
        local b = emu.memory.cart0:read8(addr + i)
        value = value * 100 + (b >> 4) * 10 + (b & 0xF)
    end
    return value
end

local function read24BE(addr)
    return (emu:read8(addr) << 16) | (emu:read8(addr + 1) << 8) | emu:read8(addr + 2)
end

local function mapName(id)
    return MAP_NAMES[id] or string.format("Unknown map (0x%02X)", id)
end

-- Test bit `index` in a flag array starting at `base` (8 flags per byte, lowest bit first)
local function testFlag(base, index)
    return (emu:read8(base + (index >> 3)) >> (index & 7)) & 1 == 1
end

-- Item ID -> name. Regular items are read from the ROM's ItemNames list;
-- TMs/HMs aren't in that list (the game builds "TM01" etc. itself), so do the same here.
local itemNameCache = {}
local function itemName(id)
    if id >= 0xC9 then return string.format("TM%02d", id - 0xC8) end
    if id >= 0xC4 then return string.format("HM%02d", id - 0xC3) end
    if itemNameCache[id] then return itemNameCache[id] end
    local addr = ItemNames
    for _ = 1, id - 1 do                       -- skip the names before this one
        while emu.memory.cart0:read8(addr) ~= 0x50 do addr = addr + 1 end
        addr = addr + 1
    end
    local name = decode(emu.memory.cart0:readRange(addr, 20))
    itemNameCache[id] = name
    return name
end

-- Move ID -> name, read from the ROM's MoveNames list (same layout as ItemNames)
local moveNameCache = {}
local function moveName(id)
    if moveNameCache[id] then return moveNameCache[id] end
    local addr = MoveNames
    for _ = 1, id - 1 do
        while emu.memory.cart0:read8(addr) ~= 0x50 do addr = addr + 1 end
        addr = addr + 1
    end
    local name = decode(emu.memory.cart0:readRange(addr, 20))
    moveNameCache[id] = name
    return name
end

-- Same rules as the Poke Mart: key items and HMs can't be sold; everything
-- else sells for half its price. Returns nil if it can't be sold.
local function sellPrice(id)
    if id >= 0xC4 and id < 0xC9 then return nil end          -- HMs
    if id >= 0xC9 then                                       -- TMs: nybble table, in thousands
        local t = id - 0xC9
        local b = emu.memory.cart0:read8(TMPrices + (t >> 1))
        local nybble = (t & 1 == 0) and (b >> 4) or (b & 0xF)
        return nybble * 1000 // 2
    end
    local keyByte = emu.memory.cart0:read8(KeyItemFlags + ((id - 1) >> 3))
    if (keyByte >> ((id - 1) & 7)) & 1 == 1 then return nil end   -- key item
    return romBCD(ItemPrices + (id - 1) * 3, 3) // 2
end

-- Status byte: bits 0-2 = sleep turns, bit 3 = poison, 4 = burn, 5 = freeze, 6 = paralysis
local function statusText(status, hp)
    if hp == 0 then return "FNT" end
    if status & 0x07 ~= 0 then return "SLP" end
    if status & 0x08 ~= 0 then return "PSN" end
    if status & 0x10 ~= 0 then return "BRN" end
    if status & 0x20 ~= 0 then return "FRZ" end
    if status & 0x40 ~= 0 then return "PAR" end
    return "OK"
end

-- Type IDs -> list of names (one entry for single-type Pokemon)
local function typeName(t)
    return TYPE_NAMES[t] or string.format("?%02X", t)
end
local function typeNames(t1, t2)
    if t1 == t2 then return { typeName(t1) } end
    return { typeName(t1), typeName(t2) }
end

-- wIsInBattle -> "none" / "wild" / "trainer"
local function battleKind()
    local b = emu:read8(wIsInBattle)
    if b == 1 then return "wild" end
    if b == 2 then return "trainer" end
    return "none"
end

-- Pokedex number -> internal species ID (the reverse of the ROM's PokedexOrder table).
-- Built once, the first time it's needed.
local dexToInternal
local function internalFromDex(dex)
    if not dexToInternal then
        dexToInternal = {}
        for id = 1, 190 do                     -- internal IDs go up to 190 (0xBE)
            local n = dexNumber(id)
            if n ~= 0 then dexToInternal[n] = id end   -- 0 = MissingNo. slots
        end
    end
    return dexToInternal[dex]
end

-- Item balls on the current map, read live from the game's object data
local function visibleItems()
    -- Which objects can be removed, and the flag that says whether they have been
    local toggleIndex = {}
    for i = 0, 31 do
        local obj = emu:read8(wToggleableObjectList + i * 2)
        if obj == 0xFF then break end
        toggleIndex[obj] = emu:read8(wToggleableObjectList + i * 2 + 1)
    end

    local list = {}
    for obj = 1, emu:read8(wNumSprites) do
        local extra = wMapSpriteExtraData + (obj - 1) * 2
        local itemId, unused = emu:read8(extra), emu:read8(extra + 1)
        if itemId ~= 0 and unused == 0 then    -- item balls store {item ID, 0}
            local state = wSprite01StateData2 + (obj - 1) * 0x10
            local flag = toggleIndex[obj]
            list[#list + 1] = {
                id = itemId,
                name = itemName(itemId),
                x = emu:read8(state + 5) - 4,
                y = emu:read8(state + 4) - 4,
                hidden = false,
                obtained = flag ~= nil and testFlag(wToggleableObjectFlags, flag),
            }
        end
    end
    return list
end

---------------------------------------------------------------------------
-- Pokemon structs (party_struct / battle_struct, macros/ram.asm)
---------------------------------------------------------------------------

-- During battle the active Pokemon on each side live in a separate "battle_struct".
-- Its HP/PP/stats are the live values; the party copy only catches up when the
-- Pokemon switches out or the battle ends.
local wBattleMon       = 0xD013  -- player's active Pokemon (battle_struct)
local wPlayerMonNumber = 0xCC2F  -- which party slot (0-5) is the player's active Pokemon
local wEnemyMonBattle  = 0xCFE4  -- enemy's active Pokemon (battle_struct) = wEnemyMon
local wEnemyPartyCount = 0xD89B
local wEnemyMons       = 0xD8A3  -- enemy trainer's party, 6 x 44-byte party_struct
local wTrainerName     = 0xD049  -- trainer class name (or rival's name), 0x50-terminated

-- Field offsets in the two struct types
local PARTY_OFS  = { hp = 1, status = 4, type1 = 5, type2 = 6, moves = 8, pp = 29, dvs = 27,
                     level = 33, maxHP = 34, atk = 36, def = 38, spe = 40, spc = 42 }
local BATTLE_OFS = { hp = 1, status = 4, type1 = 5, type2 = 6, moves = 8, pp = 25, dvs = 12,
                     level = 14, maxHP = 15, atk = 17, def = 19, spe = 21, spc = 23 }
local STAT_EXP_OFS = 17  -- party_struct only: 5 x 2-byte Stat Exp (HP, Atk, Def, Spe, Spc)

-- DVs (Gen 1 IVs, 0-15) packed in 2 bytes. The HP DV is built from the lowest bit of the other four.
local function splitDVs(dvs)
    local atk, def, spe, spc = (dvs >> 12) & 0xF, (dvs >> 8) & 0xF, (dvs >> 4) & 0xF, dvs & 0xF
    local hp = ((atk & 1) << 3) | ((def & 1) << 2) | ((spe & 1) << 1) | (spc & 1)
    return { hp = hp, atk = atk, def = def, spe = spe, spc = spc }
end

-- Build the Pokemon table every tab and the GUI use, from raw struct values:
--   species, hp, maxHP, level, status, type1, type2, atk, def, spe, spc,
--   dvs (packed 2 bytes), statExp {hp, atk, def, spe, spc}, moves {4 IDs}, pp {4 raw PP bytes}
local function buildMon(raw)
    local mon = {
        species   = raw.species,                     -- internal ID
        name      = speciesName(raw.species),
        dex       = dexNumber(raw.species),
        level     = raw.level,
        hp        = raw.hp,
        maxHP     = raw.maxHP,
        status    = raw.status,                      -- raw status byte
        condition = statusText(raw.status, raw.hp),  -- "OK", "FNT", "SLP", ...
        types     = typeNames(raw.type1, raw.type2),
        atk = raw.atk, def = raw.def, spe = raw.spe, spc = raw.spc,
        dv = splitDVs(raw.dvs),
        statExp = raw.statExp,                       -- Stat Exp (Gen 1 EVs, 0-65535 each)
        moves = {},
    }
    for m = 1, 4 do
        local move = raw.moves[m]
        if move ~= 0 then
            local ppByte = raw.pp[m]
            local basePP = emu.memory.cart0:read8(Moves + (move - 1) * 6 + 5)
            mon.moves[#mon.moves + 1] = {
                id    = move,
                name  = moveName(move),
                pp    = ppByte & 0x3F,
                maxPP = basePP + (basePP // 5) * (ppByte >> 6),   -- top 2 bits: PP Ups used
            }
        end
    end
    return mon
end

-- addr/ofs: where to read the Pokemon from (party_struct or battle_struct).
-- statExpAddr: a party_struct to take Stat Exp from, since battle_struct has none.
--   nil = no party data (wild Pokemon), shown as all zeros - which is what they really have.
local function readMon(addr, ofs, statExpAddr)
    local se = { 0, 0, 0, 0, 0 }
    if statExpAddr then
        for s = 1, 5 do se[s] = read16BE(statExpAddr + STAT_EXP_OFS + (s - 1) * 2) end
    end
    local raw = {
        species = emu:read8(addr),
        hp      = read16BE(addr + ofs.hp),
        maxHP   = read16BE(addr + ofs.maxHP),
        level   = emu:read8(addr + ofs.level),
        status  = emu:read8(addr + ofs.status),
        type1   = emu:read8(addr + ofs.type1),
        type2   = emu:read8(addr + ofs.type2),
        atk = read16BE(addr + ofs.atk), def = read16BE(addr + ofs.def),
        spe = read16BE(addr + ofs.spe), spc = read16BE(addr + ofs.spc),
        dvs     = read16BE(addr + ofs.dvs),
        statExp = { hp = se[1], atk = se[2], def = se[3], spe = se[4], spc = se[5] },
        moves = {}, pp = {},
    }
    for m = 1, 4 do
        raw.moves[m] = emu:read8(addr + ofs.moves + m - 1)
        raw.pp[m]    = emu:read8(addr + ofs.pp + m - 1)
    end
    return buildMon(raw)
end

-- Gen 1 stat formula (CalcStat in the disassembly). Stat Exp counts as
-- ceil(sqrt(statExp)), capped at 255, then divided by 4.
local function calcStat(base, dv, statExp, level, isHP)
    local root = 0
    while root < 255 and root * root < statExp do root = root + 1 end
    local value = (((base + dv) * 2 + root // 4) * level) // 100
    if isHP then return value + level + 10 end
    return value + 5
end

-- Box Pokemon don't store their level-based stats (box_struct has no MaxHP/Attack/...);
-- the game recalculates them from base stats, DVs, Stat Exp and level, so do the same.
local function calcStats(species, level, dvs, statExp)
    local dex = dexNumber(species)
    if dex < 1 or dex > NUM_POKEMON then
        return { hp = 0, atk = 0, def = 0, spe = 0, spc = 0 }   -- glitch Pokemon
    end
    local base = BaseStats + (dex - 1) * BASE_DATA_SIZE
    local function b(i) return emu.memory.cart0:read8(base + i) end
    local dv = splitDVs(dvs)
    return {
        hp  = calcStat(b(1), dv.hp,  statExp.hp,  level, true),
        atk = calcStat(b(2), dv.atk, statExp.atk, level),
        def = calcStat(b(3), dv.def, statExp.def, level),
        spe = calcStat(b(4), dv.spe, statExp.spe, level),
        spc = calcStat(b(5), dv.spc, statExp.spc, level),
    }
end

-- Parse one box (BOX_SIZE bytes, same layout in WRAM and SRAM) into a list of
-- Pokemon tables. Returns nil if the data isn't a valid box.
local BOX_MONS_OFS  = wBoxMons - wBoxDataStart
local BOX_OT_OFS    = wBoxMonOT - wBoxDataStart
local BOX_NICKS_OFS = wBoxMonNicks - wBoxDataStart
local function parseBox(data)
    local function u8(o) return data:byte(o + 1) end
    local function u16(o) return (u8(o) << 8) | u8(o + 1) end
    local function name(base, i) return decode(data:sub(base + i * NAME_LENGTH + 1, base + (i + 1) * NAME_LENGTH)) end

    local count = u8(0)   -- wBoxCount
    if count > MONS_PER_BOX then return nil end
    local mons = {}
    for i = 0, count - 1 do
        local a = BOX_MONS_OFS + i * BOX_MON_SIZE      -- box_struct (macros/ram.asm)
        local species, level, dvs = u8(a), u8(a + 3), u16(a + 27)
        local statExp = { hp = u16(a + 17), atk = u16(a + 19), def = u16(a + 21),
                          spe = u16(a + 23), spc = u16(a + 25) }
        local stats = calcStats(species, level, dvs, statExp)
        local mon = buildMon({
            species = species, hp = u16(a + 1), maxHP = stats.hp, level = level,
            status = u8(a + 4), type1 = u8(a + 5), type2 = u8(a + 6),
            atk = stats.atk, def = stats.def, spe = stats.spe, spc = stats.spc,
            dvs = dvs, statExp = statExp,
            moves = { u8(a + 8), u8(a + 9), u8(a + 10), u8(a + 11) },
            pp    = { u8(a + 29), u8(a + 30), u8(a + 31), u8(a + 32) },
        })
        mon.nickname = name(BOX_NICKS_OFS, i)
        mon.otName   = name(BOX_OT_OFS, i)
        mon.otID     = u16(a + 12)
        mon.exp      = (u8(a + 14) << 16) | (u8(a + 15) << 8) | u8(a + 16)
        mons[#mons + 1] = mon
    end
    return mons
end

-- A party Pokemon's nickname (party slot 0-5)
local function partyNickname(i)
    return decode(emu:readRange(wPartyMonNicks + i * NAME_LENGTH, NAME_LENGTH))
end

---------------------------------------------------------------------------
-- Getters: read the game and return plain tables (numbers, strings, booleans,
-- lists). No printing here - these tables are what the socket server will send.
---------------------------------------------------------------------------

local function getPlayer()
    local opt = emu:read8(wOptions)   -- constants/ram_constants.asm
    local map = emu:read8(wCurMap)

    -- Towns visited = Fly destinations (one bit per town map ID 0x00-0x0A)
    local fly = {}
    for town = 0, 10 do
        if testFlag(wTownVisitedFlag, town) then fly[#fly + 1] = MAP_NAMES[town] end
    end

    -- One bit per badge (bit 0 = Boulder ... bit 7 = Earth)
    local badgeFlags = emu:read8(wObtainedBadges)
    local badges = {}
    for bit = 0, 7 do
        badges[#badges + 1] = { name = BADGE_NAMES[bit], earned = (badgeFlags >> bit) & 1 == 1 }
    end

    return {
        name  = decode(emu:readRange(wPlayerName, NAME_LENGTH)),
        rival = decode(emu:readRange(wRivalName, NAME_LENGTH)),
        id    = read16BE(wPlayerID),
        playTime = {
            hours   = emu:read8(wPlayTimeHours),
            minutes = emu:read8(wPlayTimeMinutes),
            seconds = emu:read8(wPlayTimeSeconds),
            maxed   = emu:read8(wPlayTimeMaxed) ~= 0,
        },
        money = readBCD(wPlayerMoney, 3),
        coins = readBCD(wPlayerCoins, 2),
        map   = { id = map, name = mapName(map) },
        x     = emu:read8(wXCoord),
        y     = emu:read8(wYCoord),
        pikachu = { happiness = emu:read8(wPikachuHappiness), mood = emu:read8(wPikachuMood) },
        options = {
            textSpeed   = ({ [1] = "Fast", [3] = "Medium", [5] = "Slow" })[opt & 0x0F] or "?",
            animations  = (opt >> 7) & 1 == 0,
            battleStyle = (opt >> 6) & 1 == 1 and "Set" or "Shift",
            sound       = ({ [0] = "Mono", "Earphone1", "Earphone2", "Earphone3" })[(opt >> 4) & 3],
        },
        flyDestinations = fly,
        badges = badges,
    }
end

-- Returns nil while the game is still loading (party count is garbage)
local function getTeam()
    local count = emu:read8(wPartyCount)
    if count > 6 then return nil end
    local mons = {}
    for i = 0, count - 1 do
        local a = wPartyMons + i * PARTY_MON_SIZE
        local mon = readMon(a, PARTY_OFS, a)
        mon.nickname = partyNickname(i)
        mon.exp      = read24BE(a + 14)    -- party_struct Exp, 3 bytes
        mon.otID     = read16BE(a + 12)    -- party_struct OTID
        mon.otName   = decode(emu:readRange(wPartyMonOT + i * NAME_LENGTH, NAME_LENGTH))
        mons[#mons + 1] = mon
    end
    return { count = count, mons = mons }
end

-- An item list ({item ID, quantity} pairs, 0xFF-terminated) - the Bag and the PC use the
-- same format. Returns nil while the game is still loading. Item price is nil if it can't be sold.
local function readItemList(countAddr, listAddr, capacity)
    local count = emu:read8(countAddr)
    if count > capacity then return nil end
    local items = {}
    for i = 0, count - 1 do
        local id = emu:read8(listAddr + i * 2)
        if id == 0xFF then break end
        items[#items + 1] = {
            id    = id,
            name  = itemName(id),
            qty   = emu:read8(listAddr + i * 2 + 1),
            price = sellPrice(id),
        }
    end
    return { count = count, capacity = capacity, items = items }
end

local function getBag()
    return readItemList(wNumBagItems, wBagItems, BAG_ITEM_CAPACITY)
end

local function getPCItems()
    return readItemList(wNumBoxItems, wBoxItems, PC_ITEM_CAPACITY)
end

-- All 12 PC boxes. The current box is read from WRAM (live); the others from SRAM.
-- A box with unreadable = true couldn't be read (no SRAM access, or invalid data there) -
-- its contents are unknown, as opposed to an empty box.
local function getPCBoxes()
    local boxNum = emu:read8(wCurrentBoxNum)
    local current = (boxNum & 0x7F) + 1
    -- Until the player first switches boxes, the SRAM boxes aren't set up yet (they're empty)
    local savedBoxesUsed = boxNum & 0x80 ~= 0

    local boxes = {}
    for n = 1, NUM_BOXES do
        local box = { number = n, current = n == current, mons = {} }
        if n == current then
            box.mons = parseBox(emu:readRange(wBoxDataStart, BOX_SIZE)) or {}
        elseif savedBoxesUsed then
            local data = readSRAM(sBoxOffset(n), BOX_SIZE)
            local mons = data and parseBox(data)
            if mons then
                box.mons = mons
            else
                box.unreadable = true   -- no SRAM access, or the bytes there aren't a valid box
            end
        end
        box.count = #box.mons
        boxes[n] = box
    end
    return { currentBox = current, boxes = boxes }
end

-- entries[dex].status is "owned", "seen" or "unseen"; name is nil when unseen
local function getPokedex()
    local seen, owned, entries = 0, 0, {}
    for dex = 1, NUM_POKEMON do
        local isOwned = testFlag(wPokedexOwned, dex - 1)
        local isSeen  = testFlag(wPokedexSeen, dex - 1)
        if isSeen then seen = seen + 1 end
        if isOwned then owned = owned + 1 end
        local status = isOwned and "owned" or (isSeen and "seen" or "unseen")
        entries[dex] = {
            dex    = dex,
            status = status,
            name   = status ~= "unseen" and speciesName(internalFromDex(dex)) or nil,
        }
    end
    return { seen = seen, owned = owned, total = NUM_POKEMON, entries = entries }
end

local function getLocation()
    local map = emu:read8(wCurMap)
    local loc = {
        map   = { id = map, name = mapName(map) },
        x     = emu:read8(wXCoord),
        y     = emu:read8(wYCoord),
        items = visibleItems(),
    }
    -- Inside a building or dungeon, also note which town/route it belongs to
    if map > LAST_OUTDOOR_MAP then
        local last = emu:read8(wLastMap)
        loc.parentMap = { id = last, name = mapName(last) }
    end
    for _, h in ipairs(HIDDEN_ITEMS[map] or {}) do
        loc.items[#loc.items + 1] = {
            id = h.item, name = itemName(h.item), x = h.x, y = h.y, hidden = true,
            obtained = testFlag(wObtainedHiddenItemsFlags, h.flag),
        }
    end
    return loc
end

-- grassRate 0 = no grass encounters on this map (grass is then empty)
local function getWild()
    local wild = { battle = battleKind(), grassRate = emu:read8(wGrassRate), grass = {} }
    if wild.battle == "wild" then
        wild.enemy = readMon(wEnemyMon, BATTLE_OFS)
    end
    if wild.grassRate ~= 0 then
        for i = 0, 9 do
            local species = emu:read8(wGrassMons + i * 2 + 1)
            wild.grass[#wild.grass + 1] = {
                slot    = i + 1,
                level   = emu:read8(wGrassMons + i * 2),
                species = species,
                name    = speciesName(species),
                dex     = dexNumber(species),
            }
        end
    end
    return wild
end

-- Both sides of the current battle. The active Pokemon on each side is marked
-- active = true and read from its battle_struct (live values).
local function getBattle()
    local kind = battleKind()
    local b = { battle = kind }
    if kind == "none" then return b end

    -- Opponent
    if kind == "wild" then
        local mon = readMon(wEnemyMonBattle, BATTLE_OFS)
        mon.active = true
        b.opponent = { count = 1, mons = { mon } }
    else
        local count = emu:read8(wEnemyPartyCount)
        local activeSlot = emu:read8(wEnemyMonBattle + 3)   -- battle_struct PartyPos
        local mons = {}
        for i = 0, math.min(count, 6) - 1 do
            local party = wEnemyMons + i * PARTY_MON_SIZE
            local mon
            if i == activeSlot then
                mon = readMon(wEnemyMonBattle, BATTLE_OFS, party)
            else
                mon = readMon(party, PARTY_OFS, party)
            end
            mon.active = i == activeSlot
            mons[#mons + 1] = mon
        end
        b.opponent = { trainer = decode(emu:readRange(wTrainerName, 13)), count = count, mons = mons }
    end

    -- Player's team
    local count = emu:read8(wPartyCount)
    local activeSlot = emu:read8(wPlayerMonNumber)
    local mons = {}
    for i = 0, math.min(count, 6) - 1 do
        local party = wPartyMons + i * PARTY_MON_SIZE
        local mon
        if i == activeSlot then
            mon = readMon(wBattleMon, BATTLE_OFS, party)
        else
            mon = readMon(party, PARTY_OFS, party)
        end
        mon.active = i == activeSlot
        mon.nickname = partyNickname(i)
        mons[#mons + 1] = mon
    end
    b.player = { count = count, mons = mons }
    return b
end

---------------------------------------------------------------------------
-- Renderers: print a getter's table into a scripting-window buffer.
-- No memory reads here. The buffer is already cleared.
---------------------------------------------------------------------------

-- "Sparky (Pikachu)", or just "Pikachu" if it has no nickname
local function displayName(mon)
    if not mon.nickname or mon.nickname == mon.name then return mon.name end
    return mon.nickname .. " (" .. mon.name .. ")"
end

local function renderPlayer(buf, p)
    buf:print(string.format("Name:  %s   (ID %05d)\n", p.name, p.id))
    buf:print(string.format("Rival: %s\n", p.rival))

    local t = p.playTime
    buf:print(string.format("Play time: %d:%02d:%02d%s\n",
        t.hours, t.minutes, t.seconds, t.maxed and "  (maxed out)" or ""))

    buf:print(string.format("Money: ¥%d   Coins: %d\n", p.money, p.coins))
    buf:print(string.format("Position: %s (X %d, Y %d)\n", p.map.name, p.x, p.y))
    buf:print(string.format("Pikachu happiness: %d/255  (mood %d)\n",
        p.pikachu.happiness, p.pikachu.mood))

    local o = p.options
    buf:print(string.format("Options: Text %s, Animations %s, Style %s, Sound %s\n",
        o.textSpeed, o.animations and "On" or "Off", o.battleStyle, o.sound))

    local fly = p.flyDestinations
    buf:print(string.format("Fly destinations (%d/11): %s\n\n",
        #fly, #fly > 0 and table.concat(fly, ", ") or "none"))

    local count = 0
    for _, badge in ipairs(p.badges) do
        if badge.earned then count = count + 1 end
    end
    buf:print(string.format("Badges: %d/8\n", count))
    for _, badge in ipairs(p.badges) do
        buf:print(string.format("  [%s] %s Badge\n", badge.earned and "X" or " ", badge.name))
    end
end

local function renderTeam(buf, team)
    if not team then return end
    buf:print(string.format("Team (%d/6)\n", team.count))
    for i, mon in ipairs(team.mons) do
        buf:print(string.format("\n%d. %s  Lv %d  HP %d/%d  %s\n",
            i, displayName(mon), mon.level, mon.hp, mon.maxHP, mon.condition))
        buf:print(string.format("   Type:  %s\n", table.concat(mon.types, "/")))
        for m, mv in ipairs(mon.moves) do
            buf:print(string.format("   %s %-12s PP %2d/%2d\n",
                m == 1 and "Moves:" or "      ", mv.name, mv.pp, mv.maxPP))
        end
        buf:print(string.format("   Stats: Atk %d  Def %d  Spe %d  Spc %d\n",
            mon.atk, mon.def, mon.spe, mon.spc))
        local dv, se = mon.dv, mon.statExp
        buf:print(string.format("   DVs:   HP %d  Atk %d  Def %d  Spe %d  Spc %d\n",
            dv.hp, dv.atk, dv.def, dv.spe, dv.spc))
        buf:print(string.format("   StatXP: HP %d  Atk %d  Def %d  Spe %d  Spc %d\n",
            se.hp, se.atk, se.def, se.spe, se.spc))
        buf:print(string.format("   Exp: %d   OT: %s (ID %05d)\n", mon.exp, mon.otName, mon.otID))
    end
end

-- Shared by the Bag and PC Items tabs
local function renderItemList(buf, title, list)
    if not list then return end
    buf:print(string.format("%s (%d/%d)\n\n", title, list.count, list.capacity))
    buf:print(string.format("  %-12s %4s  %s\n", "Item", "Qty", "Sells for"))
    if #list.items == 0 then
        buf:print("  (empty)\n")
    end
    for _, it in ipairs(list.items) do
        buf:print(string.format("  %-12s x%3d  %s\n",
            it.name, it.qty, it.price and string.format("¥%d", it.price) or "invaluable"))
    end
end

local function renderBag(buf, bag) renderItemList(buf, "Bag", bag) end
local function renderPCItems(buf, items) renderItemList(buf, "PC items", items) end

-- 3 lines per Pokemon: summary, stats + DVs, moves (Stat Exp/OT/Exp are in the JSON)
local function renderPCBoxes(buf, pc)
    local total = 0
    for _, box in ipairs(pc.boxes) do total = total + box.count end
    buf:print(string.format("PC: %d Pokemon stored   (current box: %d)\n", total, pc.currentBox))

    for _, box in ipairs(pc.boxes) do
        local tag = box.current and "   <- current box" or ""
        if box.unreadable then
            buf:print(string.format("\nBox %d: (can't read this box from save RAM)%s\n", box.number, tag))
        elseif box.count == 0 then
            buf:print(string.format("\nBox %d: empty%s\n", box.number, tag))
        else
            buf:print(string.format("\nBox %d (%d/%d)%s\n", box.number, box.count, MONS_PER_BOX, tag))
        end
        for i, mon in ipairs(box.mons) do
            buf:print(string.format("  %2d. %-22s Lv %-3d HP %3d/%-3d %-3s  %s\n",
                i, displayName(mon), mon.level, mon.hp, mon.maxHP, mon.condition,
                table.concat(mon.types, "/")))
            local dv = mon.dv
            buf:print(string.format("      Atk %3d  Def %3d  Spe %3d  Spc %3d    DVs HP %2d Atk %2d Def %2d Spe %2d Spc %2d\n",
                mon.atk, mon.def, mon.spe, mon.spc, dv.hp, dv.atk, dv.def, dv.spe, dv.spc))
            local moves = {}
            for _, mv in ipairs(mon.moves) do
                moves[#moves + 1] = string.format("%s %d/%d", mv.name, mv.pp, mv.maxPP)
            end
            buf:print("      " .. table.concat(moves, ", ") .. "\n")
        end
    end
end

local function renderPokedex(buf, dex)
    buf:print(string.format("Seen:  %3d / %d\n", dex.seen, dex.total))
    buf:print(string.format("Owned: %3d / %d\n\n", dex.owned, dex.total))
    for _, e in ipairs(dex.entries) do
        -- Unseen entries look like the in-game Pokedex
        buf:print(string.format("  #%03d %-10s %s\n",
            e.dex, e.name or "----------", e.status ~= "unseen" and e.status or ""))
    end
end

local function renderLocation(buf, loc)
    buf:print(string.format("%s\n", loc.map.name))
    if loc.parentMap then
        buf:print(string.format("  (from %s)\n", loc.parentMap.name))
    end
    buf:print(string.format("  X %d, Y %d   [map 0x%02X]\n", loc.x, loc.y, loc.map.id))

    -- Items: [name, visibility, item finder needed]
    buf:print("\nItems: [Item Name, Hidden?, ItemFinder] Obtained?\n")
    if #loc.items == 0 then
        buf:print("  (none on this map)\n")
    end
    for _, it in ipairs(loc.items) do
        buf:print(string.format("  [%s, %s, %s]  %s  (X %d, Y %d)\n",
            it.name,
            it.hidden and "hidden" or "visible",
            it.hidden and "yes" or "no",
            it.obtained and "obtained" or "available",
            it.x, it.y))
    end
end

local function renderWild(buf, wild)
    if wild.battle == "wild" then
        local e = wild.enemy
        buf:print(string.format("WILD %s (#%03d)\n", e.name, e.dex))
        buf:print(string.format("  Lv %d   HP %d/%d\n", e.level, e.hp, e.maxHP))
        buf:print(string.format("  Atk %d  Def %d  Spe %d  Spc %d\n", e.atk, e.def, e.spe, e.spc))
        buf:print(string.format("  DVs  Atk %d  Def %d  Spe %d  Spc %d\n\n",
            e.dv.atk, e.dv.def, e.dv.spe, e.dv.spc))
    elseif wild.battle == "trainer" then
        buf:print("Trainer battle\n\n")
    else
        buf:print("Not in battle\n\n")
    end

    if wild.grassRate == 0 then
        buf:print("No grass encounters on this map\n")
    else
        buf:print(string.format("Grass encounters (rate %d/255 per step):\n", wild.grassRate))
        for _, g in ipairs(wild.grass) do
            buf:print(string.format("  slot %d: Lv%2d %s\n", g.slot, g.level, g.name))
        end
    end
end

local function printBattleMon(buf, slot, mon)
    buf:print(string.format("%s%d. %-22s Lv %-3d HP %3d/%-3d %s\n",
        mon.active and ">" or " ", slot, displayName(mon), mon.level, mon.hp, mon.maxHP,
        mon.condition == "FNT" and "FAINTED" or mon.condition))
    buf:print(string.format("     %s   Atk %d  Def %d  Spe %d  Spc %d\n",
        table.concat(mon.types, "/"), mon.atk, mon.def, mon.spe, mon.spc))
    buf:print(string.format("     IVs (DVs):       HP %2d  Atk %2d  Def %2d  Spe %2d  Spc %2d\n",
        mon.dv.hp, mon.dv.atk, mon.dv.def, mon.dv.spe, mon.dv.spc))
    local se = mon.statExp
    buf:print(string.format("     EVs (Stat Exp):  HP %d  Atk %d  Def %d  Spe %d  Spc %d\n",
        se.hp, se.atk, se.def, se.spe, se.spc))
    local moves = {}
    for _, mv in ipairs(mon.moves) do
        moves[#moves + 1] = string.format("%s %d/%d", mv.name, mv.pp, mv.maxPP)
    end
    buf:print("     " .. table.concat(moves, ", ") .. "\n")
end

local function renderBattle(buf, b)
    if b.battle == "none" then
        buf:print("Not in battle\n")
        return
    end

    if b.battle == "wild" then
        buf:print("WILD POKEMON\n")
    else
        buf:print(string.format("OPPONENT: %s (%d Pokemon)\n", b.opponent.trainer, b.opponent.count))
    end
    for i, mon in ipairs(b.opponent.mons) do
        printBattleMon(buf, i, mon)
    end

    buf:print(string.format("\nYOUR TEAM (%d Pokemon)\n", b.player.count))
    for i, mon in ipairs(b.player.mons) do
        printBattleMon(buf, i, mon)
    end
end

---------------------------------------------------------------------------
-- JSON encoder (mGBA has none built in)
---------------------------------------------------------------------------

-- Lua has one table type; JSON has arrays and objects. A table whose keys are
-- exactly 1..n is an array, anything else an object. An empty table becomes []
-- (every empty table in `state` is a list: an empty bag, no grass encounters...).
-- nil fields simply don't appear in the output.
local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n == #t
end

local JSON_ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function jsonString(s)
    -- %c = control characters; names are already UTF-8 so everything else passes through
    return '"' .. (s:gsub('[%c"\\]', function(c)
        return JSON_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)) .. '"'
end

local function encodeValue(v, out)
    local t = type(v)
    if t == "table" then
        if isArray(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encodeValue(v[i], out)
            end
            out[#out + 1] = "]"
        else
            -- Sorted keys: same data -> same text, so saved fixtures diff cleanly
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                local val = v[k]
                if val == nil then val = v[tonumber(k)] end   -- non-string key
                out[#out + 1] = jsonString(k)
                out[#out + 1] = ":"
                encodeValue(val, out)
            end
            out[#out + 1] = "}"
        end
    elseif t == "string" then
        out[#out + 1] = jsonString(v)
    elseif t == "number" then
        if math.type(v) == "integer" then
            out[#out + 1] = tostring(v)
        elseif v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"                       -- JSON has no NaN/inf
        else
            out[#out + 1] = string.format("%.14g", v)
        end
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    else
        out[#out + 1] = "null"
    end
end

local function jsonEncode(v)
    local out = {}
    encodeValue(v, out)
    return table.concat(out)
end

---------------------------------------------------------------------------
-- TCP server: every update, each connected client gets the whole `state` as
-- one line of JSON (newline-delimited JSON). Clients don't need to send anything.
---------------------------------------------------------------------------

local server
local clients = {}     -- id -> { sock = socket, pending = unsent part of the current message }
local nextClientID = 1

local function dropClient(id, reason)
    local c = clients[id]
    if not c then return end
    clients[id] = nil
    c.sock:close()
    console:log(string.format("[server] client %d disconnected%s", id, reason and (": " .. tostring(reason)) or ""))
end

-- Send as much of the pending message as the socket accepts right now. A slow
-- client keeps its unsent remainder and simply skips updates until it catches up.
local function flushClient(id)
    local c = clients[id]
    if not c or c.pending == "" then return end
    local sent, err = c.sock:send(c.pending)
    if type(sent) == "number" and sent >= 0 then
        c.pending = c.pending:sub(sent + 1)
    elseif err ~= socket.ERRORS.AGAIN then
        dropClient(id, err)
    end
end

-- We don't expect input, but read whatever arrives so it doesn't pile up,
-- and notice when the client goes away.
local function onClientData(id)
    local c = clients[id]
    if not c then return end
    while true do
        local data, err = c.sock:receive(1024)
        if not data then
            if err ~= socket.ERRORS.AGAIN then dropClient(id, err) end
            return
        end
    end
end

local function onAccept()
    local sock, err = server:accept()
    if not sock then
        console:error("[server] accept failed: " .. tostring(err))
        return
    end
    local id = nextClientID
    nextClientID = id + 1
    clients[id] = { sock = sock, pending = "" }
    sock:add("received", function() onClientData(id) end)
    sock:add("error", function() dropClient(id, "socket error") end)
    console:log(string.format("[server] client %d connected", id))
end

local function startServer()
    for port = SERVER_PORT, SERVER_PORT + 9 do
        local s, err = socket.bind("127.0.0.1", port)
        if s then
            local ok, listenErr = s:listen()
            if listenErr then
                s:close()
                console:error("[server] listen failed: " .. tostring(listenErr))
                return
            end
            server = s
            server:add("received", onAccept)
            console:log(string.format("[server] listening on 127.0.0.1:%d", port))
            return
        elseif err ~= socket.ERRORS.ADDRESS_IN_USE then
            console:error("[server] bind failed: " .. tostring(err))
            return
        end
    end
    console:error(string.format("[server] ports %d-%d are all in use", SERVER_PORT, SERVER_PORT + 9))
end

-- Message format: {"protocol":1,"game":"yellow","frame":N,"state":{...}}\n
-- Bump `protocol` when the shape of `state` changes in a way the GUI must know about.
local function broadcast(state, frame)
    if next(clients) == nil then return end     -- nobody listening: skip the encoding work
    local message = jsonEncode({ protocol = 1, game = "yellow", frame = frame, state = state }) .. "\n"
    for id, c in pairs(clients) do
        if c.pending == "" then c.pending = message end
        flushClient(id)
    end
end

startServer()

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

-- snapshot (optional): returns raw RAM bytes; the tab is only re-read and redrawn
-- when they change. Redrawing a long list 4 times a second would keep resetting
-- the scroll position. Tabs without one are redrawn every update.
local TABS = {
    { key = "player",   buf = bufPlayer,   get = getPlayer,   render = renderPlayer },
    { key = "team",     buf = bufTeam,     get = getTeam,     render = renderTeam,
      snapshot = function() return emu:readRange(wPartyCount, PARTY_DATA_END - wPartyCount) end },
    { key = "bag",      buf = bufBag,      get = getBag,      render = renderBag,
      snapshot = function() return emu:readRange(wNumBagItems, 42) end },
    { key = "pcItems",  buf = bufPCItems,  get = getPCItems,  render = renderPCItems,
      snapshot = function() return emu:readRange(wNumBoxItems, 1 + PC_ITEM_CAPACITY * 2 + 1) end },
    { key = "pcBoxes",  buf = bufPCBoxes,  get = getPCBoxes,  render = renderPCBoxes,
      -- current box number + live box in WRAM + both SRAM box banks (2 and 3),
      -- the latter only once the saved boxes are in use (see readSRAM)
      snapshot = function()
          local boxNum = emu:read8(wCurrentBoxNum)
          local saved = boxNum & 0x80 ~= 0 and readSRAM(2 * 0x2000, 2 * 0x2000) or ""
          return string.char(boxNum) .. emu:readRange(wBoxDataStart, BOX_SIZE) .. saved
      end },
    { key = "pokedex",  buf = bufPokedex,  get = getPokedex,  render = renderPokedex,
      -- owned + seen flag arrays are back to back
      snapshot = function() return emu:readRange(wPokedexOwned, POKEDEX_BYTES * 2) end },
    { key = "location", buf = bufLocation, get = getLocation, render = renderLocation },
    { key = "wild",     buf = bufWild,     get = getWild,     render = renderWild },
    { key = "battle",   buf = bufBattle,   get = getBattle,   render = renderBattle,
      snapshot = function()
          return string.char(emu:read8(wIsInBattle))
              .. emu:readRange(wBattleMon, 0x1D) .. emu:readRange(wEnemyMonBattle, 0x1D)
              .. emu:readRange(wPartyCount, wPartyMonOT - wPartyCount)
              .. emu:readRange(wEnemyPartyCount, 1 + 7 + 6 * PARTY_MON_SIZE)
              .. string.char(emu:read8(wPlayerMonNumber))
      end },
}

-- Latest data for every tab: state.player, state.team, state.bag, ...
-- This is what the socket server will send to the GUI.
local state = {}
local lastSnapshot = {}

local function refresh(tab)
    if tab.snapshot then
        local snap = tab.snapshot()
        if snap == lastSnapshot[tab.key] then return end
        lastSnapshot[tab.key] = snap
    end
    state[tab.key] = tab.get()
    tab.buf:clear()
    tab.render(tab.buf, state[tab.key])
end

local frames = 0
callbacks:add("frame", function()
    frames = frames + 1
    if frames % 15 == 0 then   -- 4 times a second is plenty
        for _, tab in ipairs(TABS) do
            refresh(tab)
        end
        broadcast(state, frames)
    end
end)
