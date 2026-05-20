-- Migration: simplify_kings_road_to_flat_3x
-- Replaces the SQRT(horses_level + 3) Kings Road multiplier with a flat 3× bonus.
-- Old formula: speed × SQRT(horses_lv + 3.0) → Lv1=2.0×, Lv2=2.24×, ..., Lv5=2.83×
-- New formula: speed × 3 when both castles have has_kings_road=TRUE; otherwise no bonus.
-- 1 Kings Road castle (only one endpoint) still gives no bonus.
-- Applied to: send_commander, send_on_route, process_ticks (route advancement leg).

-- ─── send_commander ───────────────────────────────────────────────────────────

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

  -- Base speed: 17.5 leagues/tick × game speed multiplier
  v_speed := COALESCE(v_game.commander_speed_mult, 1.0) * 17.5;

  -- Kings Road boost: flat 3× when BOTH endpoints have the road
  v_from_road := COALESCE(v_from_cs.has_kings_road, FALSE);
  v_to_road   := COALESCE(v_to_cs.has_kings_road, FALSE);
  IF v_from_road AND v_to_road THEN
    v_speed := v_speed * 3;
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


-- ─── send_on_route ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.send_on_route(
  p_game_id      bigint,
  p_commander_id bigint,
  p_troops       integer,
  p_waypoints    jsonb,
  p_is_loop      boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_caller        UUID;
  v_player        RECORD;
  v_commander     RECORD;
  v_from_castle   RECORD;
  v_first_dest    TEXT;
  v_to_castle     RECORD;
  v_game          RECORD;
  v_distance      NUMERIC;
  v_travel_ticks  INT;
  v_route_id      BIGINT;
  v_is_assault    BOOLEAN;
  v_norm_wps      JSONB;
  v_wp            JSONB;
  v_first_action  TEXT;
  v_speed         NUMERIC;
  v_from_road     BOOLEAN;
  v_to_road       BOOLEAN;
  v_map_w         CONSTANT NUMERIC := 672;
  v_map_h         CONSTANT NUMERIC := 1560;
BEGIN
  v_caller := auth.uid();
  SELECT * INTO v_player FROM game_players WHERE game_id = p_game_id AND user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  SELECT * INTO v_commander FROM commanders WHERE id = p_commander_id FOR UPDATE;
  IF NOT FOUND OR v_commander.game_id <> p_game_id THEN RAISE EXCEPTION 'Commander not found'; END IF;
  IF v_commander.owner_player_id <> v_player.id THEN RAISE EXCEPTION 'Not your commander'; END IF;
  IF v_commander.status <> 'idle' THEN RAISE EXCEPTION 'Commander is not idle'; END IF;
  IF p_troops < 1 THEN RAISE EXCEPTION 'Must send at least 1 troop'; END IF;
  IF jsonb_array_length(p_waypoints) < 1 THEN RAISE EXCEPTION 'Need at least one waypoint'; END IF;

  -- Normalise waypoints (string shorthand → full object)
  v_norm_wps := '[]'::JSONB;
  FOR v_wp IN SELECT * FROM jsonb_array_elements(p_waypoints)
  LOOP
    IF jsonb_typeof(v_wp) = 'string' THEN
      v_norm_wps := v_norm_wps || jsonb_build_array(
        jsonb_build_object('castle_slug', v_wp #>> '{}', 'action', 'pass', 'delay', 0, 'amount', 'null'::jsonb)
      );
    ELSE
      v_norm_wps := v_norm_wps || jsonb_build_array(
        jsonb_build_object(
          'castle_slug', v_wp->>'castle_slug',
          'action',      COALESCE(v_wp->>'action', 'pass'),
          'delay',       COALESCE((v_wp->>'delay')::INT, 0),
          'amount',      COALESCE(v_wp->'amount', 'null'::jsonb)
        )
      );
    END IF;
  END LOOP;

  -- Auto-upgrade last waypoint from 'pass' to 'deposit_all' on one-shot routes
  IF NOT p_is_loop THEN
    DECLARE v_last JSONB; v_last_idx INT;
    BEGIN
      v_last_idx := jsonb_array_length(v_norm_wps) - 1;
      v_last := v_norm_wps->v_last_idx;
      IF v_last->>'action' = 'pass' THEN
        v_norm_wps := jsonb_set(v_norm_wps, ARRAY[v_last_idx::TEXT, 'action'], '"deposit_all"');
      END IF;
    END;
  END IF;

  v_first_dest   := v_norm_wps->0->>'castle_slug';
  v_first_action := COALESCE(v_norm_wps->0->>'action', 'pass');

  SELECT gc.*, c.map_x AS m_x, c.map_y AS m_y INTO v_from_castle
  FROM game_castles gc JOIN castles c ON c.slug = gc.castle_slug
  WHERE gc.game_id = p_game_id AND gc.castle_slug = v_commander.current_castle_slug;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source castle not found'; END IF;
  IF v_from_castle.owner_player_id <> v_player.id THEN RAISE EXCEPTION 'You no longer own the source castle'; END IF;
  IF v_from_castle.troops < p_troops THEN
    RAISE EXCEPTION 'Not enough troops (have %, need %)', v_from_castle.troops, p_troops;
  END IF;

  SELECT gc.*, c.map_x AS m_x, c.map_y AS m_y INTO v_to_castle
  FROM game_castles gc JOIN castles c ON c.slug = gc.castle_slug
  WHERE gc.game_id = p_game_id AND gc.castle_slug = v_first_dest;
  IF NOT FOUND THEN RAISE EXCEPTION 'First destination castle not found'; END IF;

  SELECT * INTO v_game FROM games WHERE id = p_game_id;

  -- Speed: game multiplier × 17.5, plus flat 3× Kings Road bonus if both endpoints have it
  v_speed := COALESCE(v_game.commander_speed_mult, 1.0) * 17.5;
  v_from_road := COALESCE(v_from_castle.has_kings_road, FALSE);
  v_to_road   := COALESCE(v_to_castle.has_kings_road, FALSE);
  IF v_from_road AND v_to_road THEN
    v_speed := v_speed * 3;
  END IF;

  v_distance := SQRT(
    POWER((v_to_castle.m_x - v_from_castle.m_x) * v_map_w, 2) +
    POWER((v_to_castle.m_y - v_from_castle.m_y) * v_map_h, 2)
  );
  v_travel_ticks := GREATEST(1, CEIL(v_distance / v_speed))::INT;

  v_is_assault := (v_to_castle.owner_player_id IS NOT NULL
                   AND v_to_castle.owner_player_id <> v_player.id);

  UPDATE game_castles SET troops = troops - p_troops
  WHERE game_id = p_game_id AND castle_slug = v_commander.current_castle_slug;

  UPDATE commanders SET status = 'moving', current_castle_slug = NULL, troops = p_troops
  WHERE id = p_commander_id;

  INSERT INTO commander_routes (commander_id, game_id, waypoints, current_idx, is_loop, status)
  VALUES (p_commander_id, p_game_id, v_norm_wps, 0, p_is_loop, 'active')
  RETURNING id INTO v_route_id;

  INSERT INTO commander_movements (
    commander_id, game_id, from_castle_slug, to_castle_slug,
    departed_at_tick, arrives_at_tick, troops, march_type
  ) VALUES (
    p_commander_id, p_game_id,
    v_commander.current_castle_slug, v_first_dest,
    v_game.current_tick, v_game.current_tick + v_travel_ticks,
    p_troops,
    CASE WHEN v_first_action = 'siege' THEN 'siege' ELSE 'assault' END
  );

  RETURN jsonb_build_object(
    'success',      true,
    'route_id',     v_route_id,
    'commander_id', p_commander_id,
    'waypoints',    jsonb_array_length(v_norm_wps),
    'is_loop',      p_is_loop,
    'first_dest',   v_first_dest,
    'travel_ticks', v_travel_ticks,
    'is_assault',   v_is_assault
  );
END;
$function$;


-- ─── process_ticks: route advancement leg speed ───────────────────────────────
-- Only the Kings Road speed section changes. The full process_ticks function is in
-- 20260520024918_siege_arrivals_and_break_siege.sql. The affected snippet replaces:
--
--   SELECT COALESCE(level,1) INTO v_horses_lv FROM council_seats
--   WHERE game_id = v_mv.game_id AND player_id = v_owner AND seat = 'horses';
--   v_leg_speed := COALESCE(v_game.commander_speed_mult,1.0) * 17.5;
--   IF v_from_road AND v_to_road THEN
--     v_leg_speed := v_leg_speed * SQRT(v_horses_lv::NUMERIC + 3.0);
--   END IF;
--
-- With:
--
--   v_leg_speed := COALESCE(v_game.commander_speed_mult,1.0) * 17.5;
--   IF v_from_road AND v_to_road THEN
--     v_leg_speed := v_leg_speed * 3;
--   END IF;
--
-- The v_horses_lv variable and its SELECT are removed entirely from that block.
