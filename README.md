# PropHunt for BeamNG/BeamMP

Custom Prop Hunt mod with Outbreak-style visuals for BeamMP.

## Highlights
- Hider auto-disguise pipeline with prop randomization per round.
- Hunters see blacked-out hide phase, hiders see red proximity vignettes + floating " Seeker " tags.
- Server commands (`/ph`, `/phset`, `/phprops`) control seekers, timers, and proximity settings; sync pushed via `PropHunt_Settings`.
- Taunt system now uses BeamMP sound emitter helper with resilience against missing files.
- Client-side `/ph` shortcuts, HUD helpers, and Per-Vehicle taunt cooldown.

## Setup
1. Drop the `Resources/Client` and `Resources/Server` folders into your BeamMP server directory.
2. Start a round by using `/ph start` in the chat box.
3. If you dont see a timer in the top left press `R` and you will then see the timer.
4. Once the hider timer has finished the Seeker will be able to move and seek for the hidden props.

## Commands
- `/ph start [minutes]` (also `/phstart`) – start the game.
- `/ph stop` (also `/phstop`) – stop the current round.
- `/ph players` – dump connected player IDs.
- `/ph seeker <playerID>` – force a single seeker next round.
- `/ph seekers <id1> <id2> ...` – pick multiple seekers next round.
- `/ph seekername <username>` – force next seeker by exact name.
- `/ph seekersname <name1>,<name2>,...` – multiple seekers by username.
- `/ph set seekers fixed <n>` – fixed number of seekers per round.
- `/ph set seekers ratio <0-1>` – ratio of seekers relative to players.
- `/ph set hidetime <seconds>` – hide-phase duration.
- `/ph set roundtime <seconds>` – main round duration.
- `/ph set mode classic|tag` – choose between classic and tagging modes.
- `/ph set seekerfadedist <meters>` – seeker vignette range.
- `/ph set seekerfilterintensity <0-1>` – seeker vignette intensity multiplier.
- `/ph set hiderfadedist <meters>` – hider vignette range.
- `/ph set hiderfilterintensity <0-1>` – hider vignette intensity multiplier.
- `/ph props random` – default random prop per hider.
- `/ph props <propKey>` – force the next round prop for every hider.
- `/ph <setting> <value>` (client) – shortcut for taunt distance/proximity overrides (`taunt_dist`, `proximity`, `proximity_dist`, `hiderfadedist`, `hiderfilterintensity`).


Credit to [Olrosse](https://github.com/Olrosse), [SaltySnail](https://github.com/SaltySnail), [stefan750](https://github.com/stefan750)
