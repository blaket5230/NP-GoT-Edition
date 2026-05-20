# Westeros — Neptune's Pride: Game of Thrones Edition

An async multiplayer grand strategy game set in Westeros, built in the style of [Neptune's Pride](https://np.ironhelmet.com). Up to 9 great houses compete to control 188 castles across the continent. The first house to hold more than half the map wins the Iron Throne.

> **Status:** Active development — V1 feature-complete, V2 backlog in progress.

---

## Playable Houses

Baratheon · Lannister · Stark · Targaryen · Greyjoy · Martell · Tyrell · Tully · Arryn

---

## Core Features

**Map & Movement**
- 188 castles across Westeros rendered on a scrollable, zoomable map
- Real-time async movement — commanders march between castles over configurable tick intervals
- Multi-stop patrol routes with per-waypoint actions (collect, deposit, garrison, siege)
- Kings Road speed bonus: `17.5 × √(Horses + 3)` leagues/tick when both endpoints are connected

**Combat**
- Deterministic, no dice — outcome depends entirely on troops, commander level, and council bonuses
- Castle assault (defender +20% bonus, fires first), open-field battle (Whisperers initiative), and siege
- Siege mechanics: 3% garrison bleed per tick, infrastructure damage per cycle, Break Siege & Assault button, Sally Out, relief armies, and siege reinforcement
- War Calculator in-game to model any battle before committing

**Commanders**
- Named characters drawn from GoT lore — 15 per house, 135 total across the realm
- Levels 1–5, gaining XP through battle; compound combat multiplier with Hand of the King council seat
- Siege status, route editing, and detail panel all in-game

**Small Council (7 seats)**
| Seat | Bonus |
|---|---|
| Hand of the King | Combat attack multiplier |
| Master of Coin | Gold per production cycle |
| Lord Commander | Troop production rate |
| Master of Whisperers | Scan radius + whisper intelligence |
| Grand Maester | Random passive council XP per cycle |
| Master of Laws | Effective influence (reduces upgrade costs) |
| Master of Horses | March range + Kings Road speed |

**Fog of War**
- Castle ownership, garrison strength, and army positions hidden outside scan range
- Intelligence visible only if you can scan a player's seat castle (Intel dashboard fog gate)
- Whisper reports with confidence ratings for targets beyond scan range

**Diplomacy & Trade**
- Neutral / Allied / At War status between all house pairs
- Private ravens, global Hall chat, and Whispers tab in the Rookery
- Ledger tracks all gold transfers and council sharing with partial pay, forgive, and direct send

**Intel Dashboard**
- KPI row showing current leaders in castles, troops, and treasury
- Category tabs (Territory / Infrastructure / Council) with metric pills
- Time-series chart with house-name labels, trend arrows, and fog-gated standings table

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Single self-contained `index.html` — all JS, CSS, and HTML inline |
| Backend | [Supabase](https://supabase.com) (Postgres + Row Level Security + Edge Functions) |
| Auth | Supabase Auth (email/password) |
| Realtime | Supabase subscriptions for live game state |
| AI | Supabase Edge Functions + Claude API for Whisperer intelligence reports |
| Map | Hand-drawn SVG overlay on a custom Westeros image |

No build step. No framework. No dependencies beyond the Supabase JS client loaded via CDN.

---

## Running Locally

1. Clone the repo
2. Serve `index.html` from any static file server — e.g.:
   ```bash
   npx serve .
   # or
   python3 -m http.server 3456
   ```
3. Open `http://localhost:3456` (or whatever port) in your browser
4. The game points to the production Supabase project by default — you will need a valid account to play

To run against your own Supabase project, replace the `SUPABASE_URL` and `SUPABASE_ANON_KEY` constants near the top of `index.html`.

---

## Project Structure

```
index.html                        # Entire game — all logic, UI, and styles inline
portraits/                        # Commander portrait images (135 named characters)
supabase/
  functions/
    ai-whisper/                   # Edge function: AI-generated Whisperer intel reports
    mow-whisper/                  # Edge function: Master of Whisperers trigger logic
WESTEROS_CLAUDE_CODE_HANDOFF.md   # Detailed dev notes and session handoff document
README.md                         # This file
```

---

## V2 Backlog Highlights

Full naval mechanics · Commander capture & ransom · Iron Bank loans · Seasons & Winter · Wildlings & Essos factions · Mercenary companies · Random event deck · Smooth sub-tick army animation · Named council member characters · Non-Aggression Pacts · Marriage Alliances · Formal peace terms

---

## License

Personal project — not currently licensed for redistribution.
