# PropHunt for BeamMP

Server-authoritative PropHunt mode with hide phase, seeker/hider teams, prop disguises, proximity visuals, and live admin controls.

## Highlights
- Server-authoritative phases: `idle -> hide -> round`
- Classic and Tag modes
- Per-round hider prop assignment (random or forced next round)
- Seekers frozen + visually blocked during hide phase
- Seeker/hider proximity vignette settings synced from server
- Server-enforced taunt/tag/scan cooldowns
- Match presets (`casual|ranked|chaos`) + map profile bindings
- Prop tier balancing (ranked can restrict tiny/hard props)
- Round economy + lightweight perks (quick scan / stealth taunt)
- Killcam pulse + HUD pulse hints (alive counts/objective/preset)
- Join policy controls for mid-round joins
- Round summary broadcast (winner/reason/duration/tags/conversions/elims)
- `/ph status` live diagnostics

## Structure
- `Server/PropHunt/main.lua` - main server logic + command handling
- `Server/PropHunt/config.lua` - server config defaults
- `Client/lua/ge/extensions/PropHunt.lua` - thin loader
- `Client/lua/ge/extensions/prophunt/core.lua` - core client logic
- `Client/lua/ge/extensions/prophunt/util.lua` - message/category helpers
- `Client/lua/ge/extensions/prophunt/audio.lua` - taunt/audio emitter system
- `Client/lua/ge/extensions/prophunt/visuals.lua` - vignette/visual helper functions
- `Client/lua/ge/extensions/prophunt/commands.lua` - client `/ph...` command routing
- `Client/lua/ge/extensions/prophunt/network.lua` - network event registration mapping
- `Client/lua/ge/extensions/prophunt/disguise.lua` - hider prop-disguise pipeline
- `Client/lua/ge/extensions/prophunt/proximity.lua` - team lists + nearest-distance queries

## Setup
1. Place `Client/` and `Server/` in your BeamMP mod resource.
2. Ensure server loads `Server/PropHunt/main.lua`.
3. Ensure client zip includes folders at zip root (no extra wrapper folder).

## Commands
### Core
- `/ph help`
- `/ph start [minutes]`
- `/ph stop`
- `/ph status`
- `/ph points [playerID]`
- `/ph players`

> Canonical format is spaced commands (`/ph start`, `/ph stop`, ...). Legacy compact aliases are still accepted for compatibility.

### Team control
- `/ph seeker <playerID>`
- `/ph seekers <id1> <id2> ...`
- `/ph seekername <username>`
- `/ph seekersname <name1,name2,...>`

### Settings
- `/ph set seekers fixed <n>`
- `/ph set seekers ratio <0-1>`
- `/ph set hidetime <seconds>`
- `/ph set roundtime <seconds>`
- `/ph set mode classic|tag`
- `/ph set joinpolicy lock_next_round|spectator|seeker|hider`
- `/ph set disguisemode replace|preload|spawnswap`
- `/ph set forceghostoff <on|off>`
- `/ph set cleanupsweep <seconds>`
- `/ph set spawnswapretry <n>`
- `/ph set seekertablock <on|off>`
- `/ph set seekerfadedist <meters>`
- `/ph set seekerfilterintensity <0-1>`
- `/ph set hiderfadedist <meters>`
- `/ph set hiderfilterintensity <0-1>`

### Presets / map profiles
- `/ph preset casual|ranked|chaos`
- `/ph mapprofile <mapKey> <casual|ranked|chaos>`
- `/ph spawnbank add <mapKey> <seeker|hider> <x> <y> <z>`
- `/ph spawnbank list <mapKey>`
- `/ph spawnbank clear <mapKey>`

### Props
- `/ph props random`
- `/ph props <propKey>`

## Config
Edit `Server/PropHunt/config.lua`:
- `roundTime`, `hideTime`, `allowSoloTest` (enable 1-player local test starts)
- `mode`
- `seekerMode`, `seekerCount`, `seekerRatio`
- `joinPolicy`
- `disguiseMode` (`replace` stable, `preload` experimental, `spawnswap` experimental: pre-spawn far away then swap at hide-end)
- `forceGhostOffOnRestore` (bool), `spawnswapRetryCount` (int), `cleanupSweepSeconds` (int), `seekerTabPrevention` (bool)
- `tauntCooldown`, `tagCooldown`, `scanCooldown`, `sameTargetCooldown`
- `minEventGapTempProp`, `minEventGapTag`, `minEventGapTaunt`, `minEventGapScan` (anti-spam hard floors)
- `requireTagCorroboration`, `requireMutualContact`, `tagCorroborationWindow` (anti-spoof tag corroboration)
- `adminAclEnabled` (default `false`), `adminIds`, `adminNames`
- `currentPreset`, `mapProfiles`, `propTierMode`
- `spawnBanks` (optional map/team coordinate banks for spawn hints)
- `perksEnabled`
- `seekerFadeDist`, `seekerFilterIntensity`
- `hiderFadeDist`, `hiderFilterIntensity`
- `nextRoundForcedProp`
- `propPool`

## Notes
- `joinPolicy=lock_next_round` is safest for competitive rounds.
- Mid-round hider joins (`joinPolicy=hider`) receive immediate prop assignment.
- Use `/ph status` to verify state/settings during live tests.
