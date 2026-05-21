-- Record realm-wide events into game_events for the Realm News feed.
-- Two sources:
--   1. Castle ownership changes  → trigger on game_castles
--   2. War declarations          → patched set_enemy function

-- ── 1. Castle capture trigger ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION record_castle_capture_event()
RETURNS TRIGGER AS $$
DECLARE
  v_tick INT;
BEGIN
  IF NEW.owner_player_id IS NOT NULL
     AND NEW.owner_player_id IS DISTINCT FROM OLD.owner_player_id THEN
    SELECT current_tick INTO v_tick FROM games WHERE id = NEW.game_id;
    INSERT INTO game_events (game_id, tick, event_type, player_id, data)
    VALUES (
      NEW.game_id,
      COALESCE(v_tick, 0),
      'castle_captured',
      NEW.owner_player_id,
      jsonb_build_object(
        'castle_slug',           NEW.castle_slug,
        'new_owner_player_id',   NEW.owner_player_id,
        'prev_owner_player_id',  OLD.owner_player_id
      )
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_castle_capture_event ON game_castles;
CREATE TRIGGER trg_castle_capture_event
  AFTER UPDATE OF owner_player_id ON game_castles
  FOR EACH ROW EXECUTE FUNCTION record_castle_capture_event();

-- ── 2. War declaration: patch set_enemy ──────────────────────────────────────

CREATE OR REPLACE FUNCTION set_enemy(p_game_id bigint, p_target_player_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me   RECORD;
  v_pa   BIGINT; v_pb BIGINT;
  v_tick INT;
  v_prev TEXT;
BEGIN
  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;

  SELECT pa, pb INTO v_pa, v_pb FROM _diplomacy_pair(v_me.id, p_target_player_id);
  SELECT status INTO v_prev FROM diplomacy
    WHERE game_id = p_game_id AND player_a_id = v_pa AND player_b_id = v_pb;

  INSERT INTO diplomacy(game_id, player_a_id, player_b_id, status, updated_at)
  VALUES (p_game_id, v_pa, v_pb, 'enemy', NOW())
  ON CONFLICT (game_id, player_a_id, player_b_id) DO UPDATE SET status='enemy', updated_at=NOW();

  -- Only log when transitioning to enemy (not already at war)
  IF v_prev IS DISTINCT FROM 'enemy' THEN
    SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
    INSERT INTO game_events (game_id, tick, event_type, player_id, data)
    VALUES (
      p_game_id,
      COALESCE(v_tick, 0),
      'war_declared',
      v_me.id,
      jsonb_build_object(
        'declarer_player_id', v_me.id,
        'target_player_id',   p_target_player_id
      )
    );
  END IF;

  RETURN jsonb_build_object('ok',true);
END;
$function$;
