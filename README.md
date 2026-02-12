# BeamMP PropHunt

Server-authoritative PropHunt mode with hide phase, seeker/hider teams, prop disguises, proximity visuals, and live admin controls.
<img width="1280" height="720" alt="BeamMP-PropHunt1" src="https://github.com/user-attachments/assets/b050d74b-0bde-467b-b131-96cdf6137aec" />

---

## Highlights
- Server-authoritative phases: `idle -> hide -> round`
- Classic and Tag modes
- Per-round hider prop assignment (random or forced next round)
- Seekers frozen + visually blocked during hide phase
- Seeker/hider proximity vignette settings synced from server
- Server-enforced taunt/tag/scan cooldowns
- Join policy controls for mid-round joins
- Round summary broadcast (winner/reason/duration/tags/conversions/elims)
- `/ph status` live diagnostics

## Installation

1. Unpack `BeamMP-PropHunt.zip` and your see `Client` and `Server` folders
2. Go into your `Client folder` on your server and place the `BeamMP-PropHunt.zip`, then head to your `Server folder` and create a folder called `Tag` and add `main.lua` into your new folder.
3. Start a round by using `/ph start` in the chat box.
4. After a few seconds the round will start and a player will be selected.
5. `Seeker` will be frozen for `60` seconds (but can be changed) while the `Hider` get a headstart.

---

## Commands

### Core
- `/ph help`
- `/ph start [minutes]`
- `/ph stop`
- `/ph status`
- `/ph players`

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
- `/ph set seekerfadedist <meters>`
- `/ph set seekerfilterintensity <0-1>`
- `/ph set hiderfadedist <meters>`
- `/ph set hiderfilterintensity <0-1>`

### Props
- `/ph props random`
- `/ph props <propKey>`

---

## Notes
- `joinPolicy=lock_next_round` is safest for competitive rounds.
- Mid-round hider joins (`joinPolicy=hider`) receive immediate prop assignment.
- Use `/ph status` to verify state/settings during live tests.

---
