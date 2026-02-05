# PropHunt for BeamNG/BeamMP

Custom Prop Hunt mod with Outbreak-style visuals for BeamMP.

## Highlights
- Hider auto-disguise pipeline with prop randomization per round.
- Hunters see blacked-out hide phase, hiders see red proximity vignettes + floating "HUNTER" tags.
- Server commands (`/ph`, `/phset`, `/phprops`) control seekers, timers, and proximity settings; sync pushed via `PropHunt_Settings`.
- Taunt system now uses BeamMP sound emitter helper with resilience against missing files.
- Client-side `/ph` shortcuts, HUD helpers, and Per-Vehicle taunt cooldown.

## Setup
1. Drop the `Client` and `Server` folders into your BeamMP mod directory.
2. Start `main.lua` server script to register commands.
3. Ensure BeamMP route includes this mod before joining a session.

## Commands
- `/ph start [minutes]` – start the round.
- `/ph set seekerfadedist <m>` – set seeker vignette range.
- `/ph set hiderfilterintensity <0-1>` – set hider vignette strength.
- `/ph props <propKey|random>` – force a prop for the next round.
- `/ph <setting> <value>` – client-side overrides for taunts and proximity cues.
