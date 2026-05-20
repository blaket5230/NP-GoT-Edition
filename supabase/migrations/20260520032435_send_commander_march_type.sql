-- Migration: send_commander_march_type
-- Adds p_march_type parameter so siege marches are recorded in commander_movements.march_type
-- Without this, send_commander always wrote 'assault' regardless of the frontend value
-- Note: Kings Road speed was later simplified to flat 3× in simplify_kings_road_to_flat_3x

CREATE OR REPLACE FUNCTION public.send_commander(
  p_commander_id bigint,
  p_game_id      bigint,
  p_to_castle    text,
  p_troops       integer,
  p_march_type   text DEFAULT 'assault'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_caller      UUID   := auth.uid();
  v_player      RECORD;
  v_cmd         RECORD;
  v_from_cs     RECORD;
  v_to_cs       RECORD;
  v_game        RECORD;
  v_horses_lv   INT;
  v_from_road   BOOLEAN;
  v_to_road     BOOLEAN;
  v_dist        NUMERIC;
  v_speed       NUMERIC;
  v_ticks       INT;
BEGIN
  SELECT gp.* INTO v_player FROM game_players gp
  WHERE gp.game_id = p_game_id AND gp.user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  SELECT c.* INTO v_cmd FROM commanders c
  WHERE c.id = p_commander_id AND c.game_id = p_game_id
    AND c.owner_player_id = v_player.id AND c.status = 'idle';
  IF NOT FOUND THEN RAISE EXCEPTION 'Commander not available'; END IF;

  SELECT gc.*, cs.map_x, cs.map_y INTO v_from_cs
  FROM game_castles gc JOIN castles cs ON cs.slug = gc.castle_slug
  WHERE gc.game_id = p_game_id AND gc.castle_slug = v_cmd.current_castle_slug
    AND gc.owner_player_id = v_player.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Commander not at your castle'; END IF;

  IF p_troops < 1 OR p_troops > v_from_cs.troops THEN
    RAISE EXCEPTION 'Invalid troop count (1–%)', v_from_cs.troops;
  END IF;

  SELECT cs.map_x, cs.map_y, gc.has_kings_road INTO v_to_cs
  FROM castles cs
  JOIN game_castles gc ON gc.castle_slug = cs.slug AND gc.game_id = p_game_id
  WHERE cs.slug = p_to_castle;
  IF NOT FOUND THEN RAISE EXCEPTION 'Destination castle not found'; END IF;

  SELECT current_tick, commander_speed_mult INTO v_game FROM games WHERE id = p_game_id;

  SELECT COALESCE(level, 1) INTO v_horses_lv FROM council_seats
  WHERE game_id = p_game_id AND player_id = v_player.id AND seat = 'horses';

  -- Base speed: 17.5 leagues/tick × game speed multiplier
  v_speed := COALESCE(v_game.commander_speed_mult, 1.0) * 17.5;

  -- Kings Road boost: both castles must have it
  v_from_road := COALESCE(v_from_cs.has_kings_road, FALSE);
  v_to_road   := COALESCE(v_to_cs.has_kings_road, FALSE);
  IF v_from_road AND v_to_road THEN
    v_speed := v_speed * SQRT(v_horses_lv::NUMERIC + 3.0);
  END IF;

  v_dist := SQRT(
    POWER((v_to_cs.map_x - v_from_cs.map_x) * 672, 2) +
    POWER((v_to_cs.map_y - v_from_cs.map_y) * 1560, 2)
  );
  v_ticks := GREATEST(1, CEIL(v_dist / v_speed)::INT);

  UPDATE game_castles SET troops = troops - p_troops
  WHERE game_id = p_game_id AND castle_slug = v_cmd.current_castle_slug;

  UPDATE commanders SET status = 'moving', current_castle_slug = NULL
  WHERE id = p_commander_id;

  INSERT INTO commander_movements
    (commander_id, game_id, from_castle_slug, to_castle_slug,
     departed_at_tick, arrives_at_tick, troops, march_type)
  VALUES
    (p_commander_id, p_game_id, v_cmd.current_castle_slug, p_to_castle,
     v_game.current_tick, v_game.current_tick + v_ticks, p_troops,
     CASE WHEN p_march_type = 'siege' THEN 'siege' ELSE 'assault' END);

  RETURN jsonb_build_object('travel_ticks', v_ticks, 'troops', p_troops);
END;
$function$;
