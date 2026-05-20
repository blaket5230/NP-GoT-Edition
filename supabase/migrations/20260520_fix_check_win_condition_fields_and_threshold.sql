-- Migration: fix_check_win_condition_fields_and_threshold
-- Fixes three bugs in check_win_condition:
--   1. Win threshold was FLOOR(total * 0.50) = 94 for 188 castles, triggering at exactly 50%.
--      "More than half the map" requires 95. Changed to FLOOR(total * pct) + 1.
--   2. Return field names didn't match frontend: castle_count → castles, needed → win_at.
--   3. winner_id (player bigint) was not returned, so isWinner was always false.
-- Also updates the inbox body fields to match the new naming.

CREATE OR REPLACE FUNCTION public.check_win_condition(p_game_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_game          RECORD;
  v_total_castles INT;
  v_needed        INT;
  v_winner_id     BIGINT;
  v_winner_count  INT;
  v_winner_house  TEXT;
  v_winner_email  TEXT;
BEGIN
  SELECT * INTO v_game FROM games WHERE id = p_game_id;
  IF v_game.status != 'active' THEN
    RETURN jsonb_build_object('winner', null);
  END IF;

  SELECT COUNT(*) INTO v_total_castles
  FROM game_castles WHERE game_id = p_game_id;

  -- Strictly more than victory_pct of castles (default >50%: floor(total*0.5)+1 = 95 for 188)
  v_needed := FLOOR(v_total_castles::NUMERIC * COALESCE(v_game.victory_pct, 0.50)) + 1;

  SELECT gc.owner_player_id, COUNT(*)::INT
  INTO   v_winner_id, v_winner_count
  FROM   game_castles gc
  WHERE  gc.game_id = p_game_id AND gc.owner_player_id IS NOT NULL
  GROUP  BY gc.owner_player_id
  HAVING COUNT(*) >= v_needed
  LIMIT  1;

  IF FOUND THEN
    SELECT gp.house_slug, au.email
    INTO   v_winner_house, v_winner_email
    FROM   game_players gp
    LEFT   JOIN auth.users au ON au.id = gp.user_id
    WHERE  gp.id = v_winner_id;

    UPDATE games SET
      status           = 'finished',
      winner_player_id = v_winner_id,
      finished_at      = NOW()
    WHERE id = p_game_id;

    INSERT INTO player_inbox (game_id, player_id, tick, type, title, body)
    SELECT p_game_id, gp.id, v_game.current_tick, 'system',
      CASE WHEN gp.id = v_winner_id THEN 'Victory!' ELSE 'Defeat' END,
      jsonb_build_object(
        'winner_house',     v_winner_house,
        'winner_player_id', v_winner_id,
        'castles',          v_winner_count,
        'win_at',           v_needed,
        'total',            v_total_castles
      )
    FROM game_players gp WHERE gp.game_id = p_game_id;

    RETURN jsonb_build_object(
      'winner',    v_winner_house,
      'winner_id', v_winner_id,
      'castles',   v_winner_count,
      'win_at',    v_needed,
      'total',     v_total_castles
    );
  END IF;

  RETURN jsonb_build_object('winner', null);
END;
$function$;
