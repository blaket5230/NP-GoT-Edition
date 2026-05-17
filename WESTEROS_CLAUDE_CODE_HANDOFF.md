# Westeros Game -- Claude Code Handoff Document

---

## 1. Why We Moved to Claude Code

The game HTML file (`Westeros_v2_0_16_9.html`) is too large to edit inside Claude.ai's context window. Claude Code works directly with files on your disk, so it reads and edits only the sections it needs rather than loading everything at once. This eliminates the context overflow errors we kept hitting.

---

## 2. Claude Code Setup

### Install

You need Node.js installed first. Then in your terminal:

```bash
npm install -g @anthropic-ai/claude-code
```

Official docs: https://docs.claude.com/en/docs/claude-code/overview

### How to start each session

Navigate to your project folder in the terminal, then launch Claude Code:

```bash
cd "/Users/blaketaylor/Documents/Claude/Personal Game Code/Westeros"
claude
```

Claude Code will be able to see and edit any file in that folder directly. No uploading needed.

### Project folder

```
/Users/blaketaylor/Documents/Claude/Personal Game Code/Westeros/
  westeros.html                        <- always the working file (no version in name)
  westeros_data_collection_v4.xlsx
  westeros_influence_audit.xlsx
  GOT_Data_-_Maesters__Iron_Bank__Nights_Watch.docx
  WESTEROS_CLAUDE_CODE_HANDOFF.md      <- this file
  archive/
    westeros_v2_0_16_9.html            <- milestone snapshots go here
```

**Versioning convention:** `westeros.html` is always the live working file. When you hit a meaningful milestone, save a copy to `archive/` with the version stamp before continuing. Never rename `westeros.html` itself.

Keep this handoff doc in the project folder. At the start of each Claude Code session, you can say "read the handoff doc" and it will orient itself instantly.

---

## 3. Project Overview

**What this is:** A Neptune's Pride-style async multiplayer grand strategy game set in Game of Thrones / Westeros. 9 playable great houses compete to control the continent. Players manage castles, commanders, armies, and a Small Council that provides passive bonuses.

**Current form:** Single self-contained HTML file with all game logic, rendering, and UI inline. No backend yet -- this is a prototype/demo.

**Working file:** `westeros.html` (always the current version, no version number in the name)

**Versioning:** When a meaningful milestone is hit, a copy is saved to `archive/westeros_vX_X_X.html`. The last archived version is `archive/westeros_v2_0_16_9.html`.

---

## 4. Game Design Document Status

The GDD is complete across 19 sections. All design decisions are locked for V1. Sections:

1. Executive Summary
2. Core Concept
3. Game Modes
4. Win and Loss Conditions
5. Player and Starting Setup (all 9 commander pools, 15 characters each)
6. Tick System
7. Movement
8. Combat and Siege
9. Commanders
10. The Small Council (all 7 active seats with formulas)
11. Fog of War
12. Diplomacy
13. Geography and Map
14. Castle Abandonment
15. In-Game Messaging
16. User Interface
17. Data Structure
18. V1 Scope Summary (with full V2 backlog and build order)
19. Appendix (glossary, source materials)

---

## 5. Key Systems Summary (V1)

### Tick System
Real time passes. Each tick = a configurable number of real-world seconds (set at game creation). Everything runs on ticks: movement, production, combat resolution.

### Movement
Armies move along castle connections. Travel time = number of connection hops x tick cost. Crossing water costs +1 tick. Movement is committed -- armies march and can be recalled but not rerouted mid-march.

### Combat
Attacker/defender strengths compared with modifiers (terrain, commander level, siege vs field). Outcome is probabilistic, resolved at arrival tick.

### Commanders
Each house has a pool of 15 named characters drawn from GoT lore. The head of house is always available. Additional commanders are recruited and assigned to armies or garrisoned at castles. Commander Personal Level improves over time through battles.

### Small Council
7 active seats. Each seat held by a commander. The seat level (1-5) provides passive bonuses (scanning range, gold generation, construction speed, etc.). Leveling costs Prestige. Losing the commander resets the seat.

Seats: Hand of the King, Master of Coin, Master of Whisperers, Master of Laws, Master of Ships, Grand Maester, Commander of the City Watch.

### Fog of War
Full map geography always visible. Castle ownership, garrison strength, army composition hidden unless within scanning radius. Radius = Master of Whisperers level + fixed offset. Castles have larger radius than field commanders.

### Diplomacy (V1 simplified)
Three formal agreement types: Non-Aggression Pact, Alliance (shared vision), Marriage Alliance (locked for 20 ticks). All agreements public. Breaking a NAP costs Prestige.

### Resources
Gold (funds armies and buildings) and Prestige (funds council levels) generate per tick from castles based on Economy and Industry levels.

### Starting Conditions
All great house seat castles standardized to Influence 45. All supporting castles standardized to Influence 25. Each house starts with 4 supporting castles selected by geographic proximity to their seat.

---

## 6. Data Files

### westeros_data_collection_v4.xlsx
Main data workbook. Sheets:
- **Castle Data** -- 188 castles with stats (Influence, tier, region, connections, etc.)
- **House Data** -- 9 great houses with starting conditions
- **Region Data** -- 9 regions with terrain, climate, winter_mult, fleet strength
- **Influence Audit** -- Standardized starting influence values (T1 seats = 45, supporting = 25)
- **Commander Pool** -- 15 named commanders per house (135 total) with head-of-house flags
- **Instructions / Progress** -- Tracking sheets

### westeros_influence_audit.xlsx
Standalone audit workbook used to finalize influence standardization.

### GOT_Data_-_Maesters__Iron_Bank__Nights_Watch.docx
Supplementary lore data for Maesters, Iron Bank, and Night's Watch. Flavor/reference only for V1.

---

## 7. Current Open Tasks (as of handoff)

### Code bugs (highest priority -- these are why we moved to Claude Code)

**Bug 1: ETA shows ticks, should show time**
When an army marches, the ETA tooltip/box displays "X ticks" but it should convert to real time (hours:minutes or similar based on the tick duration setting).
- Look for: `ETA`, `travel_ticks`, `TICK_DURATION`, `msPerTick`, `formatDuration`

**Bug 2: Shield icon disappears when army marches**
The shield icon correctly shows on garrisoned commanders at castles. But when a commander leads a marching army, the map marker reverts to a plain yellow box showing only troop count. The shield should be the primary visual indicator at all times.
- If multiple commanders in one army: stack the shields visually
- Troop count should be secondary (small label)
- Look for: `army-marker`, `cmdChip`, `shield`, `commander.*icon`

### Data tasks (in progress, paused)

**Influence audit + supporting roster output** -- Was mid-execution when we hit context limits. The decisions are made (T1 = 45, supporting = 25, 4 castles per house by proximity) but the final output to the spreadsheet may not be complete.

**Commander pool sheet** -- Was queued to be added to the data workbook alongside the influence work.

---

## 8. V2 Backlog (Full List)

All of these are explicitly out of scope for V1 but logged for future development:

| System | Description |
|---|---|
| Wildlings faction | Beyond the Wall as a playable faction with unique mechanics |
| Essos factions | Free Cities, Dothraki, and other Essos starting positions |
| Full naval mechanics | Fleet building, naval combat, Master of Ships as active warfare seat. All regional fleet strength data already collected. |
| Commander capture | Post-battle outcomes including capture, ransom, execution, escape. Async-friendly implementation required. |
| Named commander death consequences | Prestige loss, regional morale effects when iconic characters die (Ned, Oberyn, etc.) |
| Split commander skills | Separate skill tracks for Field Battle, Siege Offense, Siege Defense |
| Generic commander promotion | Generic commanders earn names, portraits, and specialties through battle wins (Bronn / Davos model) |
| Iron Bank loans | Active loan mechanic with interest rates, repayment schedules, default penalties, public enemy-backing. V1 has Iron Bank as flavor only. |
| Seasons and winter | Summer / Autumn / Winter progression by tick count. Regional winter_mult penalties apply. Maesters announce via raven. All winter_mult data already collected. |
| Mercenary companies | Sellsword companies for hire with outbid mechanics |
| Random events | Regional event deck firing periodically with flavor and mechanical impact |
| Castle experience | Veteran garrison units, named garrison commanders |
| Head of house death consequences | Power transition events when named heads die |
| Sub-tick army animation | Army markers currently jump position each game tick. Use requestAnimationFrame + wall-clock interpolation so markers move smoothly every second between ticks. Pair with live progress % update in the movement info panel. |
| Shadow Paths | Retired entirely. Not planned for any version. |

---

## 9. V1 Recommended Build Order (from GDD)

For when development moves beyond the HTML prototype:

1. Data layer -- load and validate castle, house, region, commander data
2. Map rendering -- Westeros base map with castles plotted, terrain visible
3. Tick engine -- production calculations, time progression
4. Movement system -- army marching, connection routing, arrival resolution
5. Combat system -- battle resolution at arrival
6. Commander system -- pool management, assignment, leveling
7. Small Council -- seat assignment, leveling, passive bonuses
8. Fog of war -- scanning radius calculation, vision updates
9. Diplomacy -- agreement types, breach detection, prestige effects
10. UI polish -- inspector panels, army details, notifications
11. Multiplayer / async -- turn submission, tick processing on server

---

## 10. Map Asset Status

Decision: Use a high-res GoT map image as the base (personal project, no licensing concern).

Coordinate source identified: `carpiediem/game-of-thrones-map` GitHub repo, specifically `ASoIaF-objects.js` which contains castle coordinates. You were going to download this file and add it to the project. This step was not confirmed complete -- check if `ASoIaF-objects.js` is in your project folder.

---

## 11. How to Brief Claude Code Each Session

Paste this at the start of any new Claude Code session:

---

*"This is a Neptune's Pride-style GOT strategy game called Westeros. The main game file is westeros.html. Read WESTEROS_CLAUDE_CODE_HANDOFF.md for full project context before doing anything. The current open code bugs are: (1) ETA on marching armies shows ticks, should show real time; (2) shield icon disappears from army map marker when army starts marching -- shield should be primary indicator always, stack shields for multiple commanders, troop count secondary."*

---

That gives Claude Code everything it needs in one shot.
