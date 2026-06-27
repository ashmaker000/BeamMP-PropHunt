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

### Installation

1. **Download the release**

   * Go to the **Releases** page.
   * Download the latest `.zip` file.

2. **Extract the files**

   * Unzip the download.
   * You will get two folders:

     * `Client`
     * `Server`

3. **Install the client files**

   * Open the extracted **Client** folder.
   * Inside it is a `.zip` file.
   * Upload that `.zip` into your server’s **client mods folder**.

4. **Install the server files**

   * Open the extracted **Server** folder.
   * Inside is a folder for the game mode (e.g. `CarHunt`, `Tag`, `PropHunt` etc.).
   * On your server, open the main **server folder**.
   * Create a folder for that game mode (for example: `CarHunt`, `Tag`, `PropHunt`).
   * Copy **all files** from the extracted game mode folder into the matching folder you just created on the server.

5. **Restart the server**

   * Restart your BeamMP server.
   * The game mode should now be active.

---

## Commands
Canonical server commands use the spaced `/ph ...` format. Legacy compact aliases such as `/phstart`, `/phstop`, and `/phset ...` still work.

### Core server commands
- `/ph help` - Show command help.
- `/ph start [minutes]` - Start a round. Optional value is minutes.
- `/ph stop` - Stop the active round.
- `/ph status` - Show round, config, visual, autorun, and auto-taunt status.
- `/ph points [playerID]` - Show economy/perk status for yourself or a player.
- `/ph players` - List connected player IDs.

### Team control
- `/ph seeker <playerID>` - Force one seeker for the next round.
- `/ph seekers <id1> <id2> ...` - Force multiple seekers for the next round.
- `/ph seekername <username>` - Force one seeker by exact name for the next round.
- `/ph seekersname <name1>,<name2>,...` - Force multiple seekers by exact names.

### Round settings
- `/ph set seekers fixed <n>` - Use a fixed seeker count.
- `/ph set seekers ratio <0-1>` - Use a seeker ratio.
- `/ph set hidetime <seconds>` - Set hide phase length. Clamped to `0..180`.
- `/ph set roundtime <seconds>` - Set round length. Clamped to `30..3600`.
- `/ph set mode classic|tag` - Classic eliminates hiders; tag converts hiders into seekers.
- `/ph set joinpolicy lock_next_round|spectator|seeker|hider` - Control mid-round joins.
- `/ph set disguisemode replace|preload` - Set disguise pipeline. `spawnswap` is deprecated and rejected.

### Stability and permissions
- `/ph set forceghostoff <on|off>` - Force ghost mode off when restoring vehicles.
- `/ph set cleanupsweep <seconds>` - Set cleanup sweep interval. Clamped to `1..600`.
- `/ph set spawnswapretry <n>` - Set legacy spawnswap retry count. Clamped to `1..10`.
- `/ph set seekertablock <on|off>` - Accepted for compatibility; TAB blocking is currently removed.
- `/ph set nametags <on|off>` - `off` hides nametags during active rounds; `on` shows normal nametags.
- `/ph set nodegrab <on|off>` - Allow or block node grab during active rounds.
- `/ph set hiderreset <on|off>` - Allow or block hider reset during active rounds.

### Automation
- `/ph set autorun <on|off>` - Enable or disable idle auto-start.
- `/ph set autoruninterval <seconds>` - Set auto-start interval. Clamped to `60..86400`.
- `/ph set autorunminplayers <n>` - Auto-start when connected players are greater than `n`.
- `/ph set autotaunt <on|off>` - Enable or disable hider auto-taunts.
- `/ph set autotauntinterval <seconds>` - Set auto-taunt interval. Clamped to `5..300`.

### Visual settings
- `/ph set seekerfadedist <meters>` - Seeker proximity vignette range. Clamped to `5..2000`.
- `/ph set seekerfilterintensity <0-1>` - Seeker proximity vignette strength.
- `/ph set hiderfadedist <meters>` - Hider proximity vignette range. Clamped to `5..2000`.
- `/ph set hiderfilterintensity <0-1>` - Hider proximity vignette strength.

### Presets and map profiles
- `/ph preset casual|ranked|chaos` - Apply a gameplay preset.
- `/ph mapprofile <mapKey> <casual|ranked|chaos>` - Bind a preset to a map key.
- `/ph spawnbank add <mapKey> <seeker|hider> <x> <y> <z>` - Add a spawn hint.
- `/ph spawnbank list <mapKey>` - Show spawn hint counts.
- `/ph spawnbank clear <mapKey>` - Clear spawn hints for a map.

### Props
- `/ph props random` - Use random hider props next round.
- `/ph props <propKey>` - Force one prop for the next round only.

### Compatibility aliases
- `/startgame` - Alias for `/ph start`.
- `/stopgame` - Alias for `/ph stop`.
- `/players` - Alias for `/ph players`.
- `/setseeker <playerID>` - Alias for `/ph seeker <playerID>`.
- Compact command forms also work: `/phstart`, `/phstop`, `/phhelp`, `/phstatus`, `/phpoints`, `/phplayers`, `/phseeker`, `/phseekers`, `/phseekername`, `/phseekersname`, `/phset`, `/phprops`, `/phpreset`, `/phmapprofile`, `/phspawnbank`.

### Client commands
- `/phhelp` - Show client command help.
- `/ph config <setting> <value>` - Configure local client distances/intensities.
- `/phconfig <setting> <value>` - Compact client config form.
- `/phtag <playerId>` - Send a manual tag request. Intended for seekers/debugging.

Client config settings:
- `taunt_dist` or `tauntdist` - Taunt sound distance in meters.
- `proximity`, `proximityintensity`, or `proximityfilter` - Seeker proximity vignette intensity.
- `proximity_dist`, `proximitydist`, or `proximitydistance` - Seeker proximity vignette range.
- `hiderfadedist`, `hiderfadedistance`, `hiderproximitydist`, or `hiderproximitydistance` - Hider proximity vignette range.
- `hiderfilterintensity`, `hiderfilter`, or `hiderproximity` - Hider proximity vignette intensity.
