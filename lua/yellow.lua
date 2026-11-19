-- Pokemon Yellow (USA) info panels for mGBA:
--   Player   - name, ID, rival, play time, money/coins, position, Pikachu, options, Fly spots, badges
--   Team     - party summary + moves, stats, DVs, stat exp, OT for each Pokemon
--   Bag      - items, quantities and sell prices
--   Pokedex  - seen/owned counts and the full list
--   Location - current map, position, and items (visible/hidden, obtained or not)
--   Wild     - the wild Pokemon you're fighting + this map's grass encounters
--   Battle   - both sides' Pokemon during a battle: HP, fainted/status, stats, moves
-- Addresses come from pret/pokeyellow's pokeyellow.sym (symbols branch).

-- Tabs appear in the scripting window in the order they're created
local bufPlayer   = console:createBuffer("Player")
local bufTeam     = console:createBuffer("Team")
local bufBag      = console:createBuffer("Bag")
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

-- RAM (WRAM) addresses
local wIsInBattle    = 0xD056  -- 0 = no battle, 1 = wild, 2 = trainer
local wEnemyMonNick  = 0xCFD9  -- 11 bytes, 0x50-terminated
local wEnemyMon      = 0xCFE4  -- start of the active enemy's battle struct
local wGrassRate     = 0xD886  -- encounter rate for grass on this map (0 = none)
local wGrassMons     = 0xD887  -- 10 entries of {level, species}
local wBagItems      = 0xD31D  -- Items in Bag
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

-- ROM tables (bank:addr -> bank * 0x4000 + (addr - 0x4000))
local MoveNames      = 0xBC000 -- 2F:4000, names back to back, each ending in 0x50
local Moves          = 0x38000 -- 0E:4000, 6 bytes per move: anim, effect, power, type, accuracy, PP
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

local function update()
    bufWild:clear()

    local battle = emu:read8(wIsInBattle)
    if battle == 1 then
        local species = emu:read8(wEnemyMon + 0)
        bufWild:print(string.format("WILD %s (#%03d)\n", speciesName(species), dexNumber(species)))
        bufWild:print(string.format("  Lv %d   HP %d/%d\n",
            emu:read8(0xCFF2),          -- wEnemyMonLevel
            read16BE(0xCFE5),           -- wEnemyMonHP
            read16BE(0xCFF3)))          -- wEnemyMonMaxHP
        bufWild:print(string.format("  Atk %d  Def %d  Spe %d  Spc %d\n",
            read16BE(0xCFF5), read16BE(0xCFF7), read16BE(0xCFF9), read16BE(0xCFFB)))
        local dvs = read16BE(0xCFF0)    -- wEnemyMonDVs (IVs)
        bufWild:print(string.format("  DVs  Atk %d  Def %d  Spe %d  Spc %d\n\n",
            (dvs >> 12) & 0xF, (dvs >> 8) & 0xF, (dvs >> 4) & 0xF, dvs & 0xF))
    elseif battle == 2 then
        bufWild:print("Trainer battle\n\n")
    else
        bufWild:print("Not in battle\n\n")
    end

    local rate = emu:read8(wGrassRate)
    if rate == 0 then
        bufWild:print("No grass encounters on this map\n")
    else
        bufWild:print(string.format("Grass encounters (rate %d/255 per step):\n", rate))
        for i = 0, 9 do
            local level   = emu:read8(wGrassMons + i * 2)
            local species = emu:read8(wGrassMons + i * 2 + 1)
            bufWild:print(string.format("  slot %d: Lv%2d %s\n", i + 1, level, speciesName(species)))
        end
    end
end

-- Read a BCD number: each byte holds two decimal digits (0x31 -> 31)
local function readBCD(addr, length)
    local value = 0
    for i = 0, length - 1 do
        local b = emu:read8(addr + i)
        value = value * 100 + (b >> 4) * 10 + (b & 0xF)
    end
    return value
end

-- Defined here (above updatePlayer) because a local function can only be
-- used by code written after it
local function mapName(id)
    return MAP_NAMES[id] or string.format("Unknown map (0x%02X)", id)
end

local function updatePlayer()
    bufPlayer:clear()

    local name  = decode(emu:readRange(wPlayerName, 11))
    local rival = decode(emu:readRange(wRivalName, 11))
    bufPlayer:print(string.format("Name:  %s   (ID %05d)\n", name, read16BE(wPlayerID)))
    bufPlayer:print(string.format("Rival: %s\n", rival))

    local maxed = emu:read8(wPlayTimeMaxed) ~= 0
    bufPlayer:print(string.format("Play time: %d:%02d:%02d%s\n",
        emu:read8(wPlayTimeHours), emu:read8(wPlayTimeMinutes), emu:read8(wPlayTimeSeconds),
        maxed and "  (maxed out)" or ""))

    local playerMoney = readBCD(wPlayerMoney, 3)
    bufPlayer:print(string.format("Money: ¥%d   Coins: %d\n", playerMoney, readBCD(wPlayerCoins, 2)))

    bufPlayer:print(string.format("Position: %s (X %d, Y %d)\n",
        mapName(emu:read8(wCurMap)), emu:read8(wXCoord), emu:read8(wYCoord)))

    bufPlayer:print(string.format("Pikachu happiness: %d/255  (mood %d)\n",
        emu:read8(wPikachuHappiness), emu:read8(wPikachuMood)))

    -- Options byte (constants/ram_constants.asm)
    local opt = emu:read8(wOptions)
    local textSpeed = ({ [1] = "Fast", [3] = "Medium", [5] = "Slow" })[opt & 0x0F] or "?"
    local sound = ({ [0] = "Mono", "Earphone1", "Earphone2", "Earphone3" })[(opt >> 4) & 3]
    bufPlayer:print(string.format("Options: Text %s, Animations %s, Style %s, Sound %s\n",
        textSpeed,
        (opt >> 7) & 1 == 1 and "Off" or "On",
        (opt >> 6) & 1 == 1 and "Set" or "Shift",
        sound))

    -- Towns visited = Fly destinations (one bit per town map ID 0x00-0x0A)
    local visited = {}
    for town = 0, 10 do
        if (emu:read8(wTownVisitedFlag + (town >> 3)) >> (town & 7)) & 1 == 1 then
            visited[#visited + 1] = MAP_NAMES[town]
        end
    end
    bufPlayer:print(string.format("Fly destinations (%d/11): %s\n\n",
        #visited, #visited > 0 and table.concat(visited, ", ") or "none"))

    -- Check each bit of the badge byte: (flags >> bit) & 1 is 1 if that badge is owned
    local flags = emu:read8(wObtainedBadges)
    local count = 0
    local lines = {}
    for bit = 0, 7 do
        local earned = (flags >> bit) & 1 == 1
        if earned then count = count + 1 end
        lines[#lines + 1] = string.format("  [%s] %s Badge\n", earned and "X" or " ", BADGE_NAMES[bit])
    end
    bufPlayer:print(string.format("Badges: %d/8\n", count))
    for _, line in ipairs(lines) do
        bufPlayer:print(line)
    end
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

local function updateLocation()
    bufLocation:clear()

    local map = emu:read8(wCurMap)
    bufLocation:print(string.format("%s\n", mapName(map)))

    -- Inside a building or dungeon, also show which town/route it belongs to
    if map > LAST_OUTDOOR_MAP then
        bufLocation:print(string.format("  (from %s)\n", mapName(emu:read8(wLastMap))))
    end

    bufLocation:print(string.format("  X %d, Y %d   [map 0x%02X]\n",
        emu:read8(wXCoord), emu:read8(wYCoord), map))

    -- Items: [name, visibility, item finder needed]
    local items = {}
    for _, it in ipairs(visibleItems()) do items[#items + 1] = it end
    for _, h in ipairs(HIDDEN_ITEMS[map] or {}) do
        items[#items + 1] = {
            name = itemName(h.item), x = h.x, y = h.y, hidden = true,
            obtained = testFlag(wObtainedHiddenItemsFlags, h.flag),
        }
    end

    bufLocation:print("\nItems: [Item Name, Hidden?, ItemFinder] Obtained?\n")
    if #items == 0 then
        bufLocation:print("  (none on this map)\n")
    end
    for _, it in ipairs(items) do
        bufLocation:print(string.format("  [%s, %s, %s]  %s  (X %d, Y %d)\n",
            it.name,
            it.hidden and "hidden" or "visible",
            it.hidden and "yes" or "no",
            it.obtained and "obtained" or "available",
            it.x, it.y))
    end
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

-- Snapshot of both flag arrays, so the list is only redrawn when something changes.
-- (Redrawing a 151-line list 4 times a second would keep resetting the scroll position.)
local lastDexSnapshot
local function updatePokedex()
    local snapshot = emu:readRange(wPokedexOwned, POKEDEX_BYTES * 2)  -- owned + seen are back to back
    if snapshot == lastDexSnapshot then return end
    lastDexSnapshot = snapshot

    local seenCount, ownedCount = 0, 0
    local lines = {}
    for dex = 1, NUM_POKEMON do
        local owned = testFlag(wPokedexOwned, dex - 1)
        local seen  = testFlag(wPokedexSeen, dex - 1)
        if seen then seenCount = seenCount + 1 end
        if owned then ownedCount = ownedCount + 1 end

        local name, status
        if owned then
            name, status = speciesName(internalFromDex(dex)), "owned"
        elseif seen then
            name, status = speciesName(internalFromDex(dex)), "seen"
        else
            name, status = "----------", ""          -- same as the in-game Pokedex
        end
        lines[#lines + 1] = string.format("  #%03d %-10s %s\n", dex, name, status)
    end

    bufPokedex:clear()
    bufPokedex:print(string.format("Seen:  %3d / %d\n", seenCount, NUM_POKEMON))
    bufPokedex:print(string.format("Owned: %3d / %d\n\n", ownedCount, NUM_POKEMON))
    for _, line in ipairs(lines) do
        bufPokedex:print(line)
    end
end

---------------------------------------------------------------------------
-- Team
---------------------------------------------------------------------------

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

local function typeText(t1, t2)
    local a = TYPE_NAMES[t1] or string.format("?%02X", t1)
    if t1 == t2 then return a end
    return a .. "/" .. (TYPE_NAMES[t2] or string.format("?%02X", t2))
end

local function read24BE(addr)
    return (emu:read8(addr) << 16) | (emu:read8(addr + 1) << 8) | emu:read8(addr + 2)
end

local lastTeamSnapshot
local function updateTeam()
    -- Only redraw when the party data changes (keeps your scroll position)
    local snapshot = emu:readRange(wPartyCount, PARTY_DATA_END - wPartyCount)
    if snapshot == lastTeamSnapshot then return end
    lastTeamSnapshot = snapshot

    bufTeam:clear()
    local count = emu:read8(wPartyCount)
    if count > 6 then return end               -- garbage while the game is still loading
    bufTeam:print(string.format("Team (%d/6)\n", count))

    for i = 0, count - 1 do
        local a = wPartyMons + i * PARTY_MON_SIZE
        local species  = speciesName(emu:read8(a))
        local nickname = decode(emu:readRange(wPartyMonNicks + i * NAME_LENGTH, NAME_LENGTH))
        local hp, maxHP = read16BE(a + 1), read16BE(a + 34)

        -- Summary line: show the nickname only if it differs from the species name
        local title = species
        if nickname ~= species then title = nickname .. " (" .. species .. ")" end
        bufTeam:print(string.format("\n%d. %s  Lv %d  HP %d/%d  %s\n",
            i + 1, title, emu:read8(a + 33), hp, maxHP, statusText(emu:read8(a + 4), hp)))

        -- Details
        bufTeam:print(string.format("   Type:  %s\n", typeText(emu:read8(a + 5), emu:read8(a + 6))))

        for m = 0, 3 do
            local move = emu:read8(a + 8 + m)
            if move ~= 0 then
                local ppByte = emu:read8(a + 29 + m)
                local ppUps  = ppByte >> 6             -- top 2 bits: PP Ups used
                local basePP = emu.memory.cart0:read8(Moves + (move - 1) * 6 + 5)
                local maxPP  = basePP + (basePP // 5) * ppUps
                bufTeam:print(string.format("   %s %-12s PP %2d/%2d\n",
                    m == 0 and "Moves:" or "      ", moveName(move), ppByte & 0x3F, maxPP))
            end
        end

        bufTeam:print(string.format("   Stats: Atk %d  Def %d  Spe %d  Spc %d\n",
            read16BE(a + 36), read16BE(a + 38), read16BE(a + 40), read16BE(a + 42)))

        -- DVs (Gen 1 IVs, 0-15). The HP DV is built from the lowest bit of the other four.
        local dvs = read16BE(a + 27)
        local atk, def, spe, spc = (dvs >> 12) & 0xF, (dvs >> 8) & 0xF, (dvs >> 4) & 0xF, dvs & 0xF
        local hpDV = ((atk & 1) << 3) | ((def & 1) << 2) | ((spe & 1) << 1) | (spc & 1)
        bufTeam:print(string.format("   DVs:   HP %d  Atk %d  Def %d  Spe %d  Spc %d\n",
            hpDV, atk, def, spe, spc))

        -- Stat Exp (Gen 1 EVs, 0-65535 each)
        bufTeam:print(string.format("   StatXP: HP %d  Atk %d  Def %d  Spe %d  Spc %d\n",
            read16BE(a + 17), read16BE(a + 19), read16BE(a + 21), read16BE(a + 23), read16BE(a + 25)))

        local ot = decode(emu:readRange(wPartyMonOT + i * NAME_LENGTH, NAME_LENGTH))
        bufTeam:print(string.format("   Exp: %d   OT: %s (ID %05d)\n",
            read24BE(a + 14), ot, read16BE(a + 12)))
    end
end

---------------------------------------------------------------------------
-- Bag
---------------------------------------------------------------------------

-- BCD read from the ROM (emu:read8 only sees whichever ROM bank is switched in)
local function romBCD(addr, length)
    local value = 0
    for i = 0, length - 1 do
        local b = emu.memory.cart0:read8(addr + i)
        value = value * 100 + (b >> 4) * 10 + (b & 0xF)
    end
    return value
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

local lastBagSnapshot
local function updateBag()
    local snapshot = emu:readRange(wNumBagItems, 42)
    if snapshot == lastBagSnapshot then return end
    lastBagSnapshot = snapshot

    bufBag:clear()
    local count = emu:read8(wNumBagItems)
    if count > 20 then return end
    bufBag:print(string.format("Bag (%d/20)\n\n", count))
    bufBag:print(string.format("  %-12s %4s  %s\n", "Item", "Qty", "Sells for"))

    for i = 0, count - 1 do
        local id  = emu:read8(wBagItems + i * 2)
        local qty = emu:read8(wBagItems + i * 2 + 1)
        if id == 0xFF then break end
        local price = sellPrice(id)
        bufBag:print(string.format("  %-12s x%3d  %s\n",
            itemName(id), qty, price and string.format("¥%d", price) or "invaluable"))
    end
end

---------------------------------------------------------------------------
-- Battle
---------------------------------------------------------------------------

-- During battle the active Pokemon on each side live in a separate "battle_struct"
-- (macros/ram.asm). Its HP/PP/stats are the live values; the party copy only
-- catches up when the Pokemon switches out or the battle ends.
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

-- addr/ofs: where to read the Pokemon from (party_struct or battle_struct).
-- statExpAddr: a party_struct to take Stat Exp from, since battle_struct has none.
--   nil = no party data (wild Pokemon), shown as all zeros - which is what they really have.
local function readMon(addr, ofs, statExpAddr)
    local dvs = read16BE(addr + ofs.dvs)
    local atkDV, defDV, speDV, spcDV = (dvs >> 12) & 0xF, (dvs >> 8) & 0xF, (dvs >> 4) & 0xF, dvs & 0xF
    local statExp = { 0, 0, 0, 0, 0 }
    if statExpAddr then
        for s = 1, 5 do statExp[s] = read16BE(statExpAddr + STAT_EXP_OFS + (s - 1) * 2) end
    end

    local mon = {
        dv = {
            hp  = ((atkDV & 1) << 3) | ((defDV & 1) << 2) | ((speDV & 1) << 1) | (spcDV & 1),
            atk = atkDV, def = defDV, spe = speDV, spc = spcDV,
        },
        statExp = statExp,
        species = emu:read8(addr),
        hp      = read16BE(addr + ofs.hp),
        maxHP   = read16BE(addr + ofs.maxHP),
        level   = emu:read8(addr + ofs.level),
        status  = emu:read8(addr + ofs.status),
        type1   = emu:read8(addr + ofs.type1),
        type2   = emu:read8(addr + ofs.type2),
        atk = read16BE(addr + ofs.atk), def = read16BE(addr + ofs.def),
        spe = read16BE(addr + ofs.spe), spc = read16BE(addr + ofs.spc),
        moves = {},
    }
    for m = 0, 3 do
        local move = emu:read8(addr + ofs.moves + m)
        if move ~= 0 then
            local ppByte = emu:read8(addr + ofs.pp + m)
            local basePP = emu.memory.cart0:read8(Moves + (move - 1) * 6 + 5)
            mon.moves[#mon.moves + 1] = {
                name = moveName(move),
                pp = ppByte & 0x3F,
                maxPP = basePP + (basePP // 5) * (ppByte >> 6),
            }
        end
    end
    return mon
end

local function printBattleMon(slot, name, mon, active)
    bufBattle:print(string.format("%s%d. %-22s Lv %-3d HP %3d/%-3d %s\n",
        active and ">" or " ", slot, name, mon.level, mon.hp, mon.maxHP,
        mon.hp == 0 and "FAINTED" or statusText(mon.status, mon.hp)))
    bufBattle:print(string.format("     %s   Atk %d  Def %d  Spe %d  Spc %d\n",
        typeText(mon.type1, mon.type2), mon.atk, mon.def, mon.spe, mon.spc))
    bufBattle:print(string.format("     IVs (DVs):       HP %2d  Atk %2d  Def %2d  Spe %2d  Spc %2d\n",
        mon.dv.hp, mon.dv.atk, mon.dv.def, mon.dv.spe, mon.dv.spc))
    local se = mon.statExp
    bufBattle:print(string.format("     EVs (Stat Exp):  HP %d  Atk %d  Def %d  Spe %d  Spc %d\n",
        se[1], se[2], se[3], se[4], se[5]))
    local moves = {}
    for _, mv in ipairs(mon.moves) do
        moves[#moves + 1] = string.format("%s %d/%d", mv.name, mv.pp, mv.maxPP)
    end
    bufBattle:print("     " .. table.concat(moves, ", ") .. "\n")
end

local lastBattleSnapshot
local function updateBattle()
    local battle = emu:read8(wIsInBattle)

    -- Redraw only when something relevant changes
    local snapshot = string.char(battle)
        .. emu:readRange(wBattleMon, 0x1D) .. emu:readRange(wEnemyMonBattle, 0x1D)
        .. emu:readRange(wPartyCount, wPartyMonOT - wPartyCount)
        .. emu:readRange(wEnemyPartyCount, 1 + 7 + 6 * PARTY_MON_SIZE)
        .. string.char(emu:read8(wPlayerMonNumber))
    if snapshot == lastBattleSnapshot then return end
    lastBattleSnapshot = snapshot

    bufBattle:clear()
    if battle ~= 1 and battle ~= 2 then
        bufBattle:print("Not in battle\n")
        return
    end

    -- Opponent
    if battle == 1 then
        bufBattle:print("WILD POKEMON\n")
        local mon = readMon(wEnemyMonBattle, BATTLE_OFS)
        printBattleMon(1, speciesName(mon.species), mon, true)
    else
        local trainer = decode(emu:readRange(wTrainerName, 13))
        local count = emu:read8(wEnemyPartyCount)
        local activeSlot = emu:read8(wEnemyMonBattle + 3)   -- battle_struct PartyPos
        bufBattle:print(string.format("OPPONENT: %s (%d Pokemon)\n", trainer, count))
        for i = 0, math.min(count, 6) - 1 do
            local party = wEnemyMons + i * PARTY_MON_SIZE
            local mon
            if i == activeSlot then
                mon = readMon(wEnemyMonBattle, BATTLE_OFS, party) -- live values
            else
                mon = readMon(party, PARTY_OFS, party)
            end
            printBattleMon(i + 1, speciesName(mon.species), mon, i == activeSlot)
        end
    end

    -- Player's team
    local count = emu:read8(wPartyCount)
    local activeSlot = emu:read8(wPlayerMonNumber)
    bufBattle:print(string.format("\nYOUR TEAM (%d Pokemon)\n", count))
    for i = 0, math.min(count, 6) - 1 do
        local party = wPartyMons + i * PARTY_MON_SIZE
        local mon
        if i == activeSlot then
            mon = readMon(wBattleMon, BATTLE_OFS, party)          -- live values
        else
            mon = readMon(party, PARTY_OFS, party)
        end
        local nickname = decode(emu:readRange(wPartyMonNicks + i * NAME_LENGTH, NAME_LENGTH))
        local species  = speciesName(mon.species)
        local name = nickname == species and species or (nickname .. " (" .. species .. ")")
        printBattleMon(i + 1, name, mon, i == activeSlot)
    end
end

local frames = 0
callbacks:add("frame", function()
    frames = frames + 1
    if frames % 15 == 0 then   -- 4 times a second is plenty
        update()
        updatePlayer()
        updateTeam()
        updateBag()
        updateBattle()
        updateLocation()
        updatePokedex()
    end
end)
