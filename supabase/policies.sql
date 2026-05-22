-- =============================================================================
-- Westeros (Neptune's Pride GOT) — Row Level Security Policies
-- Generated: 2026-05-21
-- Run last (after schema.sql, seed.sql, functions.sql).
-- Enables RLS on each table and applies all policies.
-- =============================================================================


-- =============================================================================
-- STATIC / REFERENCE TABLES  (public read)
-- =============================================================================

ALTER TABLE castles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE houses              ENABLE ROW LEVEL SECURITY;
ALTER TABLE house_starting_castles ENABLE ROW LEVEL SECURITY;
ALTER TABLE commander_pool      ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone reads castles"
  ON castles FOR SELECT TO public USING (true);

CREATE POLICY "Anyone reads houses"
  ON houses FOR SELECT TO public USING (true);

CREATE POLICY "Anyone reads starting castles"
  ON house_starting_castles FOR SELECT TO public USING (true);

CREATE POLICY "Anyone reads commander pool"
  ON commander_pool FOR SELECT TO public USING (true);


-- =============================================================================
-- GAME LIFECYCLE TABLES
-- =============================================================================

ALTER TABLE games        ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_players ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users access games"
  ON games FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated users access game_players"
  ON game_players FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- =============================================================================
-- PER-GAME STATE TABLES
-- =============================================================================

ALTER TABLE game_castles        ENABLE ROW LEVEL SECURITY;
ALTER TABLE commanders          ENABLE ROW LEVEL SECURITY;
ALTER TABLE commander_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE commander_routes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE commander_battles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE council_seats       ENABLE ROW LEVEL SECURITY;
ALTER TABLE diplomacy           ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users access game_castles"
  ON game_castles FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated users access commanders"
  ON commanders FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated users access movements"
  ON commander_movements FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- commander_routes: owner-scoped select + update
CREATE POLICY "routes_select"
  ON commander_routes FOR SELECT TO public
  USING (
    commander_id IN (
      SELECT commanders.id FROM commanders
      WHERE commanders.owner_player_id IN (
        SELECT game_players.id FROM game_players
        WHERE game_players.user_id = auth.uid()
      )
    )
  );

CREATE POLICY "routes_update"
  ON commander_routes FOR UPDATE TO public
  USING (
    commander_id IN (
      SELECT commanders.id FROM commanders
      WHERE commanders.owner_player_id IN (
        SELECT game_players.id FROM game_players
        WHERE game_players.user_id = auth.uid()
      )
    )
  );

-- commander_battles: readable by any player in the same game
CREATE POLICY "players can read battles in their games"
  ON commander_battles FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM game_players gp
      WHERE gp.game_id = commander_battles.game_id
        AND gp.user_id = auth.uid()
    )
  );

CREATE POLICY "Authenticated users access council"
  ON council_seats FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated users access diplomacy"
  ON diplomacy FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- diplomacy: also a public select scoped to the player's own rows
CREATE POLICY "diplomacy_select"
  ON diplomacy FOR SELECT TO public
  USING (
    (player_a_id IN (SELECT game_players.id FROM game_players WHERE game_players.user_id = auth.uid()))
    OR
    (player_b_id IN (SELECT game_players.id FROM game_players WHERE game_players.user_id = auth.uid()))
  );


-- =============================================================================
-- COMMUNICATION TABLES
-- =============================================================================

ALTER TABLE game_chat         ENABLE ROW LEVEL SECURITY;
ALTER TABLE ravens            ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_threads   ENABLE ROW LEVEL SECURITY;
ALTER TABLE thread_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE thread_messages   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "game_chat_select"
  ON game_chat FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM game_players gp
      WHERE gp.game_id = game_chat.game_id
        AND gp.user_id = auth.uid()
    )
  );

CREATE POLICY "game_chat_insert"
  ON game_chat FOR INSERT TO public
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM game_players gp
      WHERE gp.id = game_chat.player_id
        AND gp.game_id = game_chat.game_id
        AND gp.user_id = auth.uid()
    )
  );

CREATE POLICY "Authenticated users access ravens"
  ON ravens FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "thread_select"
  ON message_threads FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM thread_participants tp
      WHERE tp.thread_id = message_threads.id
        AND tp.player_id IN (
          SELECT game_players.id FROM game_players
          WHERE game_players.user_id = auth.uid()
        )
    )
  );

CREATE POLICY "thread_insert"
  ON message_threads FOR INSERT TO public
  WITH CHECK (
    created_by IN (
      SELECT game_players.id FROM game_players
      WHERE game_players.user_id = auth.uid()
    )
  );

CREATE POLICY "tp_select"
  ON thread_participants FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM thread_participants tp2
      WHERE tp2.thread_id = thread_participants.thread_id
        AND tp2.player_id IN (
          SELECT game_players.id FROM game_players
          WHERE game_players.user_id = auth.uid()
        )
    )
  );

CREATE POLICY "tp_insert"
  ON thread_participants FOR INSERT TO public
  WITH CHECK (
    (
      player_id IN (
        SELECT game_players.id FROM game_players
        WHERE game_players.user_id = auth.uid()
      )
    )
    OR
    (
      EXISTS (
        SELECT 1 FROM message_threads mt
        WHERE mt.id = thread_participants.thread_id
          AND mt.created_by IN (
            SELECT game_players.id FROM game_players
            WHERE game_players.user_id = auth.uid()
          )
      )
    )
  );

CREATE POLICY "tm_select"
  ON thread_messages FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM thread_participants tp
      WHERE tp.thread_id = thread_messages.thread_id
        AND tp.player_id IN (
          SELECT game_players.id FROM game_players
          WHERE game_players.user_id = auth.uid()
        )
    )
  );

CREATE POLICY "tm_insert"
  ON thread_messages FOR INSERT TO public
  WITH CHECK (
    (
      player_id IN (
        SELECT game_players.id FROM game_players
        WHERE game_players.user_id = auth.uid()
      )
    )
    AND
    (
      EXISTS (
        SELECT 1 FROM thread_participants tp
        WHERE tp.thread_id = thread_messages.thread_id
          AND tp.player_id IN (
            SELECT game_players.id FROM game_players
            WHERE game_players.user_id = auth.uid()
          )
      )
    )
  );


-- =============================================================================
-- INTEL / EVENT / LEDGER TABLES
-- =============================================================================

ALTER TABLE game_events     ENABLE ROW LEVEL SECURITY;
ALTER TABLE player_inbox    ENABLE ROW LEVEL SECURITY;
ALTER TABLE intel_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger          ENABLE ROW LEVEL SECURITY;
ALTER TABLE whispers        ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users access events"
  ON game_events FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "inbox_select"
  ON player_inbox FOR SELECT TO public
  USING (
    player_id IN (
      SELECT game_players.id FROM game_players
      WHERE game_players.user_id = auth.uid()
    )
  );

CREATE POLICY "inbox_update"
  ON player_inbox FOR UPDATE TO public
  USING (
    player_id IN (
      SELECT game_players.id FROM game_players
      WHERE game_players.user_id = auth.uid()
    )
  );

CREATE POLICY "intel_select"
  ON intel_snapshots FOR SELECT TO public
  USING (
    game_id IN (
      SELECT game_players.game_id FROM game_players
      WHERE game_players.user_id = auth.uid()
    )
  );

CREATE POLICY "ledger_select"
  ON ledger FOR SELECT TO public
  USING (
    (payer_player_id IN (SELECT game_players.id FROM game_players WHERE game_players.user_id = auth.uid()))
    OR
    (receiver_player_id IN (SELECT game_players.id FROM game_players WHERE game_players.user_id = auth.uid()))
  );

CREATE POLICY "Players read own whispers"
  ON whispers FOR SELECT TO public
  USING (
    player_id IN (
      SELECT game_players.id FROM game_players
      WHERE game_players.user_id = auth.uid()
    )
  );

CREATE POLICY "Players update own whispers"
  ON whispers FOR UPDATE TO public
  USING (
    player_id IN (
      SELECT game_players.id FROM game_players
      WHERE game_players.user_id = auth.uid()
    )
  );

CREATE POLICY "Players delete own whispers"
  ON whispers FOR DELETE TO public
  USING (
    player_id IN (
      SELECT game_players.id FROM game_players
      WHERE game_players.user_id = auth.uid()
    )
  );

CREATE POLICY "Service role insert whispers"
  ON whispers FOR INSERT TO public
  WITH CHECK (true);
