-- Migration: concede_defeat
-- Allows a player to voluntarily concede, releasing all their castles and killing all commanders.
-- Sends a system inbox message to all players, then checks win condition.

CREATE OR REPLACE FUNCTION public.concede_defeat(p_game_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller    UUID := auth.uid();
  v_player    RECORD;
  v_game      RECORD;
  v_house     TEXT;
BEGIN
  SELECT * INTO v_game FROM games WHERE id = p_game_id;
  IF NOT FOUND OR v_game.status != 'active' THEN
    RAISE EXCEPTION 'Game is not active';
  END IF;

  SELECT gp.* INTO v_player FROM game_players gp
  WHERE gp.game_id = p_game_id AND gp.user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;
  IF v_player.eliminated_at_tick IS NOT NULL THEN
    RAISE EXCEPTION 'Already eliminated';
  END IF;

  v_house := v_player.house_slug;

  -- Mark eliminated
  UPDATE game_players
  SET eliminated_at_tick = v_game.current_tick
  WHERE id = v_player.id;

  -- Release all owned castles
  UPDATE game_castles
  SET owner_player_id      = NULL,
      is_under_siege        = FALSE,
      siege_started_at_tick = NULL
  WHERE game_id = p_game_id AND owner_player_id = v_player.id;

  -- Kill all their commanders
  UPDATE commanders
  SET status = 'dead'
  WHERE game_id = p_game_id AND owner_player_id = v_player.id AND status != 'dead';

  -- Cancel all active movements for their commanders
  DELETE FROM commander_movements
  WHERE game_id = p_game_id
    AND commander_id IN (
      SELECT id FROM commanders
      WHERE game_id = p_game_id AND owner_player_id = v_player.id
    );

  -- Cancel active patrol routes
  UPDATE commander_routes
  SET status = 'cancelled'
  WHERE game_id = p_game_id AND status = 'active'
    AND commander_id IN (
      SELECT id FROM commanders
      WHERE game_id = p_game_id AND owner_player_id = v_player.id
    );

  -- Notify all players
  INSERT INTO player_inbox (game_id, player_id, tick, type, title, body)
  SELECT p_game_id, gp.id, v_game.current_tick, 'system',
    'House Concedes',
    jsonb_build_object('house', v_house, 'player_id', v_player.id)
  FROM game_players gp
  WHERE gp.game_id = p_game_id;

  -- Check if concession triggers a win
  PERFORM check_win_condition(p_game_id);

  RETURN jsonb_build_object('ok', true, 'house', v_house);
END;
$function$;
