-- =============================================================================
-- Westeros (Neptune's Pride GOT) — Stored Functions & Procedures
-- Generated: 2026-05-21
-- Run after schema.sql and seed.sql, before policies.sql.
-- All functions use CREATE OR REPLACE so this file is idempotent.
-- =============================================================================

-- ============================================================================
-- _diplomacy_pair(a bigint, b bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public._diplomacy_pair(a bigint, b bigint)
 RETURNS TABLE(pa bigint, pb bigint)
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT LEAST(a,b), GREATEST(a,b)
$function$

-- ============================================================================
-- abort_route(p_game_id bigint, p_commander_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.abort_route(p_game_id bigint, p_commander_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_mov        RECORD;
  v_player_id  BIGINT;
BEGIN
  SELECT id INTO v_player_id
  FROM game_players
  WHERE game_id = p_game_id AND user_id = auth.uid();
  IF v_player_id IS NULL THEN
    RAISE EXCEPTION 'Not a player in this game';
  END IF;

  SELECT * INTO v_mov
  FROM commander_movements
  WHERE game_id = p_game_id AND commander_id = p_commander_id
  LIMIT 1;
  IF v_mov IS NULL THEN
    RAISE EXCEPTION 'No active movement for this commander';
  END IF;

  PERFORM 1 FROM commanders
  WHERE id = p_commander_id AND owner_player_id = v_player_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not your commander';
  END IF;

  -- Troops stay with the commander — do NOT return to garrison.
  -- Set commander idle at origin with their marching troop count.
  UPDATE commanders
  SET status = 'idle',
      current_castle_slug = v_mov.from_castle_slug,
      troops = v_mov.troops
  WHERE id = p_commander_id;

  DELETE FROM commander_movements WHERE id = v_mov.id;

  UPDATE commander_routes
  SET status = 'cancelled'
  WHERE game_id = p_game_id AND commander_id = p_commander_id AND status = 'active';

  RETURN jsonb_build_object('success', true, 'returned_to', v_mov.from_castle_slug);
END;
$function$

-- ============================================================================
-- accept_alliance(p_game_id bigint, p_target_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.accept_alliance(p_game_id bigint, p_target_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me   RECORD;
  v_them RECORD;
  v_pa   BIGINT; v_pb BIGINT;
  v_tick INT;
BEGIN
  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;

  SELECT * INTO v_them FROM game_players WHERE id = p_target_player_id AND game_id = p_game_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Target not in game'); END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  SELECT pa, pb INTO v_pa, v_pb FROM _diplomacy_pair(v_me.id, p_target_player_id);

  UPDATE diplomacy SET
    status = 'ally', formed_at_tick = v_tick,
    proposed_by_player_id = NULL, updated_at = NOW()
  WHERE game_id = p_game_id AND player_a_id = v_pa AND player_b_id = v_pb
    AND status = 'proposed'
    AND proposed_by_player_id != v_me.id;  -- only the recipient can accept

  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','No pending proposal to accept'); END IF;

  -- Raven to proposer
  INSERT INTO player_inbox(game_id, player_id, tick, type, title, body) VALUES (
    p_game_id, p_target_player_id, v_tick, 'diplomacy',
    'House ' || v_me.house_slug || ' accepted your alliance',
    jsonb_build_object('event','alliance_accepted','from_player_id',v_me.id,'from_house',v_me.house_slug)
  );

  RETURN jsonb_build_object('ok',true);
END;
$function$

-- ============================================================================
-- ai_compute_attack_strength(p_troops integer, p_cmd_level integer, p_hand_level integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_compute_attack_strength(p_troops integer, p_cmd_level integer, p_hand_level integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT p_troops::NUMERIC * (1.0 + p_cmd_level * 0.10) * (1.0 + p_hand_level * 0.10);
$function$

-- ============================================================================
-- ai_compute_defense_strength(p_troops integer, p_cmd_level integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_compute_defense_strength(p_troops integer, p_cmd_level integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT p_troops::NUMERIC * (1.0 + p_cmd_level * 0.10) * 1.20;
$function$

-- ============================================================================
-- ai_create_thread(p_game_id bigint, p_player_id bigint, p_subject text, p_recipients bigint[], p_message text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_create_thread(p_game_id bigint, p_player_id bigint, p_subject text, p_recipients bigint[], p_message text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_thread_id bigint;
  v_tick      integer;
  v_pid       bigint;
BEGIN
  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;

  -- Verify p_player_id belongs to an AI player in this game
  IF NOT EXISTS (
    SELECT 1 FROM game_players WHERE id = p_player_id AND game_id = p_game_id AND is_ai = true
  ) THEN RAISE EXCEPTION 'not an ai player'; END IF;

  INSERT INTO message_threads(game_id, subject, created_by)
  VALUES (p_game_id, p_subject, p_player_id)
  RETURNING id INTO v_thread_id;

  INSERT INTO thread_participants(thread_id, player_id) VALUES (v_thread_id, p_player_id);

  FOREACH v_pid IN ARRAY p_recipients LOOP
    IF v_pid <> p_player_id THEN
      INSERT INTO thread_participants(thread_id, player_id)
      VALUES (v_thread_id, v_pid)
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  INSERT INTO thread_messages(thread_id, player_id, message, tick)
  VALUES (v_thread_id, p_player_id, p_message, COALESCE(v_tick, 0));

  RETURN v_thread_id;
END;
$function$

-- ============================================================================
-- ai_send_thread_message(p_thread_id bigint, p_player_id bigint, p_message text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_send_thread_message(p_thread_id bigint, p_player_id bigint, p_message text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_game_id bigint;
  v_tick    integer;
BEGIN
  SELECT mt.game_id INTO v_game_id FROM message_threads mt WHERE mt.id = p_thread_id;
  SELECT current_tick INTO v_tick FROM games WHERE id = v_game_id;

  -- Verify p_player_id is an AI player
  IF NOT EXISTS (
    SELECT 1 FROM game_players WHERE id = p_player_id AND is_ai = true
  ) THEN RAISE EXCEPTION 'not an ai player'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM thread_participants WHERE thread_id = p_thread_id AND player_id = p_player_id
  ) THEN
    -- Auto-add AI to thread if not already a participant
    INSERT INTO thread_participants(thread_id, player_id)
    VALUES (p_thread_id, p_player_id)
    ON CONFLICT DO NOTHING;
  END IF;

  INSERT INTO thread_messages(thread_id, player_id, message, tick)
  VALUES (p_thread_id, p_player_id, p_message, COALESCE(v_tick, 0));
END;
$function$

-- ============================================================================
-- apply_game_settings(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.apply_game_settings(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_game   RECORD;
  v_caller UUID := auth.uid();
BEGIN
  SELECT * INTO v_game FROM games WHERE id = p_game_id;

  -- Only the game creator can apply settings
  IF v_game.created_by IS DISTINCT FROM v_caller THEN
    RAISE EXCEPTION 'Only the game creator can apply settings';
  END IF;

  -- Starting gold
  UPDATE game_players SET gold = v_game.starting_gold WHERE game_id = p_game_id;

  -- Seat castles: garrison + infrastructure
  UPDATE game_castles gc SET
    troops         = v_game.starting_garrison,
    gold_level     = v_game.starting_gold_level,
    industry_level = v_game.starting_industry_level,
    prestige_level = v_game.starting_prestige_level
  WHERE gc.game_id = p_game_id
    AND gc.castle_slug IN (SELECT seat_castle_slug FROM houses);

  RETURN jsonb_build_object('success', true);
END;
$function$

-- ============================================================================
-- break_alliance(p_game_id bigint, p_target_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.break_alliance(p_game_id bigint, p_target_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me        RECORD;
  v_player    RECORD;
  v_pa        BIGINT;  v_pb BIGINT;
  v_tick      INT;
  v_grace_end INT;
  GRACE CONSTANT INT := 24;
BEGIN
  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  SELECT pa, pb INTO v_pa, v_pb FROM _diplomacy_pair(v_me.id, p_target_player_id);
  v_grace_end := v_tick + GRACE;

  UPDATE diplomacy SET
    status = 'grace_period', broken_at_tick = v_tick,
    broken_by_player_id = v_me.id, grace_ends_at_tick = v_grace_end, updated_at = NOW()
  WHERE game_id = p_game_id AND player_a_id = v_pa AND player_b_id = v_pb
    AND status = 'ally';

  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','No active alliance to break'); END IF;

  -- Global raven to everyone
  FOR v_player IN SELECT id FROM game_players WHERE game_id = p_game_id LOOP
    INSERT INTO player_inbox(game_id, player_id, tick, type, title, body) VALUES (
      p_game_id, v_player.id, v_tick, 'diplomacy',
      'House ' || v_me.house_slug || ' broke their alliance',
      jsonb_build_object(
        'event','alliance_broken',
        'broken_by_player_id', v_me.id,
        'broken_by_house',     v_me.house_slug,
        'target_player_id',    p_target_player_id,
        'grace_ends_at_tick',  v_grace_end
      )
    );
  END LOOP;

  RETURN jsonb_build_object('ok',true,'grace_ends_at_tick',v_grace_end);
END;
$function$

-- ============================================================================
-- break_siege_and_assault(p_game_id bigint, p_castle_slug text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.break_siege_and_assault(p_game_id bigint, p_castle_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_player       RECORD;
  v_siege_cmd    RECORD;
  v_dest_gc      RECORD;
  v_tick         INT;
  v_cycle_len    INT;
  v_castle_name  TEXT;
  v_atk_cmd_lv   INT;
  v_def_cmd_lv   INT;
  v_atk_hand_lv  INT;
  v_def_hand_lv  INT;
  v_atk_dmg      INT;
  v_def_dmg      INT;
  v_r_a          INT;
  v_r_d          INT;
  v_survivors    INT;
  v_def_troops   INT;
  v_def_cmd_name TEXT;
BEGIN
  SELECT gp.* INTO v_player FROM game_players gp WHERE gp.game_id = p_game_id AND gp.user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  SELECT current_tick, production_cycle_ticks INTO v_tick, v_cycle_len FROM games WHERE id = p_game_id;
  v_cycle_len := COALESCE(v_cycle_len, 12);

  SELECT c.* INTO v_siege_cmd FROM commanders c
  WHERE c.game_id = p_game_id AND c.current_castle_slug = p_castle_slug
    AND c.status = 'sieging' AND c.owner_player_id = v_player.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No active siege at this castle by your forces'; END IF;

  SELECT gc.* INTO v_dest_gc FROM game_castles gc WHERE gc.game_id = p_game_id AND gc.castle_slug = p_castle_slug;
  IF NOT FOUND THEN RAISE EXCEPTION 'Castle not found'; END IF;

  IF v_dest_gc.siege_started_at_tick IS NULL OR (v_tick - v_dest_gc.siege_started_at_tick) < v_cycle_len THEN
    RAISE EXCEPTION 'Siege must last at least one full production cycle before assaulting';
  END IF;

  SELECT name INTO v_castle_name FROM castles WHERE slug = p_castle_slug;
  SELECT COALESCE(level,1) INTO v_atk_hand_lv FROM council_seats WHERE game_id=p_game_id AND player_id=v_player.id AND seat='hand';
  SELECT COALESCE(level,1) INTO v_def_hand_lv FROM council_seats WHERE game_id=p_game_id AND player_id=v_dest_gc.owner_player_id AND seat='hand';
  v_atk_cmd_lv := v_siege_cmd.level;
  SELECT COALESCE(MAX(c.level),0) INTO v_def_cmd_lv FROM commanders c WHERE c.game_id=p_game_id AND c.current_castle_slug=p_castle_slug AND c.status='idle';
  SELECT name INTO v_def_cmd_name FROM commanders WHERE game_id=p_game_id AND current_castle_slug=p_castle_slug AND status='idle' ORDER BY level DESC LIMIT 1;

  v_def_troops := COALESCE(v_dest_gc.troops, 0);
  v_atk_dmg := GREATEST(1, ROUND(v_atk_hand_lv::NUMERIC*(1.0+v_atk_cmd_lv*0.1))::INT);
  v_def_dmg := GREATEST(1, ROUND((v_def_hand_lv+1)::NUMERIC*(1.0+COALESCE(v_def_cmd_lv,0)*0.1))::INT);
  v_r_a := CEIL(v_siege_cmd.troops::NUMERIC / v_def_dmg)::INT;
  v_r_d := CEIL(v_def_troops::NUMERIC       / v_atk_dmg)::INT;

  IF v_r_a <= v_r_d THEN
    v_survivors := GREATEST(1, v_def_troops - (v_r_a - 1) * v_atk_dmg);
    UPDATE game_castles SET troops=v_survivors, is_under_siege=FALSE, siege_started_at_tick=NULL WHERE game_id=p_game_id AND castle_slug=p_castle_slug;
    UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_siege_cmd.id;
    UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_siege_cmd.id AND status='active';
    INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
      (p_game_id,v_player.id,v_tick,'combat','Assault Failed — '||v_castle_name,
       jsonb_build_object('combat_type','assault','result','defender_held','castle_slug',p_castle_slug,'attacker_name',v_siege_cmd.name,'attacker_troops_before',v_siege_cmd.troops,'attacker_troops_after',0,'defender_troops_before',v_def_troops,'defender_troops_after',v_survivors,'atk_dmg_per_round',v_atk_dmg,'def_dmg_per_round',v_def_dmg)),
      (p_game_id,v_dest_gc.owner_player_id,v_tick,'combat','Assault Repelled — '||v_castle_name,
       jsonb_build_object('combat_type','assault','result','defender_held','castle_slug',p_castle_slug,'attacker_name',v_siege_cmd.name,'attacker_troops_before',v_siege_cmd.troops,'attacker_troops_after',0,'defender_troops_before',v_def_troops,'defender_troops_after',v_survivors,'atk_dmg_per_round',v_atk_dmg,'def_dmg_per_round',v_def_dmg));
    RETURN jsonb_build_object('result','defender_held','attacker_survivors',0,'defender_survivors',v_survivors);
  ELSE
    v_survivors := GREATEST(1, v_siege_cmd.troops - v_r_d * v_def_dmg);
    UPDATE game_castles SET owner_player_id=v_player.id, troops=v_survivors, is_under_siege=FALSE, siege_started_at_tick=NULL WHERE game_id=p_game_id AND castle_slug=p_castle_slug;
    UPDATE commanders SET status='idle', troops=v_survivors WHERE id=v_siege_cmd.id;
    UPDATE commanders SET status='dead', current_castle_slug=NULL WHERE game_id=p_game_id AND current_castle_slug=p_castle_slug AND status='idle';
    UPDATE game_players SET gold=gold+ROUND(COALESCE(v_dest_gc.effective_influence,10))::INT WHERE id=v_player.id;
    INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
      (p_game_id,v_player.id,v_tick,'combat','Castle Taken — Assault — '||v_castle_name,
       jsonb_build_object('combat_type','assault','result','attacker_won','castle_slug',p_castle_slug,'attacker_name',v_siege_cmd.name,'attacker_troops_before',v_siege_cmd.troops,'attacker_troops_after',v_survivors,'defender_troops_before',v_def_troops,'defender_troops_after',0,'atk_dmg_per_round',v_atk_dmg,'def_dmg_per_round',v_def_dmg)),
      (p_game_id,v_dest_gc.owner_player_id,v_tick,'combat','Castle Lost — Assault — '||v_castle_name,
       jsonb_build_object('combat_type','assault','result','attacker_won','castle_slug',p_castle_slug,'attacker_name',v_siege_cmd.name,'attacker_troops_before',v_siege_cmd.troops,'attacker_troops_after',v_survivors,'defender_troops_before',v_def_troops,'defender_troops_after',0,'atk_dmg_per_round',v_atk_dmg,'def_dmg_per_round',v_def_dmg));
    RETURN jsonb_build_object('result','attacker_won','attacker_survivors',v_survivors,'defender_survivors',0);
  END IF;
END;
$function$

-- ============================================================================
-- build_kings_road(p_game_id bigint, p_castle_slug text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.build_kings_road(p_game_id bigint, p_castle_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_caller   UUID := auth.uid();
  v_player   RECORD;
  v_gc       RECORD;
  v_castle   RECORD;
  v_cost     INT;
BEGIN
  SELECT gp.* INTO v_player FROM game_players gp
  WHERE gp.game_id = p_game_id AND gp.user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  SELECT gc.*, c.base_influence INTO v_gc
  FROM game_castles gc
  JOIN castles c ON c.slug = gc.castle_slug
  WHERE gc.game_id = p_game_id AND gc.castle_slug = p_castle_slug
    AND gc.owner_player_id = v_player.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'You do not own this castle'; END IF;

  IF COALESCE(v_gc.has_kings_road, FALSE) THEN
    RAISE EXCEPTION 'Kings Road already built at this castle';
  END IF;

  v_cost := FLOOR(10000.0 / GREATEST(1, COALESCE(v_gc.base_influence, 10)));

  IF v_player.gold < v_cost THEN
    RAISE EXCEPTION 'Insufficient gold (need %, have %)', v_cost, v_player.gold;
  END IF;

  UPDATE game_players SET gold = gold - v_cost
  WHERE id = v_player.id;

  UPDATE game_castles SET has_kings_road = TRUE
  WHERE game_id = p_game_id AND castle_slug = p_castle_slug;

  RETURN jsonb_build_object('ok', true, 'cost', v_cost);
END;
$function$

-- ============================================================================
-- bulk_upgrade_infrastructure(p_game_id bigint, p_infra_type text, p_budget integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bulk_upgrade_infrastructure(p_game_id bigint, p_infra_type text, p_budget integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      UUID := auth.uid();
  v_player      RECORD;
  v_game        RECORD;
  v_castle      RECORD;
  v_cost        INT;
  v_cost_mult   NUMERIC;
  v_upgraded    INT  := 0;
  v_spent       INT  := 0;
  v_remaining   INT;
BEGIN
  SELECT gp.* INTO v_player FROM game_players gp
  WHERE gp.game_id = p_game_id AND gp.user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  SELECT infra_cost_mult INTO v_game FROM games WHERE id = p_game_id;
  v_cost_mult := COALESCE(v_game.infra_cost_mult, 1.0);
  v_remaining := LEAST(p_budget, v_player.gold);

  FOR v_castle IN
    SELECT gc.castle_slug, gc.gold_level, gc.industry_level, gc.prestige_level,
           GREATEST(1, gc.effective_influence) AS infl
    FROM   game_castles gc
    WHERE  gc.game_id = p_game_id AND gc.owner_player_id = v_player.id
    ORDER  BY gc.effective_influence DESC
  LOOP
    IF p_infra_type = 'gold' THEN
      v_cost := FLOOR(500  * (v_castle.gold_level     + 1) / v_castle.infl * v_cost_mult);
    ELSIF p_infra_type = 'industry' THEN
      v_cost := FLOOR(1000 * (v_castle.industry_level + 1) / v_castle.infl * v_cost_mult);
    ELSIF p_infra_type = 'prestige' THEN
      v_cost := FLOOR(4000 * (v_castle.prestige_level + 1) / v_castle.infl * v_cost_mult);
    ELSE
      RAISE EXCEPTION 'Unknown infra type: %', p_infra_type;
    END IF;

    EXIT WHEN v_cost > v_remaining;

    UPDATE game_castles SET
      gold_level     = CASE WHEN p_infra_type='gold'     THEN gold_level+1     ELSE gold_level     END,
      industry_level = CASE WHEN p_infra_type='industry' THEN industry_level+1 ELSE industry_level END,
      prestige_level = CASE WHEN p_infra_type='prestige' THEN prestige_level+1 ELSE prestige_level END
    WHERE game_id = p_game_id AND castle_slug = v_castle.castle_slug;

    v_remaining := v_remaining - v_cost;
    v_spent     := v_spent     + v_cost;
    v_upgraded  := v_upgraded  + 1;
  END LOOP;

  IF v_spent > 0 THEN
    UPDATE game_players SET gold = gold - v_spent WHERE id = v_player.id;
  END IF;

  RETURN jsonb_build_object('upgraded', v_upgraded, 'spent', v_spent);
END;
$function$

-- ============================================================================
-- cancel_game(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cancel_game(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_tick   INT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM games WHERE id = p_game_id AND created_by = v_caller
  ) THEN RAISE EXCEPTION 'Only the game creator can cancel this game'; END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  UPDATE games SET status = 'cancelled' WHERE id = p_game_id;

  INSERT INTO player_inbox (game_id, player_id, tick, type, title, body)
  SELECT p_game_id, gp.id, v_tick, 'system',
    'Game cancelled by the host',
    jsonb_build_object('gift_type', 'game_cancelled')
  FROM game_players gp WHERE gp.game_id = p_game_id;

  RETURN jsonb_build_object('success', true);
END;
$function$

-- ============================================================================
-- check_elimination(p_game_id bigint, p_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.check_elimination(p_game_id bigint, p_player_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_player     RECORD;
  v_owns_seat  BOOLEAN;
  v_tick       INT;
BEGIN
  SELECT gp.*, h.seat_castle_slug
  INTO v_player
  FROM game_players gp
  JOIN houses h ON h.slug = gp.house_slug
  WHERE gp.id = p_player_id AND gp.game_id = p_game_id;

  IF NOT FOUND OR v_player.eliminated_at_tick IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM game_castles
    WHERE game_id = p_game_id
      AND castle_slug = v_player.seat_castle_slug
      AND owner_player_id = p_player_id
  ) INTO v_owns_seat;

  IF NOT v_owns_seat THEN
    SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
    UPDATE game_players SET eliminated_at_tick = v_tick WHERE id = p_player_id;
    INSERT INTO game_events (game_id, tick, event_type, player_id, data)
    VALUES (
      p_game_id, v_tick, 'player_eliminated', p_player_id,
      jsonb_build_object('player_id', p_player_id, 'house', v_player.house_slug)
    );
  END IF;
END;
$function$

-- ============================================================================
-- check_win_condition(p_game_id bigint)
-- ============================================================================
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

  -- Strictly more than victory_pct of castles (default >50%, i.e. floor(total*0.5)+1)
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
$function$

-- ============================================================================
-- concede_defeat(p_game_id bigint)
-- ============================================================================
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
  SET owner_player_id     = NULL,
      is_under_siege       = FALSE,
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
$function$

-- ============================================================================
-- create_thread(p_game_id bigint, p_player_id bigint, p_subject text, p_recipients bigint[], p_message text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.create_thread(p_game_id bigint, p_player_id bigint, p_subject text, p_recipients bigint[], p_message text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_thread_id bigint;
  v_tick      integer;
  v_pid       bigint;
BEGIN
  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  IF NOT EXISTS (
    SELECT 1 FROM game_players WHERE id = p_player_id AND user_id = auth.uid()
  ) THEN RAISE EXCEPTION 'not your player'; END IF;

  INSERT INTO message_threads(game_id, subject, created_by)
  VALUES (p_game_id, p_subject, p_player_id)
  RETURNING id INTO v_thread_id;

  -- Add sender
  INSERT INTO thread_participants(thread_id, player_id) VALUES (v_thread_id, p_player_id);
  -- Add recipients
  FOREACH v_pid IN ARRAY p_recipients LOOP
    IF v_pid <> p_player_id THEN
      INSERT INTO thread_participants(thread_id, player_id)
      VALUES (v_thread_id, v_pid)
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  -- Add opening message
  INSERT INTO thread_messages(thread_id, player_id, message, tick)
  VALUES (v_thread_id, p_player_id, p_message, COALESCE(v_tick, 0));

  RETURN v_thread_id;
END;
$function$

-- ============================================================================
-- decline_alliance(p_game_id bigint, p_target_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.decline_alliance(p_game_id bigint, p_target_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me   RECORD;
  v_them RECORD;
  v_pa   BIGINT; v_pb BIGINT;
  v_tick INT;
BEGIN
  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;

  SELECT * INTO v_them FROM game_players WHERE id = p_target_player_id AND game_id = p_game_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Target not in game'); END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  SELECT pa, pb INTO v_pa, v_pb FROM _diplomacy_pair(v_me.id, p_target_player_id);

  UPDATE diplomacy SET status = 'neutral', proposed_by_player_id = NULL, updated_at = NOW()
  WHERE game_id = p_game_id AND player_a_id = v_pa AND player_b_id = v_pb
    AND status = 'proposed';

  -- Raven to proposer
  INSERT INTO player_inbox(game_id, player_id, tick, type, title, body) VALUES (
    p_game_id, p_target_player_id, v_tick, 'diplomacy',
    'House ' || v_me.house_slug || ' declined your alliance proposal',
    jsonb_build_object('event','alliance_declined','from_player_id',v_me.id,'from_house',v_me.house_slug)
  );

  RETURN jsonb_build_object('ok',true);
END;
$function$

-- ============================================================================
-- delete_game(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.delete_game(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM games WHERE id = p_game_id AND created_by = v_caller
  ) THEN RAISE EXCEPTION 'Only the game creator can delete this game'; END IF;

  DELETE FROM games WHERE id = p_game_id;  -- CASCADE handles all child rows
  RETURN jsonb_build_object('success', true);
END;
$function$

-- ============================================================================
-- delete_whisper(p_whisper_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.delete_whisper(p_whisper_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_player_id BIGINT;
BEGIN
  SELECT gp.id INTO v_player_id
  FROM public.whispers w
  JOIN public.game_players gp ON gp.id = w.player_id AND gp.user_id = auth.uid()
  WHERE w.id = p_whisper_id;

  IF v_player_id IS NULL THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  DELETE FROM public.whispers WHERE id = p_whisper_id;
END;
$function$

-- ============================================================================
-- demolish_kings_road(p_game_id bigint, p_castle_slug text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.demolish_kings_road(p_game_id bigint, p_castle_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_player RECORD;
BEGIN
  SELECT gp.* INTO v_player FROM game_players gp
  WHERE gp.game_id = p_game_id AND gp.user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  UPDATE game_castles SET has_kings_road = FALSE
  WHERE game_id = p_game_id AND castle_slug = p_castle_slug
    AND owner_player_id = v_player.id;

  IF NOT FOUND THEN RAISE EXCEPTION 'You do not own this castle'; END IF;

  RETURN jsonb_build_object('ok', true);
END;
$function$

-- ============================================================================
-- enforce_neutral_castle_zero_troops()
-- ============================================================================
CREATE OR REPLACE FUNCTION public.enforce_neutral_castle_zero_troops()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.owner_player_id IS NULL THEN
    NEW.troops := 0;
  END IF;
  RETURN NEW;
END;
$function$

-- ============================================================================
-- force_ticks(p_game_id bigint, p_count integer DEFAULT 1)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.force_ticks(p_game_id bigint, p_count integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       UUID;
  v_game         RECORD;
  v_tick_seconds INT;
  v_is_player    BOOLEAN;
BEGIN
  v_caller := auth.uid();

  SELECT * INTO v_game FROM games WHERE id = p_game_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game not found'; END IF;
  IF v_game.status <> 'active' THEN RAISE EXCEPTION 'Game is not active'; END IF;

  -- Any player in the game can force ticks (tighten to creator-only for production)
  SELECT EXISTS (
    SELECT 1 FROM game_players WHERE game_id = p_game_id AND user_id = v_caller
  ) INTO v_is_player;
  IF NOT v_is_player THEN RAISE EXCEPTION 'You are not a player in this game'; END IF;

  IF p_count < 1 OR p_count > 100 THEN
    RAISE EXCEPTION 'Tick count must be between 1 and 100';
  END IF;

  v_tick_seconds := CASE v_game.tick_speed
    WHEN 'slow'   THEN 7200
    WHEN 'normal' THEN 3600
    WHEN 'fast'   THEN 1800
    WHEN 'quad'   THEN 900
    ELSE 3600
  END;

  -- Wind the clock back so process_ticks sees exactly p_count pending ticks
  UPDATE games
  SET last_tick_processed_at =
        last_tick_processed_at - ((p_count * v_tick_seconds) || ' seconds')::INTERVAL
  WHERE id = p_game_id;

  -- Now run the normal tick engine (combat, income, movements all resolve)
  RETURN process_ticks(p_game_id);
END;
$function$

-- ============================================================================
-- forgive_debt(p_game_id bigint, p_counterpart_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.forgive_debt(p_game_id bigint, p_counterpart_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me RECORD;
  v_rows INT;
BEGIN
  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  -- Forgive: entries where they owe you (you paid, they received)
  UPDATE ledger SET is_forgiven = TRUE
  WHERE game_id            = p_game_id
    AND payer_player_id    = v_me.id
    AND receiver_player_id = p_counterpart_player_id
    AND NOT is_forgiven;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'entries_forgiven', v_rows);
END;
$function$

-- ============================================================================
-- form_alliance(p_game_id bigint, p_target_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.form_alliance(p_game_id bigint, p_target_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me    RECORD;
  v_them  RECORD;
  v_pa    BIGINT;  v_pb BIGINT;
  v_tick  INT;
BEGIN
  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;
  IF v_me.id = p_target_player_id THEN RETURN jsonb_build_object('ok',false,'error','Cannot ally with yourself'); END IF;

  SELECT * INTO v_them FROM game_players WHERE id = p_target_player_id AND game_id = p_game_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Target not in game'); END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  SELECT pa, pb INTO v_pa, v_pb FROM _diplomacy_pair(v_me.id, p_target_player_id);

  INSERT INTO diplomacy(game_id, player_a_id, player_b_id, status, formed_at_tick, updated_at)
  VALUES (p_game_id, v_pa, v_pb, 'ally', v_tick, NOW())
  ON CONFLICT (game_id, player_a_id, player_b_id) DO UPDATE
    SET status = 'ally', formed_at_tick = v_tick,
        broken_at_tick = NULL, broken_by_player_id = NULL, grace_ends_at_tick = NULL,
        updated_at = NOW();

  -- Private raven to target only
  INSERT INTO player_inbox(game_id, player_id, tick, type, title, body) VALUES (
    p_game_id, p_target_player_id, v_tick, 'diplomacy',
    'Alliance offered by ' || v_me.house_slug,
    jsonb_build_object('event','alliance_formed','from_player_id',v_me.id,'from_house',v_me.house_slug)
  );

  RETURN jsonb_build_object('ok',true);
END;
$function$

-- ============================================================================
-- get_available_commanders(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_available_commanders(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID;
  v_player RECORD;
  v_pool   JSONB;
BEGIN
  v_caller := auth.uid();
  SELECT * INTO v_player
  FROM game_players
  WHERE game_id = p_game_id AND user_id = v_caller;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'You are not a player in this game';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('id', cp.id, 'name', cp.name)
      ORDER BY cp.name
    ),
    '[]'::jsonb
  )
  INTO v_pool
  FROM commander_pool cp
  WHERE cp.house_slug = v_player.house_slug
    AND NOT EXISTS (
      SELECT 1 FROM commanders c
      WHERE c.game_id = p_game_id
        AND c.owner_player_id = v_player.id
        AND c.name = cp.name
    );

  RETURN jsonb_build_object(
    'pool', v_pool,
    'cost', 100
  );
END;
$function$

-- ============================================================================
-- mark_whisper_read(p_whisper_id bigint, p_is_read boolean)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.mark_whisper_read(p_whisper_id bigint, p_is_read boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_player_id BIGINT;
BEGIN
  -- Verify the caller owns this whisper
  SELECT gp.id INTO v_player_id
  FROM public.whispers w
  JOIN public.game_players gp ON gp.id = w.player_id AND gp.user_id = auth.uid()
  WHERE w.id = p_whisper_id;

  IF v_player_id IS NULL THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  UPDATE public.whispers SET is_read = p_is_read WHERE id = p_whisper_id;
END;
$function$

-- ============================================================================
-- process_ai_decisions(p_game_id bigint, p_tick integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_ai_decisions(p_game_id bigint, p_tick integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_game            RECORD;
  v_player          RECORD;
  v_pers            RECORD;
  v_castle          RECORD;
  v_sec_castle      RECORD;
  v_cmdr            RECORD;
  v_rel             RECORD;
  v_target          RECORD;

  v_total_castles   INT;
  v_castles_needed  INT;
  v_leader_id       BIGINT;
  v_leader_castles  INT;

  v_my_troops       INT;
  v_my_gold         INT;
  v_my_prestige     INT;
  v_my_castle_count INT;
  v_win_progress    NUMERIC;
  v_pressure        NUMERIC;
  v_closing         NUMERIC;
  v_incoming_threat INT;

  v_score           NUMERIC;
  v_best_score      NUMERIC;
  v_best_slug       TEXT;
  v_focus           TEXT;
  v_sec_type        TEXT;
  v_target_seat     TEXT;
  v_opinion         NUMERIC;

  v_dist            NUMERIC;
  v_ticks           INT;
  v_to_x            NUMERIC;
  v_to_y            NUMERIC;
  v_march_troops    INT;
  v_march_fraction  NUMERIC;
  v_min_garrison    INT;
  v_garrison_live   INT;
  v_reserve         INT;
  v_budget          INT;
  v_cur_lv          INT;
  v_upgrade_cost    INT;
  v_upgrades_done   INT;
  v_war_chance      NUMERIC;
  v_war_ticks       INT;
  v_peace_chance    NUMERIC;
  v_break_chance    NUMERIC;
  v_ally_chance     NUMERIC;
  v_strength_thr    NUMERIC;
  v_seat_lv         INT;
  v_seat_cost       INT;

  v_ally_count      INT;
  v_enemy_count     INT;
  v_other_troops    INT;

  v_pool_name       TEXT;
  v_new_cmdr_id     BIGINT;
  v_threatened      TEXT;
BEGIN
  SELECT * INTO v_game FROM games WHERE id = p_game_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- ══ WORLD STATE ══════════════════════════════════════════════════════════

  SELECT COUNT(*) INTO v_total_castles FROM game_castles WHERE game_id = p_game_id;
  v_castles_needed := GREATEST(1, CEIL(v_total_castles * COALESCE(v_game.victory_pct, 0.50))::INT);

  SELECT owner_player_id, COUNT(*) AS n INTO v_leader_id, v_leader_castles
  FROM game_castles WHERE game_id = p_game_id AND owner_player_id IS NOT NULL
  GROUP BY owner_player_id ORDER BY n DESC LIMIT 1;

  -- ══ ELIMINATED PLAYER CLEANUP ════════════════════════════════════════════
  -- Remove diplomacy rows where either party has been eliminated.
  -- Dead houses have no one to negotiate with.

  DELETE FROM diplomacy
  WHERE game_id = p_game_id
    AND (
      EXISTS (SELECT 1 FROM game_players WHERE id = player_a_id AND eliminated_at_tick IS NOT NULL)
      OR EXISTS (SELECT 1 FROM game_players WHERE id = player_b_id AND eliminated_at_tick IS NOT NULL)
    );

  -- ══ GLOBAL OPINION MAINTENANCE ══════════════════════════════════════════

  UPDATE diplomacy SET opinion_score = opinion_score * 0.97 WHERE game_id = p_game_id;

  UPDATE diplomacy SET opinion_score = GREATEST(-100, opinion_score - 4)
  WHERE game_id = p_game_id AND status = 'enemy';

  UPDATE diplomacy SET opinion_score = LEAST(100, opinion_score + 2)
  WHERE game_id = p_game_id AND status = 'ally';

  IF v_leader_castles >= v_castles_needed * 0.60 THEN
    UPDATE diplomacy SET opinion_score = GREATEST(-100, opinion_score - 8)
    WHERE game_id = p_game_id
      AND (player_a_id = v_leader_id OR player_b_id = v_leader_id)
      AND status <> 'ally';
  END IF;

  -- ══ PER-PLAYER DECISIONS ════════════════════════════════════════════════

  FOR v_player IN
    SELECT gp.id, gp.house_slug,
           gp.ai_rationality, gp.ai_honor, gp.ai_greed, gp.ai_vengefulness
    FROM game_players gp
    WHERE gp.game_id = p_game_id AND gp.is_ai = TRUE AND gp.eliminated_at_tick IS NULL
    ORDER BY gp.id
  LOOP
    SELECT gold, prestige INTO v_my_gold, v_my_prestige FROM game_players WHERE id = v_player.id;

    SELECT * INTO v_pers FROM house_ai_personality WHERE house_slug = v_player.house_slug;
    IF NOT FOUND THEN
      v_pers.troop_bias := 1.0; v_pers.atk_bias := 1.0;
      v_pers.focus_override := NULL; v_pers.expand_bias := 1;
    END IF;

    SELECT COALESCE(SUM(troops), 0), COUNT(*) INTO v_my_troops, v_my_castle_count
    FROM game_castles WHERE game_id = p_game_id AND owner_player_id = v_player.id;

    v_win_progress := v_my_castle_count::NUMERIC / v_castles_needed;

    SELECT COALESCE(SUM(cm.troops), 0) INTO v_incoming_threat
    FROM commander_movements cm
    JOIN commanders c2 ON c2.id = cm.commander_id
    WHERE cm.game_id = p_game_id AND c2.owner_player_id <> v_player.id
      AND cm.arrives_at_tick > p_tick
      AND cm.to_castle_slug IN (
        SELECT castle_slug FROM game_castles WHERE game_id = p_game_id AND owner_player_id = v_player.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM diplomacy d WHERE d.game_id = p_game_id AND d.status = 'ally'
          AND ((d.player_a_id = v_player.id AND d.player_b_id = c2.owner_player_id)
            OR (d.player_b_id = v_player.id AND d.player_a_id = c2.owner_player_id))
      );

    v_pressure := LEAST(1.0,
      GREATEST(0, 1 - v_win_progress) * 0.65
      + LEAST(0.35, v_incoming_threat::NUMERIC / GREATEST(v_my_troops, 50) * 0.5)
    );

    v_closing := GREATEST(0.0, (v_win_progress - 0.70) / 0.30);

    SELECT COUNT(*) FILTER (WHERE status = 'ally'), COUNT(*) FILTER (WHERE status = 'enemy')
    INTO v_ally_count, v_enemy_count
    FROM diplomacy WHERE game_id = p_game_id
      AND (player_a_id = v_player.id OR player_b_id = v_player.id);

    -- ── DIPLOMACY ────────────────────────────────────────────────────────────

    v_ally_chance := 0.10 + v_player.ai_honor * 0.12 + v_enemy_count * 0.15
                   + v_pressure * 0.22 - v_ally_count * 0.05
                   + CASE WHEN v_ally_count = 0 THEN 0.15 ELSE 0 END;
    IF v_ally_count < 3 AND RANDOM() < v_ally_chance THEN
      SELECT id INTO v_rel FROM diplomacy
      WHERE game_id = p_game_id
        AND (player_a_id = v_player.id OR player_b_id = v_player.id)
        AND status = 'neutral'
        AND NOT (p_tick - COALESCE(status_changed_at_tick, 0) < 50 AND opinion_score < -10)
      ORDER BY opinion_score DESC, RANDOM() LIMIT 1;
      IF FOUND THEN
        UPDATE diplomacy SET status = 'ally', status_changed_at_tick = p_tick,
          opinion_score = LEAST(100, opinion_score + 25)
        WHERE id = v_rel.id;
        v_ally_count := v_ally_count + 1;
        -- Log alliance formation with public=false for post-game recap only
        INSERT INTO game_events (game_id, tick, event_type, player_id, data)
        VALUES (p_game_id, p_tick, 'alliance_formed', v_player.id,
          jsonb_build_object('other_player_id',
            CASE WHEN (SELECT player_a_id FROM diplomacy WHERE id = v_rel.id) = v_player.id
              THEN (SELECT player_b_id FROM diplomacy WHERE id = v_rel.id)
              ELSE (SELECT player_a_id FROM diplomacy WHERE id = v_rel.id) END,
            'public', false));
      END IF;
    END IF;

    IF v_enemy_count = 0 AND v_pers.expand_bias >= 1.5 THEN
      v_war_chance   := 0.04 + v_player.ai_vengefulness * 0.04 - v_player.ai_honor * 0.02;
      v_strength_thr := 0.9 + v_player.ai_rationality * 0.5;
      IF RANDOM() < v_war_chance THEN
        FOR v_rel IN
          SELECT d.id,
            CASE WHEN d.player_a_id = v_player.id THEN d.player_b_id ELSE d.player_a_id END AS other_pid
          FROM diplomacy d WHERE d.game_id = p_game_id
            AND (d.player_a_id = v_player.id OR d.player_b_id = v_player.id)
            AND d.status = 'neutral'
          ORDER BY d.opinion_score ASC LIMIT 1
        LOOP
          SELECT COALESCE(SUM(troops), 0) INTO v_other_troops
          FROM game_castles WHERE game_id = p_game_id AND owner_player_id = v_rel.other_pid;
          IF v_my_troops::NUMERIC / GREATEST(v_other_troops, 1) >= v_strength_thr THEN
            UPDATE diplomacy SET status = 'enemy', status_changed_at_tick = p_tick,
              opinion_score = GREATEST(-100, opinion_score - 35)
            WHERE id = v_rel.id;
            v_enemy_count := v_enemy_count + 1;
            INSERT INTO game_events (game_id, tick, event_type, player_id, data)
            VALUES (p_game_id, p_tick, 'war_declared', v_player.id,
              jsonb_build_object('other_player_id', v_rel.other_pid));
          END IF;
        END LOOP;
      END IF;
    END IF;

    -- Coalition war: any house resenting a near-victor can declare war regardless of expand_bias
    IF v_leader_id IS NOT NULL AND v_leader_id <> v_player.id
       AND v_leader_castles >= v_castles_needed * 0.60
       AND v_enemy_count < 2 THEN
      SELECT COALESCE(opinion_score, 0) INTO v_opinion FROM diplomacy
      WHERE game_id = p_game_id
        AND ((player_a_id = v_player.id AND player_b_id = v_leader_id)
          OR (player_b_id = v_player.id AND player_a_id = v_leader_id))
      LIMIT 1;
      IF v_opinion < -30 THEN
        SELECT id INTO v_rel FROM diplomacy
        WHERE game_id = p_game_id
          AND ((player_a_id = v_player.id AND player_b_id = v_leader_id)
            OR (player_b_id = v_player.id AND player_a_id = v_leader_id))
          AND status = 'neutral';
        IF FOUND AND RANDOM() < LEAST(0.40, (ABS(v_opinion) - 30) * 0.008 + v_pressure * 0.10) THEN
          UPDATE diplomacy SET status = 'enemy', status_changed_at_tick = p_tick,
            opinion_score = GREATEST(-100, opinion_score - 35)
          WHERE id = v_rel.id;
          v_enemy_count := v_enemy_count + 1;
          INSERT INTO game_events (game_id, tick, event_type, player_id, data)
          VALUES (p_game_id, p_tick, 'war_declared', v_player.id,
            jsonb_build_object('other_player_id', v_leader_id, 'coalition', true));
        END IF;
      END IF;
    END IF;

    -- Near-winner ally pressure: self-interest strains loyalty when an ally nears victory
    FOR v_rel IN
      SELECT d.id,
        CASE WHEN d.player_a_id = v_player.id THEN d.player_b_id ELSE d.player_a_id END AS ally_pid
      FROM diplomacy d WHERE d.game_id = p_game_id
        AND (d.player_a_id = v_player.id OR d.player_b_id = v_player.id)
        AND d.status = 'ally'
    LOOP
      DECLARE v_ally_progress NUMERIC;
      BEGIN
        SELECT COUNT(*)::NUMERIC / v_castles_needed INTO v_ally_progress
        FROM game_castles WHERE game_id = p_game_id AND owner_player_id = v_rel.ally_pid;
        -- If ally is 75%+ to winning, self-interest strains the bond (-6 opinion/cycle)
        IF v_ally_progress >= 0.75 THEN
          UPDATE diplomacy
          SET opinion_score = GREATEST(-100, opinion_score - (6 + (1 - v_player.ai_honor) * 8)::INT)
          WHERE id = v_rel.id;
        END IF;
      END;
    END LOOP;

    -- Opportunistic war: strike a neighbor already under attack from a third party
    IF v_enemy_count < 2 AND v_pers.expand_bias >= 1.0
       AND RANDOM() < LEAST(0.30, 0.12 + v_player.ai_vengefulness * 0.10 - v_player.ai_honor * 0.06)
    THEN
      FOR v_rel IN
        SELECT d.id,
          CASE WHEN d.player_a_id = v_player.id THEN d.player_b_id ELSE d.player_a_id END AS other_pid
        FROM diplomacy d WHERE d.game_id = p_game_id
          AND (d.player_a_id = v_player.id OR d.player_b_id = v_player.id)
          AND d.status = 'neutral'
        ORDER BY d.opinion_score ASC LIMIT 3
      LOOP
        IF EXISTS (
          SELECT 1 FROM commander_movements cm
          JOIN commanders c2 ON c2.id = cm.commander_id
          WHERE cm.game_id = p_game_id
            AND c2.owner_player_id <> v_rel.other_pid
            AND c2.owner_player_id <> v_player.id
            AND cm.arrives_at_tick > p_tick
            AND cm.to_castle_slug IN (
              SELECT castle_slug FROM game_castles
              WHERE game_id = p_game_id AND owner_player_id = v_rel.other_pid
            )
        ) THEN
          SELECT COALESCE(SUM(troops), 0) INTO v_other_troops
          FROM game_castles WHERE game_id = p_game_id AND owner_player_id = v_rel.other_pid;
          IF v_my_troops::NUMERIC / GREATEST(v_other_troops, 1) >= 0.70 THEN
            UPDATE diplomacy SET status = 'enemy', status_changed_at_tick = p_tick,
              opinion_score = GREATEST(-100, opinion_score - 35)
            WHERE id = v_rel.id;
            v_enemy_count := v_enemy_count + 1;
            INSERT INTO game_events (game_id, tick, event_type, player_id, data)
            VALUES (p_game_id, p_tick, 'war_declared', v_player.id,
              jsonb_build_object('other_player_id', v_rel.other_pid, 'opportunistic', true));
            EXIT;
          END IF;
        END IF;
      END LOOP;
    END IF;

    -- Ally war entry: honor the alliance when an ally is under attack
    FOR v_rel IN
      SELECT d.id,
        CASE WHEN d.player_a_id = v_player.id THEN d.player_b_id ELSE d.player_a_id END AS ally_pid
      FROM diplomacy d WHERE d.game_id = p_game_id
        AND (d.player_a_id = v_player.id OR d.player_b_id = v_player.id)
        AND d.status = 'ally'
    LOOP
      FOR v_target IN
        SELECT CASE WHEN d2.player_a_id = v_rel.ally_pid THEN d2.player_b_id ELSE d2.player_a_id END AS enemy_pid
        FROM diplomacy d2 WHERE d2.game_id = p_game_id
          AND (d2.player_a_id = v_rel.ally_pid OR d2.player_b_id = v_rel.ally_pid)
          AND d2.status = 'enemy'
      LOOP
        IF EXISTS (
          SELECT 1 FROM diplomacy d3 WHERE d3.game_id = p_game_id
            AND ((d3.player_a_id = v_player.id AND d3.player_b_id = v_target.enemy_pid)
              OR (d3.player_b_id = v_player.id AND d3.player_a_id = v_target.enemy_pid))
            AND d3.status = 'neutral'
        ) THEN
          SELECT COALESCE(SUM(troops), 0) INTO v_other_troops
          FROM game_castles WHERE game_id = p_game_id AND owner_player_id = v_target.enemy_pid;
          IF RANDOM() < LEAST(0.50, v_player.ai_honor * 0.20 + v_player.ai_vengefulness * 0.05)
             AND v_my_troops::NUMERIC / GREATEST(v_other_troops, 1) >= 0.65 THEN
            UPDATE diplomacy SET status = 'enemy', status_changed_at_tick = p_tick,
              opinion_score = GREATEST(-100, opinion_score - 35)
            WHERE game_id = p_game_id
              AND ((player_a_id = v_player.id AND player_b_id = v_target.enemy_pid)
                OR (player_b_id = v_player.id AND player_a_id = v_target.enemy_pid));
            v_enemy_count := v_enemy_count + 1;
            INSERT INTO game_events (game_id, tick, event_type, player_id, data)
            VALUES (p_game_id, p_tick, 'war_declared', v_player.id,
              jsonb_build_object('other_player_id', v_target.enemy_pid, 'in_defense_of', v_rel.ally_pid));
          END IF;
        END IF;
      END LOOP;
    END LOOP;

    -- Peace-making
    FOR v_rel IN
      SELECT d.id,
        CASE WHEN d.player_a_id = v_player.id THEN d.player_b_id ELSE d.player_a_id END AS other_pid,
        d.status_changed_at_tick
      FROM diplomacy d WHERE d.game_id = p_game_id
        AND (d.player_a_id = v_player.id OR d.player_b_id = v_player.id)
        AND d.status = 'enemy'
    LOOP
      v_war_ticks := p_tick - COALESCE(v_rel.status_changed_at_tick, 0);
      v_peace_chance := LEAST(0.35,
        0.015 + (v_war_ticks::NUMERIC / 400) + v_pressure * 0.10
        + v_player.ai_honor * 0.06 - v_player.ai_vengefulness * 0.04);
      IF v_peace_chance > 0 AND RANDOM() < v_peace_chance THEN
        SELECT COALESCE(SUM(troops), 0) INTO v_other_troops
        FROM game_castles WHERE game_id = p_game_id AND owner_player_id = v_rel.other_pid;
        IF v_my_troops::NUMERIC / GREATEST(v_other_troops, 1) < (1.1 + v_player.ai_rationality * 0.4)
           OR v_war_ticks > 120 THEN
          UPDATE diplomacy SET status = 'neutral', status_changed_at_tick = p_tick,
            opinion_score = GREATEST(-20, opinion_score + 40)
          WHERE id = v_rel.id;
          v_enemy_count := v_enemy_count - 1;
          INSERT INTO game_events (game_id, tick, event_type, player_id, data)
          VALUES (p_game_id, p_tick, 'peace_made', v_player.id,
            jsonb_build_object('other_player_id', v_rel.other_pid));
        END IF;
      END IF;
    END LOOP;

    -- Alliance breaking: opinion < -20 toward an ally triggers exit (public knowledge)
    FOR v_rel IN
      SELECT d.id,
        CASE WHEN d.player_a_id = v_player.id THEN d.player_b_id ELSE d.player_a_id END AS other_pid,
        d.opinion_score
      FROM diplomacy d WHERE d.game_id = p_game_id
        AND (d.player_a_id = v_player.id OR d.player_b_id = v_player.id)
        AND d.status = 'ally' AND d.opinion_score < -20
    LOOP
      v_break_chance := LEAST(0.40,
        (ABS(v_rel.opinion_score) - 20) * 0.008
        + v_player.ai_vengefulness * 0.05 - v_player.ai_honor * 0.08);
      IF v_break_chance > 0 AND RANDOM() < v_break_chance THEN
        UPDATE diplomacy SET status = 'neutral', status_changed_at_tick = p_tick,
          opinion_score = GREATEST(-30, v_rel.opinion_score + 10)
        WHERE id = v_rel.id;
        v_ally_count := v_ally_count - 1;
        INSERT INTO game_events (game_id, tick, event_type, player_id, data)
        VALUES (p_game_id, p_tick, 'alliance_broken', v_player.id,
          jsonb_build_object('other_player_id', v_rel.other_pid));
      END IF;
    END LOOP;

    -- ── INFRASTRUCTURE ────────────────────────────────────────────────────────

    IF v_pressure <= 0.75 THEN
      v_reserve := (80 + (1 - v_player.ai_greed) * 150 + (2 - v_pers.expand_bias) * 50)::INT;
      SELECT gold INTO v_my_gold FROM game_players WHERE id = v_player.id;
      v_budget := GREATEST(0, ((v_my_gold - v_reserve)::NUMERIC
        * (0.40 + v_player.ai_greed * 0.25 - v_pressure * 0.20))::INT);

      IF RANDOM() < (0.4 + v_player.ai_rationality * 0.6) THEN
        v_focus := CASE v_pers.focus_override
          WHEN 'coin'           THEN 'gold'
          WHEN 'laws'           THEN 'gold'
          WHEN 'lord_commander' THEN 'industry'
          WHEN 'grand_maester'  THEN 'prestige'
          WHEN 'whisperers'     THEN 'prestige'
          ELSE 'gold'
        END;
      ELSE
        v_focus := CASE (RANDOM() * 2)::INT WHEN 0 THEN 'gold' WHEN 1 THEN 'industry' ELSE 'prestige' END;
      END IF;
      v_sec_type := CASE v_focus WHEN 'gold' THEN 'industry' WHEN 'industry' THEN 'gold' ELSE 'gold' END;

      v_upgrades_done := 0;
      FOR v_castle IN
        SELECT gc.castle_slug, gc.effective_influence, gc.gold_level, gc.industry_level, gc.prestige_level
        FROM game_castles gc WHERE gc.game_id = p_game_id AND gc.owner_player_id = v_player.id
        ORDER BY gc.effective_influence DESC
      LOOP
        EXIT WHEN v_upgrades_done >= 5 OR v_budget <= 0;
        SELECT gold INTO v_my_gold FROM game_players WHERE id = v_player.id;
        v_cur_lv := CASE v_focus WHEN 'gold' THEN v_castle.gold_level
          WHEN 'industry' THEN v_castle.industry_level ELSE v_castle.prestige_level END;
        v_upgrade_cost := FLOOR(
          CASE v_focus WHEN 'gold' THEN 500 WHEN 'industry' THEN 1000 ELSE 4000 END
          * (v_cur_lv + 1)::NUMERIC / GREATEST(v_castle.effective_influence::NUMERIC, 1)
          * COALESCE(v_game.infra_cost_mult, 1.0))::INT;
        IF v_upgrade_cost <= v_budget AND v_my_gold - v_upgrade_cost >= v_reserve THEN
          UPDATE game_castles
          SET gold_level     = gold_level     + (CASE WHEN v_focus = 'gold'     THEN 1 ELSE 0 END),
              industry_level = industry_level + (CASE WHEN v_focus = 'industry' THEN 1 ELSE 0 END),
              prestige_level = prestige_level + (CASE WHEN v_focus = 'prestige' THEN 1 ELSE 0 END)
          WHERE game_id = p_game_id AND castle_slug = v_castle.castle_slug;
          UPDATE game_players SET gold = gold - v_upgrade_cost WHERE id = v_player.id;
          v_budget := v_budget - v_upgrade_cost; v_upgrades_done := v_upgrades_done + 1;
        END IF;
      END LOOP;

      v_upgrades_done := 0;
      FOR v_sec_castle IN
        SELECT gc.castle_slug, gc.effective_influence, gc.gold_level, gc.industry_level, gc.prestige_level
        FROM game_castles gc WHERE gc.game_id = p_game_id AND gc.owner_player_id = v_player.id
        ORDER BY gc.effective_influence DESC
      LOOP
        EXIT WHEN v_upgrades_done >= 2 OR v_budget <= 0;
        SELECT gold INTO v_my_gold FROM game_players WHERE id = v_player.id;
        v_cur_lv := CASE v_sec_type WHEN 'gold' THEN v_sec_castle.gold_level
          WHEN 'industry' THEN v_sec_castle.industry_level ELSE v_sec_castle.prestige_level END;
        v_upgrade_cost := FLOOR(
          CASE v_sec_type WHEN 'gold' THEN 500 WHEN 'industry' THEN 1000 ELSE 4000 END
          * (v_cur_lv + 1)::NUMERIC / GREATEST(v_sec_castle.effective_influence::NUMERIC, 1)
          * COALESCE(v_game.infra_cost_mult, 1.0))::INT;
        IF v_upgrade_cost <= v_budget AND v_my_gold - v_upgrade_cost >= v_reserve THEN
          UPDATE game_castles
          SET gold_level     = gold_level     + (CASE WHEN v_sec_type = 'gold'     THEN 1 ELSE 0 END),
              industry_level = industry_level + (CASE WHEN v_sec_type = 'industry' THEN 1 ELSE 0 END),
              prestige_level = prestige_level + (CASE WHEN v_sec_type = 'prestige' THEN 1 ELSE 0 END)
          WHERE game_id = p_game_id AND castle_slug = v_sec_castle.castle_slug;
          UPDATE game_players SET gold = gold - v_upgrade_cost WHERE id = v_player.id;
          v_budget := v_budget - v_upgrade_cost; v_upgrades_done := v_upgrades_done + 1;
        END IF;
      END LOOP;
    END IF;

    -- ── COUNCIL SEAT UPGRADES ─────────────────────────────────────────────────

    SELECT prestige INTO v_my_prestige FROM game_players WHERE id = v_player.id;
    v_target_seat := CASE v_pers.focus_override
      WHEN 'coin'           THEN 'coin'    WHEN 'lord_commander' THEN 'lord_commander'
      WHEN 'laws'           THEN 'laws'    WHEN 'grand_maester'  THEN 'grand_maester'
      WHEN 'whisperers'     THEN 'whisperers' WHEN 'hand'        THEN 'hand'
      ELSE 'coin'
    END;
    SELECT COALESCE(level, 1) INTO v_seat_lv FROM council_seats
    WHERE game_id = p_game_id AND player_id = v_player.id AND seat = v_target_seat;
    IF NOT FOUND THEN v_seat_lv := 1; END IF;
    v_seat_cost := 144 * v_seat_lv;
    IF v_my_prestige >= v_seat_cost THEN
      UPDATE game_players SET prestige = prestige - v_seat_cost WHERE id = v_player.id;
      INSERT INTO council_seats (game_id, player_id, seat, level, research_progress)
      VALUES (p_game_id, v_player.id, v_target_seat, v_seat_lv + 1, 0)
      ON CONFLICT (game_id, player_id, seat) DO UPDATE SET level = v_seat_lv + 1, research_progress = 0;
      INSERT INTO game_events (game_id, tick, event_type, player_id, data)
      VALUES (p_game_id, p_tick, 'council_upgraded', v_player.id,
        jsonb_build_object('seat', v_target_seat, 'new_level', v_seat_lv + 1, 'cost', v_seat_cost));
    END IF;

    -- ── COMMANDER RECRUITMENT (no cap — gold is the only limit) ───────────────
    -- Recruit when there's a well-stocked castle without an idle commander already present.
    -- Moderate random gate prevents recruiting every single tick.
    -- Cost: 200 gold per commander.

    SELECT gold INTO v_my_gold FROM game_players WHERE id = v_player.id;
    IF v_my_gold >= 400
       AND RANDOM() < LEAST(0.60, 0.15 + v_pers.expand_bias * 0.08 + v_closing * 0.20)
    THEN
      SELECT castle_slug INTO v_best_slug FROM game_castles
      WHERE game_id = p_game_id AND owner_player_id = v_player.id
        AND troops >= 80
        -- Don't stack idle commanders at the same castle
        AND NOT EXISTS (
          SELECT 1 FROM commanders c2
          WHERE c2.game_id = p_game_id AND c2.owner_player_id = v_player.id
            AND c2.current_castle_slug = game_castles.castle_slug AND c2.status = 'idle'
        )
      ORDER BY troops DESC LIMIT 1;

      SELECT cp.name INTO v_pool_name FROM commander_pool cp WHERE cp.house_slug = v_player.house_slug
        AND NOT EXISTS (SELECT 1 FROM commanders c2 WHERE c2.game_id = p_game_id
          AND c2.owner_player_id = v_player.id AND c2.name = cp.name)
      ORDER BY RANDOM() LIMIT 1;

      IF v_best_slug IS NOT NULL AND v_pool_name IS NOT NULL THEN
        INSERT INTO commanders (game_id, owner_player_id, name, is_named, level, experience,
          current_castle_slug, troops, status)
        VALUES (p_game_id, v_player.id, v_pool_name, TRUE, 1, 0, v_best_slug, 0, 'idle')
        RETURNING id INTO v_new_cmdr_id;
        UPDATE game_players SET gold = gold - 200 WHERE id = v_player.id;
        INSERT INTO game_events (game_id, tick, event_type, player_id, data)
        VALUES (p_game_id, p_tick, 'commander_recruited', v_player.id,
          jsonb_build_object('commander_id', v_new_cmdr_id, 'name', v_pool_name,
                             'is_named', TRUE, 'castle', v_best_slug, 'cost', 200));
      END IF;
    END IF;

    -- ── COMMANDER ORDERS (all idle commanders) ────────────────────────────────

    FOR v_cmdr IN
      SELECT c.id AS cmdr_id, c.current_castle_slug AS at_castle,
             cs.map_x AS from_x, cs.map_y AS from_y
      FROM commanders c
      JOIN game_castles gc ON gc.castle_slug = c.current_castle_slug AND gc.game_id = p_game_id
      JOIN castles cs ON cs.slug = c.current_castle_slug
      WHERE c.game_id = p_game_id AND c.owner_player_id = v_player.id AND c.status = 'idle'
      ORDER BY gc.troops DESC
    LOOP
      SELECT troops INTO v_garrison_live FROM game_castles
      WHERE game_id = p_game_id AND castle_slug = v_cmdr.at_castle;

      v_min_garrison := (65 * v_pers.troop_bias * (1 + v_pressure * 0.45))::INT;
      IF v_garrison_live < v_min_garrison THEN CONTINUE; END IF;

      v_threatened := NULL;
      SELECT cm.to_castle_slug INTO v_threatened
      FROM commander_movements cm JOIN commanders c2 ON c2.id = cm.commander_id
      WHERE cm.game_id = p_game_id AND c2.owner_player_id <> v_player.id
        AND cm.arrives_at_tick > p_tick
        AND cm.to_castle_slug IN (
          SELECT castle_slug FROM game_castles WHERE game_id = p_game_id AND owner_player_id = v_player.id
        )
        AND NOT EXISTS (SELECT 1 FROM diplomacy d WHERE d.game_id = p_game_id AND d.status = 'ally'
            AND ((d.player_a_id = v_player.id AND d.player_b_id = c2.owner_player_id)
              OR (d.player_b_id = v_player.id AND d.player_a_id = c2.owner_player_id)))
      ORDER BY cm.arrives_at_tick ASC LIMIT 1;

      IF v_threatened IS NOT NULL AND v_threatened <> v_cmdr.at_castle THEN
        v_best_slug := v_threatened;

      ELSIF v_pressure > 0.85 AND v_closing < 0.30 THEN
        SELECT castle_slug INTO v_best_slug FROM game_castles
        WHERE game_id = p_game_id AND owner_player_id = v_player.id
          AND castle_slug <> v_cmdr.at_castle
        ORDER BY troops ASC LIMIT 1;

      ELSE
        v_best_score := -999; v_best_slug := NULL;

        FOR v_target IN
          SELECT cs.slug, cs.tier, cs.map_x, cs.map_y,
                 gc.owner_player_id AS owner_pid, gc.troops AS garrison
          FROM castles cs JOIN game_castles gc ON gc.castle_slug = cs.slug AND gc.game_id = p_game_id
          WHERE cs.slug <> v_cmdr.at_castle
            AND gc.owner_player_id IS DISTINCT FROM v_player.id
            AND NOT EXISTS (SELECT 1 FROM diplomacy d WHERE d.game_id = p_game_id AND d.status = 'ally'
                AND gc.owner_player_id IS NOT NULL
                AND ((d.player_a_id = v_player.id AND d.player_b_id = gc.owner_player_id)
                  OR (d.player_b_id = v_player.id AND d.player_a_id = gc.owner_player_id)))
            AND NOT EXISTS (SELECT 1 FROM commander_movements cm2
                JOIN commanders c3 ON c3.id = cm2.commander_id
                WHERE cm2.game_id = p_game_id AND c3.owner_player_id = v_player.id
                  AND cm2.to_castle_slug = cs.slug AND cm2.arrives_at_tick > p_tick)
        LOOP
          IF v_target.owner_pid IS NOT NULL
             AND v_target.garrison >= v_garrison_live * v_pers.atk_bias
             AND NOT EXISTS (SELECT 1 FROM diplomacy d WHERE d.game_id = p_game_id AND d.status = 'enemy'
                 AND ((d.player_a_id = v_player.id AND d.player_b_id = v_target.owner_pid)
                   OR (d.player_b_id = v_player.id AND d.player_a_id = v_target.owner_pid)))
          THEN CONTINUE; END IF;

          v_dist := SQRT(POWER((v_target.map_x - v_cmdr.from_x) * 672, 2)
                       + POWER((v_target.map_y - v_cmdr.from_y) * 1560, 2));

          SELECT COALESCE(opinion_score, 0) INTO v_opinion FROM diplomacy
          WHERE game_id = p_game_id AND v_target.owner_pid IS NOT NULL
            AND ((player_a_id = v_player.id AND player_b_id = v_target.owner_pid)
              OR (player_b_id = v_player.id AND player_a_id = v_target.owner_pid))
          LIMIT 1;
          IF NOT FOUND THEN v_opinion := 0; END IF;

          v_score :=
            (4 - v_target.tier) * 15.0
            - v_dist * 0.10
            + CASE WHEN v_target.owner_pid IS NULL THEN 35 ELSE 0 END
            + CASE WHEN v_target.owner_pid IS NULL THEN (2 - v_pers.expand_bias) * 9 ELSE 0 END
            - GREATEST(0, (v_target.garrison::NUMERIC - v_garrison_live * 0.5) * 0.4 * v_pers.atk_bias)
            + v_pers.expand_bias * 14.0
            + CASE WHEN v_target.owner_pid IS NOT NULL
                THEN v_player.ai_vengefulness * GREATEST(0, -v_opinion) * 0.35
              ELSE 0 END
            + CASE WHEN v_target.owner_pid IS NOT NULL AND EXISTS (
                SELECT 1 FROM diplomacy d WHERE d.game_id = p_game_id AND d.status = 'enemy'
                  AND ((d.player_a_id = v_player.id AND d.player_b_id = v_target.owner_pid)
                    OR (d.player_b_id = v_player.id AND d.player_a_id = v_target.owner_pid))
              ) THEN 42 ELSE 0 END
            + CASE WHEN EXISTS (
                SELECT 1 FROM castles cs2
                JOIN game_castles gc2 ON gc2.castle_slug = cs2.slug AND gc2.game_id = p_game_id
                WHERE gc2.owner_player_id = v_player.id
                  AND SQRT(POWER((v_target.map_x - cs2.map_x) * 672, 2)
                         + POWER((v_target.map_y - cs2.map_y) * 1560, 2)) < 300
              ) THEN 20 ELSE 0 END
            + v_closing * 30.0
            - v_pressure * v_dist * 0.04
            + (RANDOM() * 16.0 - 8.0)
            + CASE WHEN EXISTS (
                SELECT 1 FROM pending_ai_actions paa
                WHERE paa.game_id = p_game_id
                  AND paa.ai_player_id = v_player.id
                  AND paa.action_type = 'attack_castle'
                  AND paa.castle_slug = v_target.slug
                  AND NOT paa.fulfilled
                  AND (paa.expires_tick IS NULL OR paa.expires_tick >= p_tick)
              ) THEN 300 ELSE 0 END;

          IF v_score > v_best_score THEN
            v_best_score := v_score; v_best_slug := v_target.slug;
          END IF;
        END LOOP;

        IF v_best_slug IS NULL THEN
          SELECT castle_slug INTO v_best_slug FROM game_castles
          WHERE game_id = p_game_id AND owner_player_id = v_player.id
            AND castle_slug <> v_cmdr.at_castle
          ORDER BY troops ASC LIMIT 1;
        END IF;
      END IF;

      IF v_best_slug IS NULL THEN CONTINUE; END IF;

      v_march_fraction := GREATEST(0.25,
        0.40 + v_pers.expand_bias * 0.10 - v_pressure * 0.12 + v_closing * 0.15 + RANDOM() * 0.06);
      v_march_troops := GREATEST(1, (v_garrison_live::NUMERIC * v_march_fraction)::INT);
      v_march_troops := LEAST(v_march_troops, v_garrison_live - GREATEST(15, (v_min_garrison * 0.3)::INT));
      IF v_march_troops < 5 THEN CONTINUE; END IF;

      SELECT cs.map_x, cs.map_y INTO v_to_x, v_to_y FROM castles cs WHERE cs.slug = v_best_slug;
      v_dist  := SQRT(POWER((v_to_x - v_cmdr.from_x) * 672, 2) + POWER((v_to_y - v_cmdr.from_y) * 1560, 2));
      v_ticks := GREATEST(1, CEIL(v_dist / (COALESCE(v_game.commander_speed_mult, 1.0) * 17.5))::INT);

      UPDATE game_castles SET troops = troops - v_march_troops
      WHERE game_id = p_game_id AND castle_slug = v_cmdr.at_castle;
      UPDATE commanders SET status = 'moving', current_castle_slug = NULL WHERE id = v_cmdr.cmdr_id;
      INSERT INTO commander_movements (commander_id, game_id, from_castle_slug, to_castle_slug,
        departed_at_tick, arrives_at_tick, troops, march_type)
      VALUES (v_cmdr.cmdr_id, p_game_id, v_cmdr.at_castle, v_best_slug,
        p_tick, p_tick + v_ticks, v_march_troops, 'assault');

      UPDATE pending_ai_actions SET fulfilled = true
      WHERE game_id = p_game_id AND ai_player_id = v_player.id
        AND action_type = 'attack_castle' AND castle_slug = v_best_slug AND NOT fulfilled;

    END LOOP;

  END LOOP;
END;
$function$

-- ============================================================================
-- process_ai_turns(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_ai_turns(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tick           INT;
  v_total_castles  INT;
  v_neutral_count  INT;
  v_leader_id      BIGINT;
  v_leader_castles INT;
  v_total_moves    INT  := 0;
  v_total_upgrades INT  := 0;
  v_total_recruits INT  := 0;
  v_summary        JSONB := '[]';

  -- ── Commander dispatch (section 1) ──────────────────────────────
  v_cmd          RECORD;
  v_from_id      BIGINT;
  v_from_slug    TEXT;
  v_from_troops  INT;
  v_from_level   INT;
  v_from_x       NUMERIC;
  v_from_y       NUMERIC;
  v_player_id    BIGINT;
  v_diff         INT;
  v_mode         TEXT;
  v_hand_lv      INT;
  v_scan_radius  NUMERIC;
  v_atk_threshold NUMERIC;
  v_troop_pct    NUMERIC;
  v_target_slug  TEXT;
  v_target_x     NUMERIC;
  v_target_y     NUMERIC;
  v_troops_to_send INT;
  v_dist         NUMERIC;
  v_travel_ticks INT;

  -- ── Infrastructure / council / recruit (section 2) ──────────────
  v_ai           RECORD;
  v_my_castles   INT;
  v_my_gold      INT;
  v_upgrades_this INT;
  v_max_upgrades INT;
  v_upg_budget   INT;
  v_upg          RECORD;
  v_upg_type     TEXT;
  v_upg_cost     INT;
  v_focus        TEXT;
  v_cur_focus    TEXT;
  v_idle_count   INT;
  v_recruit_castle TEXT;
  v_avail_cmd    RECORD;
  v_recruit_min  INT;
BEGIN
  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  SELECT COUNT(*) INTO v_total_castles FROM game_castles WHERE game_id = p_game_id;
  SELECT COUNT(*) INTO v_neutral_count  FROM game_castles WHERE game_id = p_game_id AND owner_player_id IS NULL;
  SELECT owner_player_id, COUNT(*)::INT
  INTO   v_leader_id, v_leader_castles
  FROM   game_castles WHERE game_id = p_game_id AND owner_player_id IS NOT NULL
  GROUP  BY owner_player_id ORDER BY COUNT(*) DESC LIMIT 1;

  -- ════════════════════════════════════════════════════════════════
  -- SECTION 1: COMMANDER DISPATCH
  -- Iterates all idle AI commanders in one loop.
  -- The JOIN condition gc.owner_player_id = c.owner_player_id is
  -- a pure SQL column comparison — no PL/pgSQL variable involved.
  -- ════════════════════════════════════════════════════════════════
  FOR v_cmd IN
    SELECT
      c.id                                                           AS cmd_id,
      c.level                                                        AS cmd_level,
      gc.castle_slug                                                 AS from_slug,
      gc.troops                                                      AS castle_troops,
      cs.map_x,
      cs.map_y,
      c.owner_player_id                                              AS player_id,
      gp.house_slug,
      COALESCE(gp.ai_difficulty, g.ai_difficulty, 3)                AS eff_diff,
      COALESCE(hp.troop_bias,  1.0)                                  AS troop_bias,
      COALESCE(hp.atk_bias,    1.0)                                  AS atk_bias,
      COALESCE(hp.expand_bias, 1)                                    AS expand_bias,
      (SELECT COUNT(*) FROM game_castles x
       WHERE x.game_id = p_game_id AND x.owner_player_id = c.owner_player_id) AS my_castles
    FROM commanders c
    -- Join to game_players to restrict to AI only
    JOIN game_players gp ON gp.id = c.owner_player_id
                        AND gp.game_id = p_game_id
                        AND gp.is_ai = TRUE
                        AND gp.eliminated_at_tick IS NULL
    JOIN games g ON g.id = p_game_id
    LEFT JOIN house_ai_personality hp ON hp.house_slug = gp.house_slug
    -- KEY FIX: gc.owner_player_id = c.owner_player_id (pure SQL, no variable)
    JOIN game_castles gc ON gc.game_id        = p_game_id
                        AND gc.castle_slug    = c.current_castle_slug
                        AND gc.owner_player_id = c.owner_player_id
    JOIN castles cs ON cs.slug = gc.castle_slug
    WHERE c.game_id      = p_game_id
      AND c.status       = 'idle'
      AND gc.troops      > 5
      AND cs.map_x       IS NOT NULL
      AND cs.map_y       IS NOT NULL
    ORDER BY c.owner_player_id, gc.troops DESC
  LOOP
    -- ── Extract every record field to a plain scalar first ─────────
    v_from_id     := v_cmd.cmd_id;
    v_from_slug   := v_cmd.from_slug;
    v_from_troops := v_cmd.castle_troops;
    v_from_level  := v_cmd.cmd_level;
    v_from_x      := v_cmd.map_x;
    v_from_y      := v_cmd.map_y;
    v_player_id   := v_cmd.player_id;
    v_diff        := v_cmd.eff_diff;

    -- Council level lookups using plain scalar v_player_id
    SELECT COALESCE(level,0) INTO v_hand_lv FROM council_seats
    WHERE  game_id = p_game_id AND player_id = v_player_id AND seat = 'hand';
    SELECT COALESCE(level,0) INTO v_scan_radius FROM council_seats
    WHERE  game_id = p_game_id AND player_id = v_player_id AND seat = 'whisperers';
    v_scan_radius := 200.0 + COALESCE(v_scan_radius, 0) * 60.0;

    -- Thresholds
    IF    v_diff = 1 THEN v_atk_threshold := 9999.0; v_troop_pct := 0.50;
    ELSIF v_diff = 2 THEN v_atk_threshold := 3.0;    v_troop_pct := 0.60;
    ELSIF v_diff = 3 THEN v_atk_threshold := 2.0;    v_troop_pct := 0.65;
    ELSIF v_diff = 4 THEN v_atk_threshold := 1.5;    v_troop_pct := 0.72;
    ELSE                  v_atk_threshold := 1.25;   v_troop_pct := 0.80;
    END IF;
    v_troop_pct     := LEAST(0.90, v_troop_pct * v_cmd.troop_bias);
    v_atk_threshold := v_atk_threshold * v_cmd.atk_bias;

    -- Strategic mode
    IF v_diff = 1 OR v_cmd.expand_bias = 0 THEN
      v_mode := 'EXPAND';
    ELSIF v_cmd.expand_bias = 2 THEN
      IF v_neutral_count > 3 THEN v_mode := 'EXPAND'; ELSE v_mode := 'PRESSURE'; END IF;
    ELSIF v_diff <= 3 THEN
      IF v_neutral_count > 4 THEN v_mode := 'EXPAND'; ELSE v_mode := 'PRESSURE'; END IF;
    ELSE
      IF v_leader_castles::NUMERIC / NULLIF(v_total_castles,0) > 0.25
           AND v_leader_id IS DISTINCT FROM v_player_id
        THEN v_mode := 'DOMINATE';
      ELSIF v_neutral_count > 2 THEN v_mode := 'EXPAND';
      ELSE v_mode := 'PRESSURE'; END IF;
    END IF;

    -- ── Phase 1: target scan ─────────────────────────────────────
    v_target_slug := NULL;

    SELECT gc2.castle_slug, cs2.map_x, cs2.map_y
    INTO   v_target_slug, v_target_x, v_target_y
    FROM   game_castles gc2
    JOIN   castles cs2 ON cs2.slug = gc2.castle_slug
    WHERE  gc2.game_id = p_game_id
      AND  cs2.map_x IS NOT NULL
      AND  (gc2.owner_player_id IS NULL OR gc2.owner_player_id != v_player_id)
      AND  NOT EXISTS (
        SELECT 1 FROM commander_movements cm2
        JOIN   commanders c3 ON c3.id = cm2.commander_id
        WHERE  cm2.game_id = p_game_id
          AND  cm2.to_castle_slug = gc2.castle_slug
          AND  c3.owner_player_id = v_player_id
      )
      AND (
        (v_mode = 'EXPAND' AND gc2.owner_player_id IS NULL)
        OR (v_mode IN ('PRESSURE','DOMINATE') AND (
          gc2.owner_player_id IS NULL
          OR (gc2.owner_player_id != v_player_id
              AND v_from_troops::NUMERIC * (1.0 + v_from_level * 0.10) * (1.0 + COALESCE(v_hand_lv,0) * 0.10)
                > gc2.troops::NUMERIC * 1.20 * v_atk_threshold)
        ))
      )
    ORDER BY
      CASE WHEN v_mode = 'DOMINATE' AND gc2.owner_player_id = v_leader_id THEN 0 ELSE 1 END,
      CASE WHEN gc2.owner_player_id IS NULL THEN 0 ELSE 1 END,
      CASE WHEN v_diff >= 4 THEN -(gc2.gold_level + gc2.industry_level + gc2.prestige_level) ELSE 0 END,
      SQRT(POWER((cs2.map_x - v_from_x)*672,2) + POWER((cs2.map_y - v_from_y)*1560,2))
    LIMIT 1;

    -- ── Phase 2: fallback — any neutral anywhere ──────────────────
    IF v_target_slug IS NULL THEN
      SELECT gc2.castle_slug, cs2.map_x, cs2.map_y
      INTO   v_target_slug, v_target_x, v_target_y
      FROM   game_castles gc2
      JOIN   castles cs2 ON cs2.slug = gc2.castle_slug
      WHERE  gc2.game_id = p_game_id
        AND  gc2.owner_player_id IS NULL
        AND  cs2.map_x IS NOT NULL
        AND  NOT EXISTS (
          SELECT 1 FROM commander_movements cm2
          JOIN   commanders c3 ON c3.id = cm2.commander_id
          WHERE  cm2.game_id = p_game_id
            AND  cm2.to_castle_slug = gc2.castle_slug
            AND  c3.owner_player_id = v_player_id
        )
      ORDER BY SQRT(POWER((cs2.map_x - v_from_x)*672,2) + POWER((cs2.map_y - v_from_y)*1560,2))
      LIMIT 1;
    END IF;

    -- ── Execute ───────────────────────────────────────────────────
    IF v_target_slug IS NOT NULL THEN
      v_troops_to_send := GREATEST(1, FLOOR(v_from_troops * v_troop_pct)::INT);
      v_dist           := SQRT(POWER((v_target_x - v_from_x)*672,2)
                              + POWER((v_target_y - v_from_y)*1560,2));
      v_travel_ticks   := GREATEST(1, CEIL(v_dist / 17.5)::INT);

      UPDATE game_castles SET troops = troops - v_troops_to_send
      WHERE  game_id = p_game_id AND castle_slug = v_from_slug;

      UPDATE commanders SET status = 'moving', current_castle_slug = NULL
      WHERE  id = v_from_id;

      INSERT INTO commander_movements
        (commander_id, game_id, from_castle_slug, to_castle_slug,
         departed_at_tick, arrives_at_tick, troops)
      VALUES
        (v_from_id, p_game_id, v_from_slug, v_target_slug,
         v_tick, v_tick + v_travel_ticks, v_troops_to_send);

      v_total_moves := v_total_moves + 1;
    END IF;
  END LOOP;

  -- ════════════════════════════════════════════════════════════════
  -- SECTION 2: INFRASTRUCTURE / COUNCIL / RECRUIT
  -- Still loops per AI player (no JOIN issue here — upgrades and
  -- council queries use simple WHERE player_id = v_ai.id which works
  -- fine in scalar context outside JOIN ON clauses).
  -- ════════════════════════════════════════════════════════════════
  FOR v_ai IN
    SELECT gp.id, gp.gold, gp.house_slug, gp.research_seat,
           COALESCE(gp.ai_difficulty, g.ai_difficulty, 3) AS eff_diff,
           COALESCE(hp.focus_override, NULL)               AS focus_override
    FROM   game_players gp
    JOIN   games g ON g.id = gp.game_id
    LEFT   JOIN house_ai_personality hp ON hp.house_slug = gp.house_slug
    WHERE  gp.game_id = p_game_id AND gp.is_ai = TRUE AND gp.eliminated_at_tick IS NULL
  LOOP
    v_diff          := v_ai.eff_diff;
    v_my_gold       := v_ai.gold;
    v_upgrades_this := 0;
    SELECT COUNT(*) INTO v_my_castles FROM game_castles WHERE game_id=p_game_id AND owner_player_id=v_ai.id;

    -- Infrastructure upgrades
    IF v_diff >= 2 THEN
      IF    v_diff = 2 THEN v_upg_budget := v_my_gold / 4;        v_max_upgrades := 1;
      ELSIF v_diff = 3 THEN v_upg_budget := v_my_gold / 3;        v_max_upgrades := 2;
      ELSIF v_diff = 4 THEN v_upg_budget := v_my_gold / 2;        v_max_upgrades := 4;
      ELSE                  v_upg_budget := (v_my_gold * 2) / 3;  v_max_upgrades := 8;
      END IF;

      WHILE v_upgrades_this < v_max_upgrades AND v_upg_budget > 50 LOOP
        SELECT gc.castle_slug, gc.gold_level, gc.industry_level, gc.prestige_level,
               GREATEST(1, gc.effective_influence) AS infl
        INTO   v_upg
        FROM   game_castles gc
        WHERE  gc.game_id = p_game_id AND gc.owner_player_id = v_ai.id
        ORDER  BY gc.effective_influence DESC, (gc.gold_level+gc.industry_level+gc.prestige_level) ASC
        LIMIT  1;
        EXIT WHEN NOT FOUND;

        IF v_diff = 2 THEN
          v_upg_type := 'industry';
          v_upg_cost := FLOOR(1000*(v_upg.industry_level+1)/v_upg.infl);
        ELSIF v_diff = 3 THEN
          IF FLOOR(500*(v_upg.gold_level+1)/v_upg.infl) < FLOOR(1000*(v_upg.industry_level+1)/v_upg.infl)
            THEN v_upg_type := 'gold';     v_upg_cost := FLOOR(500*(v_upg.gold_level+1)/v_upg.infl);
            ELSE v_upg_type := 'industry'; v_upg_cost := FLOOR(1000*(v_upg.industry_level+1)/v_upg.infl);
          END IF;
        ELSE
          DECLARE
            v_cg INT := FLOOR(500 *(v_upg.gold_level    +1)/v_upg.infl);
            v_ci INT := FLOOR(1000*(v_upg.industry_level+1)/v_upg.infl);
            v_cp INT := FLOOR(4000*(v_upg.prestige_level+1)/v_upg.infl);
          BEGIN
            IF v_ai.focus_override IN ('coin','laws')           THEN v_cg := FLOOR(v_cg*0.8); END IF;
            IF v_ai.focus_override IN ('hand','lord_commander') THEN v_ci := FLOOR(v_ci*0.8); END IF;
            IF v_cg<=v_ci AND v_cg<=v_cp THEN
              v_upg_type:='gold';     v_upg_cost:=FLOOR(500 *(v_upg.gold_level    +1)/v_upg.infl);
            ELSIF v_ci<=v_cp THEN
              v_upg_type:='industry'; v_upg_cost:=FLOOR(1000*(v_upg.industry_level+1)/v_upg.infl);
            ELSE
              v_upg_type:='prestige'; v_upg_cost:=FLOOR(4000*(v_upg.prestige_level+1)/v_upg.infl);
            END IF;
          END;
        END IF;

        EXIT WHEN v_upg_cost > v_my_gold OR v_upg_cost > v_upg_budget;

        UPDATE game_castles SET
          gold_level     = CASE WHEN v_upg_type='gold'     THEN gold_level+1     ELSE gold_level     END,
          industry_level = CASE WHEN v_upg_type='industry' THEN industry_level+1 ELSE industry_level END,
          prestige_level = CASE WHEN v_upg_type='prestige' THEN prestige_level+1 ELSE prestige_level END
        WHERE game_id=p_game_id AND castle_slug=v_upg.castle_slug;

        UPDATE game_players SET gold=gold-v_upg_cost WHERE id=v_ai.id;
        v_my_gold    := v_my_gold    - v_upg_cost;
        v_upg_budget := v_upg_budget - v_upg_cost;
        v_upgrades_this  := v_upgrades_this  + 1;
        v_total_upgrades := v_total_upgrades + 1;
      END LOOP;
    END IF;

    -- Council training
    IF v_diff >= 3 THEN
      SELECT research_seat INTO v_cur_focus FROM game_players WHERE id=v_ai.id;
      IF v_ai.focus_override IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM council_seats WHERE game_id=p_game_id AND player_id=v_ai.id AND seat=v_ai.focus_override AND level>=3)
        THEN v_focus := v_ai.focus_override;
      ELSIF v_diff = 3 THEN
        IF    NOT EXISTS (SELECT 1 FROM council_seats WHERE game_id=p_game_id AND player_id=v_ai.id AND seat='hand' AND level>=3) THEN v_focus:='hand';
        ELSIF NOT EXISTS (SELECT 1 FROM council_seats WHERE game_id=p_game_id AND player_id=v_ai.id AND seat='coin' AND level>=2) THEN v_focus:='coin';
        ELSE v_focus:='lord_commander'; END IF;
      ELSIF v_diff = 4 THEN
        IF    NOT EXISTS (SELECT 1 FROM council_seats WHERE game_id=p_game_id AND player_id=v_ai.id AND seat='grand_maester' AND level>=2) THEN v_focus:='grand_maester';
        ELSIF NOT EXISTS (SELECT 1 FROM council_seats WHERE game_id=p_game_id AND player_id=v_ai.id AND seat='hand' AND level>=3) THEN v_focus:='hand';
        ELSE v_focus:='lord_commander'; END IF;
      ELSE
        IF    NOT EXISTS (SELECT 1 FROM council_seats WHERE game_id=p_game_id AND player_id=v_ai.id AND seat='grand_maester' AND level>=3) THEN v_focus:='grand_maester';
        ELSIF NOT EXISTS (SELECT 1 FROM council_seats WHERE game_id=p_game_id AND player_id=v_ai.id AND seat='coin' AND level>=3) THEN v_focus:='coin';
        ELSE v_focus:='hand'; END IF;
      END IF;

      IF v_cur_focus IS DISTINCT FROM v_focus
         AND NOT EXISTS (SELECT 1 FROM council_seats WHERE game_id=p_game_id AND player_id=v_ai.id AND seat=v_focus AND level>=5)
        THEN UPDATE game_players SET research_seat=v_focus WHERE id=v_ai.id;
      END IF;
    END IF;

    -- Recruit
    IF v_diff >= 2 THEN
      IF    v_diff=2 THEN v_recruit_min:=200;
      ELSIF v_diff=3 THEN v_recruit_min:=150;
      ELSIF v_diff=4 THEN v_recruit_min:=100;
      ELSE                v_recruit_min:=80;
      END IF;

      SELECT COUNT(*) INTO v_idle_count FROM commanders
      WHERE  game_id=p_game_id AND owner_player_id=v_ai.id AND status='idle';

      IF v_idle_count=0 AND v_my_gold>=v_recruit_min THEN
        SELECT gc.castle_slug INTO v_recruit_castle FROM game_castles gc
        WHERE  gc.game_id=p_game_id AND gc.owner_player_id=v_ai.id ORDER BY gc.troops DESC LIMIT 1;
        IF FOUND THEN
          SELECT * INTO v_avail_cmd FROM commanders
          WHERE  game_id=p_game_id AND status='available' AND owner_player_id IS NULL
          ORDER  BY level DESC LIMIT 1;
          IF FOUND THEN
            UPDATE commanders SET owner_player_id=v_ai.id, status='idle',
              current_castle_slug=v_recruit_castle, level=LEAST(v_diff,5)
            WHERE id=v_avail_cmd.id;
            UPDATE game_players SET gold=gold-100 WHERE id=v_ai.id;
            v_total_recruits := v_total_recruits + 1;
          END IF;
        END IF;
      END IF;
    END IF;

    v_summary := v_summary || jsonb_build_object(
      'house', v_ai.house_slug, 'diff', v_diff,
      'castles', v_my_castles, 'upgrades', v_upgrades_this
    );
  END LOOP;

  RETURN jsonb_build_object(
    'total_moves',    v_total_moves,
    'total_upgrades', v_total_upgrades,
    'total_recruits', v_total_recruits,
    'detail',         v_summary
  );
END;
$function$

-- ============================================================================
-- process_all_active_games()
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_all_active_games()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_game      RECORD;
  v_result    JSONB;
  v_winner    JSONB;
  v_ai        JSONB;
  v_games_run INT   := 0;
  v_ticks_sum INT   := 0;
  v_summary   JSONB := '[]';
BEGIN
  FOR v_game IN SELECT id, name FROM games WHERE status = 'active' LOOP
    BEGIN
      v_result := process_ticks(v_game.id);
      IF (v_result->>'pending_ticks')::INT > 0 THEN
        v_ai := process_ai_turns(v_game.id);
      END IF;
      IF (v_result->>'cycles_fired')::INT > 0 THEN
        v_winner := check_win_condition(v_game.id);
        PERFORM record_intel_snapshot(v_game.id);
      END IF;
      v_games_run := v_games_run + 1;
      v_ticks_sum := v_ticks_sum + COALESCE((v_result->>'pending_ticks')::INT, 0);
      v_summary   := v_summary || jsonb_build_object(
        'game', v_game.name, 'ticks', v_result->>'pending_ticks',
        'cycles', v_result->>'cycles_fired', 'winner', v_winner->>'winner', 'ai', v_ai
      );
    EXCEPTION WHEN OTHERS THEN
      v_summary := v_summary || jsonb_build_object('game', v_game.name, 'error', SQLERRM);
    END;
  END LOOP;
  RETURN jsonb_build_object('games_processed',v_games_run,'total_ticks',v_ticks_sum,'ran_at',NOW(),'detail',v_summary);
END;
$function$

-- ============================================================================
-- process_ticks(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_ticks(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_game            RECORD;
  v_now             TIMESTAMPTZ := NOW();
  v_pending         INT;
  v_cycles_fired    INT := 0;
  v_combats         INT := 0;
  v_i               INT;
  v_tick            INT;
  v_cycle_len       INT;

  v_player          RECORD;
  v_castle          RECORD;
  v_hand_lv         INT;
  v_coin_lv         INT;
  v_lord_lv         INT;
  v_gm_lv           INT;
  v_laws_lv         INT;
  v_troop_prod      NUMERIC;
  v_gold_prod       NUMERIC;
  v_prestige_prod   NUMERIC;
  v_gold_earned     NUMERIC;
  v_prestige_earned NUMERIC;
  v_seat_progress   INT;

  v_research_seat   TEXT;
  v_gm_rand_seat    TEXT;
  v_cur_lv          INT;
  v_train_cost      NUMERIC;
  v_council_mult    NUMERIC;

  v_total_gold_lv     INT;
  v_total_prestige_lv INT;
  v_castles_owned     INT;

  v_movement       RECORD;
  v_dest_gc        RECORD;
  v_dest_cmd       RECORD;
  v_cmd_owner      BIGINT;
  v_cmd_level      INT;

  v_wp_action      TEXT;
  v_wp_amount      INT;
  v_new_troops     INT;
  v_action_val     INT;

  v_obs_player          RECORD;
  v_mow_lv              INT;
  v_catch_rate          NUMERIC;
  v_whisper_interval    INT;
  v_whisper_conf        INT;
  v_inserted_whisper_id BIGINT;
  v_new_whisper_ids     BIGINT[] := ARRAY[]::BIGINT[];

  -- Open-field combat
  v_fought_mov_ids  BIGINT[];
  v_field_pair      RECORD;
  v_of_whisp_a      INT;
  v_of_whisp_b      INT;
  v_of_hand_a       INT;
  v_of_hand_b       INT;
  v_of_dmg_a        INT;
  v_of_dmg_b        INT;
  v_of_r_a          INT;
  v_of_r_b          INT;
  v_of_init_a       BOOLEAN;
  v_of_surv_a       INT;
  v_of_surv_b       INT;
  v_of_winner       TEXT;

  -- Siege bleed
  v_siege_rec       RECORD;
  v_siege_bleed     INT;
  v_garr_bleed      INT;
  v_new_siege_t     INT;
  v_new_garr_t      INT;
  v_castle_nm2      TEXT;
  v_infra_roll      NUMERIC;

  -- Siege arrival scenarios
  v_siege_at_dest      RECORD;
  v_should_face_castle BOOLEAN;
  v_outside_winner     TEXT;
  v_outside_surv_m     INT;
  v_outside_surv_s     INT;
  v_outside_hand_m     INT;
  v_outside_hand_s     INT;
  v_outside_dmg_m      INT;
  v_outside_dmg_s      INT;
  v_outside_r_m        INT;
  v_outside_r_s        INT;
  v_outside_init_m     BOOLEAN;
  v_outside_whisp_m    INT;
  v_outside_whisp_s    INT;
  v_eff_troops         INT;

BEGIN
  SELECT * INTO v_game FROM games WHERE id = p_game_id FOR UPDATE;
  IF v_game.status NOT IN ('active') THEN
    RETURN jsonb_build_object('pending_ticks',0,'cycles_fired',0,'combats',0,'new_whisper_ids',ARRAY[]::BIGINT[]);
  END IF;

  -- Initialize turn deadline on first tick for turn-based games
  IF v_game.tick_speed = 'turn_based' AND v_game.current_turn_ends_at IS NULL THEN
    UPDATE games
    SET current_turn_ends_at = v_now + (COALESCE(turn_timeout_minutes, 1440) * INTERVAL '1 minute')
    WHERE id = p_game_id;
    SELECT * INTO v_game FROM games WHERE id = p_game_id;
  END IF;

  v_pending := CASE v_game.tick_speed
    WHEN 'slow'       THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 7200)
    WHEN 'normal'     THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 3600)
    WHEN 'fast'       THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 1800)
    WHEN 'quad'       THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 900)
    WHEN 'turn_based' THEN (
      CASE WHEN
        NOT EXISTS (
          SELECT 1 FROM game_players
          WHERE game_id = p_game_id AND eliminated_at_tick IS NULL AND NOT is_ai AND NOT turn_submitted
        )
        OR (v_game.current_turn_ends_at IS NOT NULL AND v_now >= v_game.current_turn_ends_at)
      THEN COALESCE(v_game.ticks_per_turn, 1)
      ELSE 0 END
    )
    ELSE 0
  END;

  IF v_pending <= 0 THEN
    RETURN jsonb_build_object('pending_ticks',0,'cycles_fired',0,'combats',0,'new_whisper_ids',ARRAY[]::BIGINT[]);
  END IF;

  v_cycle_len    := COALESCE(v_game.production_cycle_ticks, 12);
  v_council_mult := COALESCE(v_game.council_cost_mult, 1.0);

  FOR v_i IN 1..v_pending LOOP
    v_tick           := v_game.current_tick + v_i;
    v_fought_mov_ids := ARRAY[]::BIGINT[];

    -- Per-tick troop production (fractional accumulator)
    FOR v_player IN
      SELECT gp.id, gp.research_seat FROM game_players gp
      WHERE gp.game_id = p_game_id AND gp.eliminated_at_tick IS NULL
    LOOP
      SELECT COALESCE(level, 1) INTO v_lord_lv FROM council_seats
      WHERE game_id=p_game_id AND player_id=v_player.id AND seat='lord_commander';

      WITH new_vals AS (
        SELECT id,
          FLOOR(troop_accumulator + (industry_level::NUMERIC * (v_lord_lv + 4) / v_cycle_len::NUMERIC)) AS troops_to_add,
          (troop_accumulator + (industry_level::NUMERIC * (v_lord_lv + 4) / v_cycle_len::NUMERIC))
            - FLOOR(troop_accumulator + (industry_level::NUMERIC * (v_lord_lv + 4) / v_cycle_len::NUMERIC)) AS new_accumulator
        FROM game_castles
        WHERE game_id = p_game_id AND owner_player_id = v_player.id
      )
      UPDATE game_castles gc SET
        troops            = gc.troops + nv.troops_to_add::INT,
        troop_accumulator = nv.new_accumulator
      FROM new_vals nv WHERE gc.id = nv.id;

      IF v_player.research_seat IS NOT NULL THEN
        SELECT COALESCE(SUM(prestige_level), 0) INTO v_prestige_prod
        FROM game_castles WHERE game_id=p_game_id AND owner_player_id=v_player.id;

        IF v_prestige_prod > 0 THEN
          SELECT COALESCE(level, 1) INTO v_cur_lv FROM council_seats
          WHERE game_id=p_game_id AND player_id=v_player.id AND seat=v_player.research_seat;
          v_cur_lv     := COALESCE(v_cur_lv, 1);
          v_train_cost := 144.0 * v_cur_lv * v_council_mult;

          INSERT INTO council_seats (game_id, player_id, seat, level, research_progress)
          VALUES (p_game_id, v_player.id, v_player.research_seat, 1, v_prestige_prod::INT)
          ON CONFLICT (game_id, player_id, seat) DO UPDATE
            SET research_progress = council_seats.research_progress + v_prestige_prod::INT
          RETURNING research_progress INTO v_seat_progress;

          IF v_seat_progress >= v_train_cost THEN
            UPDATE council_seats SET level = level + 1, research_progress = 0
            WHERE game_id=p_game_id AND player_id=v_player.id AND seat=v_player.research_seat;
            INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
              (p_game_id,v_player.id,v_tick,'system','Council Advancement',
               jsonb_build_object('gift_type','council_levelup','seat',v_player.research_seat,'new_level',v_cur_lv+1,'source','research'));
          END IF;
        END IF;
      END IF;
    END LOOP;

    -- Open-field combat (proximity check ≤20.2 map units)
    FOR v_field_pair IN
      WITH pos AS (
        SELECT
          cm_a.id AS id_a, cm_b.id AS id_b,
          cm_a.commander_id AS cmd_id_a, cm_b.commander_id AS cmd_id_b,
          cm_a.troops AS troops_a, cm_b.troops AS troops_b,
          ca.owner_player_id AS player_a, cb.owner_player_id AS player_b,
          ca.level AS cmd_lv_a, cb.level AS cmd_lv_b,
          ca.name AS cmd_name_a, cb.name AS cmd_name_b,
          fa.map_x + (ta.map_x - fa.map_x) *
            LEAST(1.0, (v_tick - cm_a.departed_at_tick)::NUMERIC /
            GREATEST(1, cm_a.arrives_at_tick - cm_a.departed_at_tick)) AS ax,
          fa.map_y + (ta.map_y - fa.map_y) *
            LEAST(1.0, (v_tick - cm_a.departed_at_tick)::NUMERIC /
            GREATEST(1, cm_a.arrives_at_tick - cm_a.departed_at_tick)) AS ay,
          fb.map_x + (tb.map_x - fb.map_x) *
            LEAST(1.0, (v_tick - cm_b.departed_at_tick)::NUMERIC /
            GREATEST(1, cm_b.arrives_at_tick - cm_b.departed_at_tick)) AS bx,
          fb.map_y + (tb.map_y - fb.map_y) *
            LEAST(1.0, (v_tick - cm_b.departed_at_tick)::NUMERIC /
            GREATEST(1, cm_b.arrives_at_tick - cm_b.departed_at_tick)) AS by
        FROM commander_movements cm_a
        JOIN commander_movements cm_b ON cm_a.game_id = cm_b.game_id AND cm_a.id < cm_b.id
        JOIN commanders ca ON ca.id = cm_a.commander_id
        JOIN commanders cb ON cb.id = cm_b.commander_id
        JOIN castles fa ON fa.slug = cm_a.from_castle_slug
        JOIN castles ta ON ta.slug = cm_a.to_castle_slug
        JOIN castles fb ON fb.slug = cm_b.from_castle_slug
        JOIN castles tb ON tb.slug = cm_b.to_castle_slug
        WHERE cm_a.game_id = p_game_id
          AND ca.owner_player_id <> cb.owner_player_id
          AND cm_a.departed_at_tick <= v_tick AND cm_b.departed_at_tick <= v_tick
          AND cm_a.arrives_at_tick  >  v_tick AND cm_b.arrives_at_tick  >  v_tick
      )
      SELECT *, SQRT(POWER((ax-bx)*672.0,2) + POWER((ay-by)*1560.0,2)) AS dist
      FROM pos WHERE SQRT(POWER((ax-bx)*672.0,2) + POWER((ay-by)*1560.0,2)) <= 20.2
    LOOP
      CONTINUE WHEN v_field_pair.id_a = ANY(v_fought_mov_ids) OR v_field_pair.id_b = ANY(v_fought_mov_ids);

      SELECT COALESCE(level,1) INTO v_of_whisp_a FROM council_seats WHERE game_id=p_game_id AND player_id=v_field_pair.player_a AND seat='whisperers';
      SELECT COALESCE(level,1) INTO v_of_whisp_b FROM council_seats WHERE game_id=p_game_id AND player_id=v_field_pair.player_b AND seat='whisperers';
      v_of_init_a := CASE WHEN v_of_whisp_a > v_of_whisp_b THEN TRUE WHEN v_of_whisp_b > v_of_whisp_a THEN FALSE ELSE (RANDOM() < 0.5) END;
      SELECT COALESCE(level,1) INTO v_of_hand_a FROM council_seats WHERE game_id=p_game_id AND player_id=v_field_pair.player_a AND seat='hand';
      SELECT COALESCE(level,1) INTO v_of_hand_b FROM council_seats WHERE game_id=p_game_id AND player_id=v_field_pair.player_b AND seat='hand';
      v_of_dmg_a := GREATEST(1, ROUND(v_of_hand_a::NUMERIC*(1.0+v_field_pair.cmd_lv_a*0.1))::INT);
      v_of_dmg_b := GREATEST(1, ROUND(v_of_hand_b::NUMERIC*(1.0+v_field_pair.cmd_lv_b*0.1))::INT);
      v_of_r_a := CEIL(v_field_pair.troops_a::NUMERIC / v_of_dmg_b)::INT;
      v_of_r_b := CEIL(v_field_pair.troops_b::NUMERIC / v_of_dmg_a)::INT;

      IF v_of_init_a THEN
        IF v_of_r_b <= v_of_r_a THEN v_of_winner:='a'; v_of_surv_a:=GREATEST(1,v_field_pair.troops_a-(v_of_r_b-1)*v_of_dmg_b); v_of_surv_b:=0;
        ELSE v_of_winner:='b'; v_of_surv_a:=0; v_of_surv_b:=GREATEST(1,v_field_pair.troops_b-v_of_r_a*v_of_dmg_a); END IF;
      ELSE
        IF v_of_r_a <= v_of_r_b THEN v_of_winner:='b'; v_of_surv_b:=GREATEST(1,v_field_pair.troops_b-(v_of_r_a-1)*v_of_dmg_a); v_of_surv_a:=0;
        ELSE v_of_winner:='a'; v_of_surv_b:=0; v_of_surv_a:=GREATEST(1,v_field_pair.troops_a-v_of_r_b*v_of_dmg_b); END IF;
      END IF;

      IF v_of_winner = 'a' THEN
        UPDATE commander_movements SET troops=v_of_surv_a WHERE id=v_field_pair.id_a;
        UPDATE commanders SET troops=v_of_surv_a WHERE id=v_field_pair.cmd_id_a;
        DELETE FROM commander_movements WHERE id=v_field_pair.id_b;
        UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_field_pair.cmd_id_b;
        UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_field_pair.cmd_id_b AND status='active';
      ELSE
        UPDATE commander_movements SET troops=v_of_surv_b WHERE id=v_field_pair.id_b;
        UPDATE commanders SET troops=v_of_surv_b WHERE id=v_field_pair.cmd_id_b;
        DELETE FROM commander_movements WHERE id=v_field_pair.id_a;
        UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_field_pair.cmd_id_a;
        UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_field_pair.cmd_id_a AND status='active';
      END IF;

      INSERT INTO player_inbox (game_id, player_id, tick, type, title, body) VALUES
        (p_game_id, v_field_pair.player_a, v_tick, 'combat', CASE WHEN v_of_winner='a' THEN 'Field Victory' ELSE 'Field Defeat' END,
          jsonb_build_object('combat_type','open_field','result',v_of_winner,'role','a',
            'cmd_name_a',v_field_pair.cmd_name_a,'cmd_name_b',v_field_pair.cmd_name_b,
            'player_a',v_field_pair.player_a,'player_b',v_field_pair.player_b,
            'troops_a_before',v_field_pair.troops_a,'troops_b_before',v_field_pair.troops_b,
            'troops_a_after',v_of_surv_a,'troops_b_after',v_of_surv_b,
            'atk_dmg',v_of_dmg_a,'def_dmg',v_of_dmg_b,'hand_a',v_of_hand_a,'hand_b',v_of_hand_b,
            'initiative',CASE WHEN v_of_init_a THEN 'a' ELSE 'b' END)),
        (p_game_id, v_field_pair.player_b, v_tick, 'combat', CASE WHEN v_of_winner='b' THEN 'Field Victory' ELSE 'Field Defeat' END,
          jsonb_build_object('combat_type','open_field','result',v_of_winner,'role','b',
            'cmd_name_a',v_field_pair.cmd_name_a,'cmd_name_b',v_field_pair.cmd_name_b,
            'player_a',v_field_pair.player_a,'player_b',v_field_pair.player_b,
            'troops_a_before',v_field_pair.troops_a,'troops_b_before',v_field_pair.troops_b,
            'troops_a_after',v_of_surv_a,'troops_b_after',v_of_surv_b,
            'atk_dmg',v_of_dmg_a,'def_dmg',v_of_dmg_b,'hand_a',v_of_hand_a,'hand_b',v_of_hand_b,
            'initiative',CASE WHEN v_of_init_a THEN 'a' ELSE 'b' END));

      v_fought_mov_ids := v_fought_mov_ids || ARRAY[v_field_pair.id_a, v_field_pair.id_b];
      v_combats := v_combats + 1;
    END LOOP;

    -- Siege bleed: 3% per tick to both sides, castle bonus fire first in manual assault
    FOR v_siege_rec IN
      SELECT gc.castle_slug, gc.troops AS garr_troops, gc.owner_player_id AS garr_player,
             c.id AS siege_cmd_id, c.troops AS siege_troops, c.owner_player_id AS siege_player, c.name AS siege_cmd_name
      FROM game_castles gc
      JOIN commanders c ON c.game_id=p_game_id AND c.current_castle_slug=gc.castle_slug AND c.status='sieging'
      WHERE gc.game_id=p_game_id AND gc.is_under_siege=TRUE
    LOOP
      v_siege_bleed := GREATEST(1, FLOOR(v_siege_rec.siege_troops * 0.03)::INT);
      v_garr_bleed  := GREATEST(1, FLOOR(v_siege_rec.garr_troops  * 0.03)::INT);
      v_new_siege_t := GREATEST(0, v_siege_rec.siege_troops - v_siege_bleed);
      v_new_garr_t  := GREATEST(0, v_siege_rec.garr_troops  - v_garr_bleed);
      SELECT name INTO v_castle_nm2 FROM castles WHERE slug=v_siege_rec.castle_slug;

      IF v_new_siege_t = 0 THEN
        -- Siege army wiped out by bleed
        UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_siege_rec.siege_cmd_id;
        UPDATE game_castles SET is_under_siege=FALSE, siege_started_at_tick=NULL, troops=v_new_garr_t WHERE game_id=p_game_id AND castle_slug=v_siege_rec.castle_slug;
        UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_siege_rec.siege_cmd_id AND status='active';
        INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
          (p_game_id,v_siege_rec.siege_player,v_tick,'combat','Siege Broken — '||v_castle_nm2,
           jsonb_build_object('combat_type','siege','result','siege_broken','role','attacker','castle_slug',v_siege_rec.castle_slug,'siege_cmd',v_siege_rec.siege_cmd_name,'siege_troops_before',v_siege_rec.siege_troops,'garr_troops_before',v_siege_rec.garr_troops)),
          (p_game_id,v_siege_rec.garr_player,v_tick,'combat','Siege Repelled — '||v_castle_nm2,
           jsonb_build_object('combat_type','siege','result','siege_broken','role','defender','castle_slug',v_siege_rec.castle_slug,'siege_cmd',v_siege_rec.siege_cmd_name,'siege_troops_before',v_siege_rec.siege_troops,'garr_troops_before',v_siege_rec.garr_troops,'garr_remaining',v_new_garr_t));
      ELSIF v_new_garr_t = 0 THEN
        -- Garrison wiped out: siege wins automatically
        UPDATE game_castles SET owner_player_id=v_siege_rec.siege_player, troops=v_new_siege_t, is_under_siege=FALSE, siege_started_at_tick=NULL WHERE game_id=p_game_id AND castle_slug=v_siege_rec.castle_slug;
        UPDATE commanders SET status='idle', troops=v_new_siege_t WHERE id=v_siege_rec.siege_cmd_id;
        UPDATE commanders SET status='dead', current_castle_slug=NULL WHERE game_id=p_game_id AND current_castle_slug=v_siege_rec.castle_slug AND owner_player_id=v_siege_rec.garr_player AND status='idle';
        v_combats := v_combats + 1;
        INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
          (p_game_id,v_siege_rec.siege_player,v_tick,'combat','Siege Victory — '||v_castle_nm2,
           jsonb_build_object('combat_type','siege','result','attacker_won','role','attacker','castle_slug',v_siege_rec.castle_slug,'siege_cmd',v_siege_rec.siege_cmd_name,'siege_troops_before',v_siege_rec.siege_troops,'garr_troops_before',v_siege_rec.garr_troops,'survivors',v_new_siege_t)),
          (p_game_id,v_siege_rec.garr_player,v_tick,'combat','Castle Lost — Siege — '||v_castle_nm2,
           jsonb_build_object('combat_type','siege','result','attacker_won','role','defender','castle_slug',v_siege_rec.castle_slug,'siege_cmd',v_siege_rec.siege_cmd_name,'siege_troops_before',v_siege_rec.siege_troops,'garr_troops_before',v_siege_rec.garr_troops));
      ELSE
        -- Both sides still standing: just apply bleed
        UPDATE commanders SET troops=v_new_siege_t WHERE id=v_siege_rec.siege_cmd_id;
        UPDATE game_castles SET troops=v_new_garr_t WHERE game_id=p_game_id AND castle_slug=v_siege_rec.castle_slug;
      END IF;
    END LOOP;

    -- Army arrivals
    FOR v_movement IN
      SELECT cm.*, c.owner_player_id AS cmd_owner, c.level AS cmd_level
      FROM commander_movements cm
      JOIN commanders c ON c.id = cm.commander_id
      WHERE cm.game_id = p_game_id AND cm.arrives_at_tick = v_tick
    LOOP
      v_cmd_owner := v_movement.cmd_owner;
      v_cmd_level := v_movement.cmd_level;

      SELECT * INTO v_dest_gc FROM game_castles WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;

      -- Is there already a siege commander at destination?
      SELECT c.* INTO v_siege_at_dest
      FROM commanders c
      WHERE c.game_id=p_game_id AND c.current_castle_slug=v_movement.to_castle_slug AND c.status='sieging'
      ORDER BY c.troops DESC LIMIT 1;

      SELECT cr.waypoints->cr.current_idx->>'action', (cr.waypoints->cr.current_idx->>'amount')::INT
      INTO v_wp_action, v_wp_amount
      FROM commander_routes cr WHERE cr.commander_id=v_movement.commander_id AND cr.status='active';
      v_wp_action := COALESCE(v_wp_action, 'deposit_all');

      v_new_troops         := v_movement.troops;
      v_eff_troops         := v_movement.troops;
      v_should_face_castle := TRUE;

      IF v_dest_gc.owner_player_id = v_cmd_owner THEN
        -- OWN CASTLE
        IF v_dest_gc.is_under_siege AND v_siege_at_dest.id IS NOT NULL
           AND v_siege_at_dest.owner_player_id <> v_cmd_owner THEN
          -- Relief army: fight siege commander outside (no castle bonus)
          SELECT name INTO v_castle_nm2 FROM castles WHERE slug=v_movement.to_castle_slug;
          SELECT COALESCE(level,1) INTO v_outside_whisp_m FROM council_seats WHERE game_id=p_game_id AND player_id=v_cmd_owner AND seat='whisperers';
          SELECT COALESCE(level,1) INTO v_outside_whisp_s FROM council_seats WHERE game_id=p_game_id AND player_id=v_siege_at_dest.owner_player_id AND seat='whisperers';
          v_outside_init_m := CASE WHEN v_outside_whisp_m > v_outside_whisp_s THEN TRUE WHEN v_outside_whisp_s > v_outside_whisp_m THEN FALSE ELSE (RANDOM() < 0.5) END;
          SELECT COALESCE(level,1) INTO v_outside_hand_m FROM council_seats WHERE game_id=p_game_id AND player_id=v_cmd_owner AND seat='hand';
          SELECT COALESCE(level,1) INTO v_outside_hand_s FROM council_seats WHERE game_id=p_game_id AND player_id=v_siege_at_dest.owner_player_id AND seat='hand';
          v_outside_dmg_m := GREATEST(1, ROUND(v_outside_hand_m::NUMERIC*(1.0+v_movement.cmd_level*0.1))::INT);
          v_outside_dmg_s := GREATEST(1, ROUND(v_outside_hand_s::NUMERIC*(1.0+v_siege_at_dest.level*0.1))::INT);
          v_outside_r_m   := CEIL(v_movement.troops::NUMERIC      / v_outside_dmg_s)::INT;
          v_outside_r_s   := CEIL(v_siege_at_dest.troops::NUMERIC / v_outside_dmg_m)::INT;
          IF v_outside_init_m THEN
            IF v_outside_r_s <= v_outside_r_m THEN v_outside_winner:='relief'; v_outside_surv_m:=GREATEST(1,v_movement.troops-(v_outside_r_s-1)*v_outside_dmg_s); v_outside_surv_s:=0;
            ELSE v_outside_winner:='siege'; v_outside_surv_m:=0; v_outside_surv_s:=GREATEST(1,v_siege_at_dest.troops-v_outside_r_m*v_outside_dmg_m); END IF;
          ELSE
            IF v_outside_r_m <= v_outside_r_s THEN v_outside_winner:='siege'; v_outside_surv_s:=GREATEST(1,v_siege_at_dest.troops-(v_outside_r_m-1)*v_outside_dmg_m); v_outside_surv_m:=0;
            ELSE v_outside_winner:='relief'; v_outside_surv_s:=0; v_outside_surv_m:=GREATEST(1,v_movement.troops-v_outside_r_s*v_outside_dmg_s); END IF;
          END IF;
          IF v_outside_winner = 'relief' THEN
            UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_siege_at_dest.id;
            UPDATE game_castles SET is_under_siege=FALSE, siege_started_at_tick=NULL WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
            UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_siege_at_dest.id AND status='active';
            UPDATE game_castles SET troops=troops+v_outside_surv_m WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
            UPDATE commanders SET status='idle', current_castle_slug=v_movement.to_castle_slug, troops=0 WHERE id=v_movement.commander_id;
            INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
              (p_game_id,v_cmd_owner,v_tick,'combat','Relief Victory — '||v_castle_nm2,
               jsonb_build_object('combat_type','open_field','result','relief_won','castle_slug',v_movement.to_castle_slug,'relief_troops_before',v_movement.troops,'siege_troops_before',v_siege_at_dest.troops,'relief_survivors',v_outside_surv_m,'siege_survivors',0,'relief_dmg',v_outside_dmg_m,'siege_dmg',v_outside_dmg_s)),
              (p_game_id,v_siege_at_dest.owner_player_id,v_tick,'combat','Siege Broken — Relief — '||v_castle_nm2,
               jsonb_build_object('combat_type','open_field','result','relief_won','castle_slug',v_movement.to_castle_slug,'relief_troops_before',v_movement.troops,'siege_troops_before',v_siege_at_dest.troops,'relief_survivors',v_outside_surv_m,'siege_survivors',0,'relief_dmg',v_outside_dmg_m,'siege_dmg',v_outside_dmg_s));
            v_should_face_castle := FALSE;
          ELSE
            UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_movement.commander_id;
            UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_movement.commander_id AND status='active';
            UPDATE commanders SET troops=v_outside_surv_s WHERE id=v_siege_at_dest.id;
            INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
              (p_game_id,v_cmd_owner,v_tick,'combat','Relief Defeated — '||v_castle_nm2,
               jsonb_build_object('combat_type','open_field','result','siege_held','castle_slug',v_movement.to_castle_slug,'relief_troops_before',v_movement.troops,'siege_troops_before',v_siege_at_dest.troops,'relief_survivors',0,'siege_survivors',v_outside_surv_s,'relief_dmg',v_outside_dmg_m,'siege_dmg',v_outside_dmg_s)),
              (p_game_id,v_siege_at_dest.owner_player_id,v_tick,'combat','Relief Repelled — '||v_castle_nm2,
               jsonb_build_object('combat_type','open_field','result','siege_held','castle_slug',v_movement.to_castle_slug,'relief_troops_before',v_movement.troops,'siege_troops_before',v_siege_at_dest.troops,'relief_survivors',0,'siege_survivors',v_outside_surv_s,'relief_dmg',v_outside_dmg_m,'siege_dmg',v_outside_dmg_s));
            v_should_face_castle := FALSE;
          END IF;
        END IF;

        IF v_should_face_castle THEN
          SELECT c.level INTO v_cmd_level FROM commanders c WHERE c.game_id=p_game_id AND c.current_castle_slug=v_movement.to_castle_slug AND c.status='idle' ORDER BY c.level DESC LIMIT 1;
          IF v_wp_action = 'deposit_all' THEN
            UPDATE game_castles SET troops=troops+v_movement.troops WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug; v_new_troops := 0;
          ELSIF v_wp_action = 'collect_all' THEN
            v_new_troops := v_movement.troops + COALESCE(v_dest_gc.troops,0);
            UPDATE game_castles SET troops=0 WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
          ELSIF v_wp_action = 'collect' THEN
            v_action_val := LEAST(COALESCE(v_wp_amount,0), COALESCE(v_dest_gc.troops,0));
            v_new_troops := v_movement.troops + v_action_val;
            UPDATE game_castles SET troops=GREATEST(0,troops-v_action_val) WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
          ELSIF v_wp_action = 'deposit' THEN
            v_action_val := LEAST(COALESCE(v_wp_amount,0), v_movement.troops);
            v_new_troops := v_movement.troops - v_action_val;
            UPDATE game_castles SET troops=troops+v_action_val WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
          ELSIF v_wp_action = 'collect_all_but' THEN
            v_action_val := GREATEST(0, COALESCE(v_dest_gc.troops,0)-COALESCE(v_wp_amount,0));
            v_new_troops := v_movement.troops + v_action_val;
            UPDATE game_castles SET troops=GREATEST(0,troops-v_action_val) WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
          ELSIF v_wp_action = 'deposit_all_but' THEN
            v_action_val := GREATEST(0, v_movement.troops-COALESCE(v_wp_amount,0));
            v_new_troops := v_movement.troops - v_action_val;
            UPDATE game_castles SET troops=troops+v_action_val WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
          ELSIF v_wp_action = 'garrison' THEN
            IF COALESCE(v_dest_gc.troops,0) < COALESCE(v_wp_amount,0) THEN
              v_action_val := LEAST(COALESCE(v_wp_amount,0)-COALESCE(v_dest_gc.troops,0), v_movement.troops);
              UPDATE game_castles SET troops=troops+v_action_val WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
              v_new_troops := v_movement.troops - v_action_val;
            ELSIF COALESCE(v_dest_gc.troops,0) > COALESCE(v_wp_amount,0) THEN
              v_action_val := COALESCE(v_dest_gc.troops,0)-COALESCE(v_wp_amount,0);
              UPDATE game_castles SET troops=COALESCE(v_wp_amount,0) WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
              v_new_troops := v_movement.troops + v_action_val;
            END IF;
          END IF;
          UPDATE commanders SET status='idle', current_castle_slug=v_movement.to_castle_slug, troops=v_new_troops WHERE id=v_movement.commander_id;
        END IF;

      ELSIF v_dest_gc.owner_player_id IS NULL THEN
        -- NEUTRAL CASTLE
        UPDATE game_castles SET owner_player_id=v_cmd_owner WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
        IF v_wp_action = 'deposit_all' THEN
          UPDATE game_castles SET troops=v_movement.troops WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug; v_new_troops := 0;
        END IF;
        UPDATE commanders SET status='idle', current_castle_slug=v_movement.to_castle_slug, troops=v_new_troops WHERE id=v_movement.commander_id;

      ELSE
        -- ENEMY CASTLE
        IF v_dest_gc.is_under_siege AND v_siege_at_dest.id IS NOT NULL THEN
          IF v_siege_at_dest.owner_player_id = v_cmd_owner THEN
            -- Reinforce own siege: merge troops into siege commander
            SELECT name INTO v_castle_nm2 FROM castles WHERE slug=v_movement.to_castle_slug;
            UPDATE commanders SET troops=troops+v_movement.troops WHERE id=v_siege_at_dest.id;
            UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_movement.commander_id;
            UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_movement.commander_id AND status='active';
            INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
              (p_game_id,v_cmd_owner,v_tick,'combat','Siege Reinforced — '||v_castle_nm2,
               jsonb_build_object('castle_slug',v_movement.to_castle_slug,'reinforcements',v_movement.troops,'siege_strength',v_siege_at_dest.troops+v_movement.troops));
            v_should_face_castle := FALSE;
          ELSE
            -- Enemy's siege: fight siege commander outside, then optionally face castle
            SELECT name INTO v_castle_nm2 FROM castles WHERE slug=v_movement.to_castle_slug;
            SELECT COALESCE(level,1) INTO v_outside_whisp_m FROM council_seats WHERE game_id=p_game_id AND player_id=v_cmd_owner AND seat='whisperers';
            SELECT COALESCE(level,1) INTO v_outside_whisp_s FROM council_seats WHERE game_id=p_game_id AND player_id=v_siege_at_dest.owner_player_id AND seat='whisperers';
            v_outside_init_m := CASE WHEN v_outside_whisp_m > v_outside_whisp_s THEN TRUE WHEN v_outside_whisp_s > v_outside_whisp_m THEN FALSE ELSE (RANDOM() < 0.5) END;
            SELECT COALESCE(level,1) INTO v_outside_hand_m FROM council_seats WHERE game_id=p_game_id AND player_id=v_cmd_owner AND seat='hand';
            SELECT COALESCE(level,1) INTO v_outside_hand_s FROM council_seats WHERE game_id=p_game_id AND player_id=v_siege_at_dest.owner_player_id AND seat='hand';
            v_outside_dmg_m := GREATEST(1, ROUND(v_outside_hand_m::NUMERIC*(1.0+v_movement.cmd_level*0.1))::INT);
            v_outside_dmg_s := GREATEST(1, ROUND(v_outside_hand_s::NUMERIC*(1.0+v_siege_at_dest.level*0.1))::INT);
            v_outside_r_m   := CEIL(v_movement.troops::NUMERIC      / v_outside_dmg_s)::INT;
            v_outside_r_s   := CEIL(v_siege_at_dest.troops::NUMERIC / v_outside_dmg_m)::INT;
            IF v_outside_init_m THEN
              IF v_outside_r_s <= v_outside_r_m THEN v_outside_winner:='movement'; v_outside_surv_m:=GREATEST(1,v_movement.troops-(v_outside_r_s-1)*v_outside_dmg_s); v_outside_surv_s:=0;
              ELSE v_outside_winner:='siege'; v_outside_surv_m:=0; v_outside_surv_s:=GREATEST(1,v_siege_at_dest.troops-v_outside_r_m*v_outside_dmg_m); END IF;
            ELSE
              IF v_outside_r_m <= v_outside_r_s THEN v_outside_winner:='siege'; v_outside_surv_s:=GREATEST(1,v_siege_at_dest.troops-(v_outside_r_m-1)*v_outside_dmg_m); v_outside_surv_m:=0;
              ELSE v_outside_winner:='movement'; v_outside_surv_s:=0; v_outside_surv_m:=GREATEST(1,v_movement.troops-v_outside_r_s*v_outside_dmg_s); END IF;
            END IF;
            IF v_outside_winner = 'movement' THEN
              UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_siege_at_dest.id;
              UPDATE game_castles SET is_under_siege=FALSE, siege_started_at_tick=NULL WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
              UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_siege_at_dest.id AND status='active';
              v_eff_troops := v_outside_surv_m;
              INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
                (p_game_id,v_cmd_owner,v_tick,'combat','Siege Broken (Field) — '||v_castle_nm2,
                 jsonb_build_object('combat_type','open_field','result','broke_siege','castle_slug',v_movement.to_castle_slug,'relief_troops_before',v_movement.troops,'siege_troops_before',v_siege_at_dest.troops,'survivors',v_outside_surv_m,'relief_dmg',v_outside_dmg_m,'siege_dmg',v_outside_dmg_s)),
                (p_game_id,v_siege_at_dest.owner_player_id,v_tick,'combat','Driven Off — '||v_castle_nm2,
                 jsonb_build_object('combat_type','open_field','result','broke_siege','castle_slug',v_movement.to_castle_slug,'survivors',0,'relief_dmg',v_outside_dmg_m,'siege_dmg',v_outside_dmg_s)),
                (p_game_id,v_dest_gc.owner_player_id,v_tick,'combat','Siege Lifted — '||v_castle_nm2,
                 jsonb_build_object('combat_type','open_field','result','siege_lifted','castle_slug',v_movement.to_castle_slug,'by_player',v_cmd_owner));
              -- fall through to face castle with v_eff_troops
            ELSE
              UPDATE commanders SET status='dead', troops=0, current_castle_slug=NULL WHERE id=v_movement.commander_id;
              UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_movement.commander_id AND status='active';
              UPDATE commanders SET troops=v_outside_surv_s WHERE id=v_siege_at_dest.id;
              INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
                (p_game_id,v_cmd_owner,v_tick,'combat','Defeated Outside Walls — '||v_castle_nm2,
                 jsonb_build_object('combat_type','open_field','result','lost_outside','castle_slug',v_movement.to_castle_slug,'survivors',0,'relief_dmg',v_outside_dmg_m,'siege_dmg',v_outside_dmg_s)),
                (p_game_id,v_siege_at_dest.owner_player_id,v_tick,'combat','Repelled Interlopers — '||v_castle_nm2,
                 jsonb_build_object('combat_type','open_field','result','siege_defended','castle_slug',v_movement.to_castle_slug,'survivors',v_outside_surv_s,'relief_dmg',v_outside_dmg_m,'siege_dmg',v_outside_dmg_s));
              v_should_face_castle := FALSE;
            END IF;
          END IF;
        END IF;

        IF v_should_face_castle THEN
          IF v_movement.march_type = 'siege' THEN
            -- Begin siege
            UPDATE game_castles SET is_under_siege=TRUE, siege_started_at_tick=v_tick WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
            UPDATE commanders SET status='sieging', current_castle_slug=v_movement.to_castle_slug, troops=v_eff_troops WHERE id=v_movement.commander_id;
            SELECT name INTO v_castle_nm2 FROM castles WHERE slug=v_movement.to_castle_slug;
            INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
              (p_game_id,v_cmd_owner,v_tick,'combat','Siege Begun — '||v_castle_nm2,
               jsonb_build_object('combat_type','siege','result','siege_started','role','attacker','castle_slug',v_movement.to_castle_slug,'siege_troops',v_eff_troops,'garr_troops',COALESCE(v_dest_gc.troops,0))),
              (p_game_id,v_dest_gc.owner_player_id,v_tick,'combat','Siege Begun — '||v_castle_nm2,
               jsonb_build_object('combat_type','siege','result','siege_started','role','defender','castle_slug',v_movement.to_castle_slug,'siege_troops',v_eff_troops,'garr_troops',COALESCE(v_dest_gc.troops,0)));
            v_new_troops := v_eff_troops;
          ELSE
            -- Direct assault
            DECLARE
              v_atk_cmd_lv    INT;
              v_def_cmd_lv    INT;
              v_atk_hand_lv   INT;
              v_def_hand_lv   INT;
              v_atk_player    BIGINT := v_cmd_owner;
              v_def_player    BIGINT := v_dest_gc.owner_player_id;
              v_atk_cmd_name  TEXT;
              v_def_cmd_name  TEXT;
              v_def_troops_b  INT;
              v_def_troops_a  INT;
              v_atk_dmg       INT;
              v_def_dmg       INT;
              v_r_a           INT;
              v_r_d           INT;
              v_gold_loot     INT := 0;
              v_castle_name   TEXT;
              v_combat_result TEXT;
            BEGIN
              SELECT COALESCE(level,0), name INTO v_atk_cmd_lv, v_atk_cmd_name FROM commanders WHERE id=v_movement.commander_id;
              SELECT COALESCE(MAX(c.level),0) INTO v_def_cmd_lv FROM commanders c WHERE c.game_id=p_game_id AND c.current_castle_slug=v_movement.to_castle_slug AND c.status='idle';
              SELECT name INTO v_def_cmd_name FROM commanders WHERE game_id=p_game_id AND current_castle_slug=v_movement.to_castle_slug AND status='idle' ORDER BY level DESC LIMIT 1;
              SELECT COALESCE(level,1) INTO v_atk_hand_lv FROM council_seats WHERE game_id=p_game_id AND player_id=v_atk_player AND seat='hand';
              SELECT COALESCE(level,1) INTO v_def_hand_lv FROM council_seats WHERE game_id=p_game_id AND player_id=v_def_player AND seat='hand';
              v_def_troops_b := COALESCE(v_dest_gc.troops, 0);
              SELECT name INTO v_castle_name FROM castles WHERE slug=v_movement.to_castle_slug;
              -- Defender gets +1 Hand equivalent for castle bonus
              v_atk_dmg := GREATEST(1, ROUND(v_atk_hand_lv::NUMERIC*(1.0+v_atk_cmd_lv*0.1))::INT);
              v_def_dmg := GREATEST(1, ROUND((v_def_hand_lv+1)::NUMERIC*(1.0+COALESCE(v_def_cmd_lv,0)*0.1))::INT);
              v_r_a := CEIL(v_eff_troops::NUMERIC     / v_def_dmg)::INT;
              v_r_d := CEIL(v_dest_gc.troops::NUMERIC / v_atk_dmg)::INT;

              IF v_r_a <= v_r_d THEN
                v_combat_result := 'defender_held';
                v_def_troops_a  := GREATEST(1, v_dest_gc.troops-(v_r_a-1)*v_atk_dmg);
                v_new_troops    := 0;
                UPDATE game_castles SET troops=v_def_troops_a WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
                UPDATE commanders SET status='dead', current_castle_slug=NULL, experience=COALESCE(experience,0)+10 WHERE id=v_movement.commander_id;
                INSERT INTO commander_battles (game_id,commander_id,tick,result,castle_slug,troops_sent,troops_faced) VALUES (p_game_id,v_movement.commander_id,v_tick,'defeat',v_movement.to_castle_slug,v_eff_troops,v_def_troops_b);
                INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
                  (p_game_id,v_atk_player,v_tick,'combat','Repelled — '||v_castle_name,
                   jsonb_build_object('role','attacker','result','defender_held','castle_slug',v_movement.to_castle_slug,'attacker_player_id',v_atk_player,'defender_player_id',v_def_player,'attacker_name',v_atk_cmd_name,'attacker_cmd_level',v_atk_cmd_lv,'attacker_troops_before',v_eff_troops,'attacker_troops_after',0,'atk_dmg_per_round',v_atk_dmg,'def_dmg_per_round',v_def_dmg,'atk_hand_lv',v_atk_hand_lv,'def_hand_lv',v_def_hand_lv,'defender_cmd',COALESCE(v_def_cmd_name,'none'),'defender_cmd_level',v_def_cmd_lv,'defender_troops_before',v_def_troops_b,'defender_troops_after',v_def_troops_a,'gold_looted',0,'survivors',v_def_troops_a)),
                  (p_game_id,v_def_player,v_tick,'combat','Held — '||v_castle_name,
                   jsonb_build_object('role','defender','result','defender_held','castle_slug',v_movement.to_castle_slug,'attacker_player_id',v_atk_player,'defender_player_id',v_def_player,'attacker_name',v_atk_cmd_name,'attacker_cmd_level',v_atk_cmd_lv,'attacker_troops_before',v_eff_troops,'attacker_troops_after',0,'atk_dmg_per_round',v_atk_dmg,'def_dmg_per_round',v_def_dmg,'atk_hand_lv',v_atk_hand_lv,'def_hand_lv',v_def_hand_lv,'defender_cmd',COALESCE(v_def_cmd_name,'none'),'defender_cmd_level',v_def_cmd_lv,'defender_troops_before',v_def_troops_b,'defender_troops_after',v_def_troops_a,'gold_looted',0,'survivors',v_def_troops_a));
              ELSE
                v_combat_result := 'attacker_won';
                v_new_troops    := GREATEST(1, v_eff_troops-v_r_d*v_def_dmg);
                v_def_troops_a  := 0;
                v_gold_loot     := ROUND(COALESCE(v_dest_gc.effective_influence,10))::INT;
                UPDATE game_castles SET owner_player_id=v_atk_player, troops=v_new_troops WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
                UPDATE commanders SET status='dead', current_castle_slug=NULL WHERE game_id=p_game_id AND current_castle_slug=v_movement.to_castle_slug AND status='idle';
                UPDATE commanders SET status='idle', current_castle_slug=v_movement.to_castle_slug, troops=v_new_troops, experience=COALESCE(experience,0)+50 WHERE id=v_movement.commander_id;
                UPDATE game_players SET gold=gold+v_gold_loot WHERE id=v_atk_player;
                INSERT INTO commander_battles (game_id,commander_id,tick,result,castle_slug,troops_sent,troops_faced) VALUES (p_game_id,v_movement.commander_id,v_tick,'victory',v_movement.to_castle_slug,v_eff_troops,v_def_troops_b);
                INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
                  (p_game_id,v_atk_player,v_tick,'combat','Victory — '||v_castle_name,
                   jsonb_build_object('role','attacker','result','attacker_won','castle_slug',v_movement.to_castle_slug,'attacker_player_id',v_atk_player,'defender_player_id',v_def_player,'attacker_name',v_atk_cmd_name,'attacker_cmd_level',v_atk_cmd_lv,'attacker_troops_before',v_eff_troops,'attacker_troops_after',v_new_troops,'atk_dmg_per_round',v_atk_dmg,'def_dmg_per_round',v_def_dmg,'atk_hand_lv',v_atk_hand_lv,'def_hand_lv',v_def_hand_lv,'defender_cmd',COALESCE(v_def_cmd_name,'none'),'defender_cmd_level',v_def_cmd_lv,'defender_troops_before',v_def_troops_b,'defender_troops_after',0,'gold_looted',v_gold_loot,'survivors',v_new_troops)),
                  (p_game_id,v_def_player,v_tick,'combat','Defeat — '||v_castle_name,
                   jsonb_build_object('role','defender','result','attacker_won','castle_slug',v_movement.to_castle_slug,'attacker_player_id',v_atk_player,'defender_player_id',v_def_player,'attacker_name',v_atk_cmd_name,'attacker_cmd_level',v_atk_cmd_lv,'attacker_troops_before',v_eff_troops,'attacker_troops_after',v_new_troops,'atk_dmg_per_round',v_atk_dmg,'def_dmg_per_round',v_def_dmg,'atk_hand_lv',v_atk_hand_lv,'def_hand_lv',v_def_hand_lv,'defender_cmd',COALESCE(v_def_cmd_name,'none'),'defender_cmd_level',v_def_cmd_lv,'defender_troops_before',v_def_troops_b,'defender_troops_after',0,'gold_looted',v_gold_loot,'survivors',v_new_troops));
              END IF;

              v_combats := v_combats + 1;

              FOR v_obs_player IN
                SELECT gp.id FROM game_players gp
                WHERE gp.game_id=p_game_id AND gp.eliminated_at_tick IS NULL AND gp.id NOT IN (v_atk_player, v_def_player)
              LOOP
                SELECT COALESCE(level,1) INTO v_mow_lv FROM council_seats WHERE game_id=p_game_id AND player_id=v_obs_player.id AND seat='whisperers';
                v_catch_rate := LEAST(0.90, 0.05+v_mow_lv*0.15);
                IF RANDOM() < v_catch_rate THEN
                  v_whisper_conf := LEAST(95, 30+v_mow_lv*10);
                  INSERT INTO whispers (game_id,player_id,tick,category,confidence,body)
                  VALUES (p_game_id,v_obs_player.id,v_tick,'combat_nearby',v_whisper_conf,
                    jsonb_build_object('castle_slug',v_movement.to_castle_slug,'castle_name',v_castle_name,'attacker_player_id',v_atk_player::TEXT,'defender_player_id',v_def_player::TEXT,'result',v_combat_result,'mow_level',v_mow_lv))
                  RETURNING id INTO v_inserted_whisper_id;
                  v_new_whisper_ids := v_new_whisper_ids || v_inserted_whisper_id;
                END IF;
              END LOOP;
            END;
          END IF;
        END IF;
      END IF;

      DELETE FROM commander_movements WHERE id=v_movement.id;

      -- Route advancement
      DECLARE
        v_route2      RECORD;
        v_cmd_alive   BOOLEAN;
        v_nxt_idx     INT;
        v_nxt_slug    TEXT;
        v_nxt_action  TEXT;
        v_nxt_from_x  NUMERIC; v_nxt_from_y NUMERIC;
        v_nxt_to_x    NUMERIC; v_nxt_to_y   NUMERIC;
        v_nxt_dist    NUMERIC; v_nxt_ticks  INT;
        v_cur_delay   INT;
        v_rt_owner    BIGINT;
        v_rt_horses   INT;
        v_rt_speed    NUMERIC;
        v_from_road   BOOLEAN;
        v_to_road     BOOLEAN;
      BEGIN
        SELECT (status='idle') INTO v_cmd_alive FROM commanders WHERE id=v_movement.commander_id;
        IF v_cmd_alive THEN
          SELECT * INTO v_route2 FROM commander_routes WHERE commander_id=v_movement.commander_id AND status='active';
          IF FOUND THEN
            SELECT owner_player_id INTO v_rt_owner FROM commanders WHERE id=v_movement.commander_id;
            SELECT COALESCE(level,1) INTO v_rt_horses FROM council_seats WHERE game_id=p_game_id AND player_id=v_rt_owner AND seat='horses';
            v_rt_speed  := COALESCE(v_game.commander_speed_mult,1.0)*17.5;
            v_cur_delay := GREATEST(0, COALESCE((v_route2.waypoints->v_route2.current_idx->>'delay')::INT,0));
            v_nxt_idx   := v_route2.current_idx + 1;

            IF v_nxt_idx < jsonb_array_length(v_route2.waypoints) THEN
              v_nxt_slug   := v_route2.waypoints->v_nxt_idx->>'castle_slug';
              v_nxt_action := COALESCE(v_route2.waypoints->v_nxt_idx->>'action', 'pass');
              SELECT COALESCE(has_kings_road,FALSE) INTO v_from_road FROM game_castles WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
              SELECT COALESCE(has_kings_road,FALSE) INTO v_to_road   FROM game_castles WHERE game_id=p_game_id AND castle_slug=v_nxt_slug;
              IF v_from_road AND v_to_road THEN v_rt_speed := v_rt_speed*SQRT(v_rt_horses::NUMERIC+3.0); END IF;
              SELECT c.map_x,c.map_y INTO v_nxt_from_x,v_nxt_from_y FROM castles c WHERE c.slug=v_movement.to_castle_slug;
              SELECT c.map_x,c.map_y INTO v_nxt_to_x,v_nxt_to_y     FROM castles c WHERE c.slug=v_nxt_slug;
              v_nxt_dist  := SQRT(POWER((v_nxt_to_x-v_nxt_from_x)*672.0,2)+POWER((v_nxt_to_y-v_nxt_from_y)*1560.0,2));
              v_nxt_ticks := GREATEST(1, CEIL(v_nxt_dist/v_rt_speed))::INT;
              UPDATE commander_routes SET current_idx=v_nxt_idx WHERE id=v_route2.id;
              UPDATE commanders SET status='moving', current_castle_slug=NULL WHERE id=v_movement.commander_id;
              INSERT INTO commander_movements (commander_id,game_id,from_castle_slug,to_castle_slug,departed_at_tick,arrives_at_tick,troops,march_type)
              VALUES (v_movement.commander_id,p_game_id,v_movement.to_castle_slug,v_nxt_slug,v_tick+v_cur_delay,v_tick+v_cur_delay+v_nxt_ticks,v_new_troops,
                CASE WHEN v_nxt_action = 'siege' THEN 'siege' ELSE 'assault' END);

            ELSIF v_route2.is_loop THEN
              v_nxt_slug   := v_route2.waypoints->0->>'castle_slug';
              v_nxt_action := COALESCE(v_route2.waypoints->0->>'action', 'pass');
              SELECT COALESCE(has_kings_road,FALSE) INTO v_from_road FROM game_castles WHERE game_id=p_game_id AND castle_slug=v_movement.to_castle_slug;
              SELECT COALESCE(has_kings_road,FALSE) INTO v_to_road   FROM game_castles WHERE game_id=p_game_id AND castle_slug=v_nxt_slug;
              IF v_from_road AND v_to_road THEN v_rt_speed := v_rt_speed*SQRT(v_rt_horses::NUMERIC+3.0); END IF;
              SELECT c.map_x,c.map_y INTO v_nxt_from_x,v_nxt_from_y FROM castles c WHERE c.slug=v_movement.to_castle_slug;
              SELECT c.map_x,c.map_y INTO v_nxt_to_x,v_nxt_to_y     FROM castles c WHERE c.slug=v_nxt_slug;
              v_nxt_dist  := SQRT(POWER((v_nxt_to_x-v_nxt_from_x)*672.0,2)+POWER((v_nxt_to_y-v_nxt_from_y)*1560.0,2));
              v_nxt_ticks := GREATEST(1, CEIL(v_nxt_dist/v_rt_speed))::INT;
              UPDATE commander_routes SET current_idx=0 WHERE id=v_route2.id;
              UPDATE commanders SET status='moving', current_castle_slug=NULL WHERE id=v_movement.commander_id;
              INSERT INTO commander_movements (commander_id,game_id,from_castle_slug,to_castle_slug,departed_at_tick,arrives_at_tick,troops,march_type)
              VALUES (v_movement.commander_id,p_game_id,v_movement.to_castle_slug,v_nxt_slug,v_tick+v_cur_delay,v_tick+v_cur_delay+v_nxt_ticks,v_new_troops,
                CASE WHEN v_nxt_action = 'siege' THEN 'siege' ELSE 'assault' END);
            ELSE
              UPDATE commander_routes SET status='completed' WHERE id=v_route2.id;
            END IF;
          END IF;
        ELSE
          UPDATE commander_routes SET status='cancelled' WHERE commander_id=v_movement.commander_id AND status='active';
        END IF;
      END;
    END LOOP;

    -- Production cycle (fires every v_cycle_len ticks)
    IF v_tick % v_cycle_len = 0 THEN
      v_cycles_fired := v_cycles_fired + 1;

      -- Infrastructure damage to castles under siege (50% gold, 35% industry, 15% prestige)
      FOR v_siege_rec IN
        SELECT gc.castle_slug, gc.owner_player_id AS garr_player, gc.gold_level, gc.industry_level, gc.prestige_level
        FROM game_castles gc WHERE gc.game_id=p_game_id AND gc.is_under_siege=TRUE
      LOOP
        SELECT name INTO v_castle_nm2 FROM castles WHERE slug=v_siege_rec.castle_slug;
        v_infra_roll := RANDOM();
        IF v_infra_roll < 0.50 AND v_siege_rec.gold_level > 0 THEN
          UPDATE game_castles SET gold_level=GREATEST(0,gold_level-1) WHERE game_id=p_game_id AND castle_slug=v_siege_rec.castle_slug;
          INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES (p_game_id,v_siege_rec.garr_player,v_tick,'combat','Siege Damage — '||v_castle_nm2,jsonb_build_object('combat_type','siege','result','infra_damage','role','defender','castle_slug',v_siege_rec.castle_slug,'infra','Treasury'));
        ELSIF v_infra_roll < 0.85 AND v_siege_rec.industry_level > 0 THEN
          UPDATE game_castles SET industry_level=GREATEST(0,industry_level-1) WHERE game_id=p_game_id AND castle_slug=v_siege_rec.castle_slug;
          INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES (p_game_id,v_siege_rec.garr_player,v_tick,'combat','Siege Damage — '||v_castle_nm2,jsonb_build_object('combat_type','siege','result','infra_damage','role','defender','castle_slug',v_siege_rec.castle_slug,'infra','Recruitment'));
        ELSIF v_siege_rec.prestige_level > 0 THEN
          UPDATE game_castles SET prestige_level=GREATEST(0,prestige_level-1) WHERE game_id=p_game_id AND castle_slug=v_siege_rec.castle_slug;
          INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES (p_game_id,v_siege_rec.garr_player,v_tick,'combat','Siege Damage — '||v_castle_nm2,jsonb_build_object('combat_type','siege','result','infra_damage','role','defender','castle_slug',v_siege_rec.castle_slug,'infra','Prestige'));
        END IF;
      END LOOP;

      -- Gold production + Grand Maester XP + council research
      FOR v_player IN SELECT gp.* FROM game_players gp WHERE gp.game_id=p_game_id AND gp.eliminated_at_tick IS NULL LOOP
        v_gm_rand_seat := NULL;
        SELECT COALESCE(level,1) INTO v_coin_lv FROM council_seats WHERE game_id=p_game_id AND player_id=v_player.id AND seat='coin';
        SELECT COALESCE(level,1) INTO v_gm_lv   FROM council_seats WHERE game_id=p_game_id AND player_id=v_player.id AND seat='grand_maester';
        SELECT COALESCE(level,1) INTO v_laws_lv  FROM council_seats WHERE game_id=p_game_id AND player_id=v_player.id AND seat='laws';
        UPDATE game_castles gc SET effective_influence=c.base_influence+(v_laws_lv*5) FROM castles c WHERE gc.game_id=p_game_id AND gc.owner_player_id=v_player.id AND c.slug=gc.castle_slug;
        SELECT COALESCE(SUM(gold_level),0)::INT, COALESCE(SUM(prestige_level),0)::INT, COUNT(*)::INT INTO v_total_gold_lv, v_total_prestige_lv, v_castles_owned FROM game_castles WHERE game_id=p_game_id AND owner_player_id=v_player.id;
        v_gold_earned     := v_total_gold_lv * (10+COALESCE(v_coin_lv,1)*2);
        v_prestige_earned := v_total_prestige_lv * v_cycle_len;
        UPDATE game_players SET gold=gold+v_gold_earned WHERE id=v_player.id;
        v_research_seat := v_player.research_seat;

        IF v_gm_lv > 0 THEN
          DECLARE
            v_gm_bonus  INT := 72*v_gm_lv;
            v_rand_seat TEXT; v_rand_lv INT; v_rand_cost INT; v_rand_prog INT; eligible TEXT[];
          BEGIN
            SELECT ARRAY_AGG(s ORDER BY RANDOM()) INTO eligible FROM UNNEST(ARRAY['hand','coin','lord_commander','whisperers','grand_maester','laws','horses']) AS s WHERE s <> COALESCE(v_research_seat,'');
            IF eligible IS NOT NULL AND array_length(eligible,1)>0 THEN
              v_rand_seat    := eligible[1];
              v_gm_rand_seat := v_rand_seat;
              SELECT level INTO v_rand_lv FROM council_seats WHERE game_id=p_game_id AND player_id=v_player.id AND seat=v_rand_seat;
              v_rand_lv := COALESCE(v_rand_lv,1); v_rand_cost := (144.0*v_rand_lv*v_council_mult)::INT;
              INSERT INTO council_seats (game_id,player_id,seat,level,research_progress) VALUES (p_game_id,v_player.id,v_rand_seat,1,v_gm_bonus)
              ON CONFLICT (game_id,player_id,seat) DO UPDATE SET research_progress=council_seats.research_progress+v_gm_bonus RETURNING research_progress INTO v_rand_prog;
              IF v_rand_prog >= v_rand_cost THEN
                UPDATE council_seats SET level=level+1, research_progress=0 WHERE game_id=p_game_id AND player_id=v_player.id AND seat=v_rand_seat;
                INSERT INTO player_inbox (game_id,player_id,tick,type,title,body) VALUES
                  (p_game_id,v_player.id,v_tick,'system','Council Advancement',
                   jsonb_build_object('gift_type','council_levelup','seat',v_rand_seat,'new_level',v_rand_lv+1,'source','grand_maester'));
              END IF;
            END IF;
          END;
        END IF;

        INSERT INTO player_inbox (game_id,player_id,tick,type,title,body)
        VALUES (p_game_id,v_player.id,v_tick,'production_cycle','Castellan Report',
          jsonb_build_object('gift_type','production_cycle','cycle_number',v_tick/v_cycle_len,'castles_owned',v_castles_owned,'gold_level',v_total_gold_lv,'prestige_level',v_total_prestige_lv,'coin_level',v_coin_lv,'gold_earned',v_gold_earned,'prestige_earned',v_prestige_earned,'gm_rand_seat',v_gm_rand_seat));
      END LOOP;
    END IF;

    PERFORM process_ai_decisions(p_game_id, v_tick);

    -- Commander level-ups
    UPDATE commanders SET level=level+1, experience=experience-(level*100) WHERE game_id=p_game_id AND status<>'dead' AND experience>=(level*100) AND level<10;

    -- Elimination check
    UPDATE game_players gp SET eliminated_at_tick=v_tick WHERE gp.game_id=p_game_id AND gp.eliminated_at_tick IS NULL AND NOT EXISTS (SELECT 1 FROM game_castles gc WHERE gc.game_id=p_game_id AND gc.owner_player_id=gp.id);

    -- Whisper generation
    FOR v_obs_player IN SELECT gp.id FROM game_players gp WHERE gp.game_id=p_game_id AND gp.eliminated_at_tick IS NULL LOOP
      SELECT COALESCE(level,1) INTO v_mow_lv FROM council_seats WHERE game_id=p_game_id AND player_id=v_obs_player.id AND seat='whisperers';
      v_mow_lv := COALESCE(v_mow_lv,1);
      v_whisper_interval := GREATEST(2, 8-v_mow_lv);
      IF v_tick % v_whisper_interval = 0 THEN
        v_whisper_conf := LEAST(95, 30+v_mow_lv*10);
        INSERT INTO whispers (game_id,player_id,tick,category,confidence,body)
        VALUES (p_game_id,v_obs_player.id,v_tick,'general_briefing',v_whisper_conf,jsonb_build_object('mow_level',v_mow_lv,'current_tick',v_tick))
        RETURNING id INTO v_inserted_whisper_id;
        v_new_whisper_ids := v_new_whisper_ids || v_inserted_whisper_id;
      END IF;
    END LOOP;
  END LOOP;

  UPDATE games SET current_tick=current_tick+v_pending, last_tick_processed_at=v_now WHERE id=p_game_id;

  -- Turn-based: reset submissions and advance deadline after tick fires
  IF v_game.tick_speed = 'turn_based' AND v_pending > 0 THEN
    UPDATE game_players SET turn_submitted = FALSE, turn_submitted_at = NULL
    WHERE game_id = p_game_id;
    UPDATE games
    SET current_turn_ends_at = v_now + (COALESCE(v_game.turn_timeout_minutes, 1440) * INTERVAL '1 minute')
    WHERE id = p_game_id;
  END IF;

  RETURN jsonb_build_object('pending_ticks',v_pending,'cycles_fired',v_cycles_fired,'combats',v_combats,'new_whisper_ids',v_new_whisper_ids);
END;
$function$

-- ============================================================================
-- propose_alliance(p_game_id bigint, p_target_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.propose_alliance(p_game_id bigint, p_target_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me   RECORD;
  v_them RECORD;
  v_pa   BIGINT; v_pb BIGINT;
  v_tick INT;
BEGIN
  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;
  IF v_me.id = p_target_player_id THEN RETURN jsonb_build_object('ok',false,'error','Cannot propose to yourself'); END IF;

  SELECT * INTO v_them FROM game_players WHERE id = p_target_player_id AND game_id = p_game_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Target not in game'); END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  SELECT pa, pb INTO v_pa, v_pb FROM _diplomacy_pair(v_me.id, p_target_player_id);

  INSERT INTO diplomacy(game_id, player_a_id, player_b_id, status, proposed_by_player_id, updated_at)
  VALUES (p_game_id, v_pa, v_pb, 'proposed', v_me.id, NOW())
  ON CONFLICT (game_id, player_a_id, player_b_id) DO UPDATE
    SET status = 'proposed', proposed_by_player_id = v_me.id,
        broken_at_tick = NULL, broken_by_player_id = NULL, grace_ends_at_tick = NULL,
        updated_at = NOW()
  WHERE diplomacy.status IN ('neutral','enemy');

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','Proposal already pending or alliance already active');
  END IF;

  -- Raven to target's Rookery
  INSERT INTO player_inbox(game_id, player_id, tick, type, title, body) VALUES (
    p_game_id, p_target_player_id, v_tick, 'diplomacy',
    'Alliance proposed by House ' || v_me.house_slug,
    jsonb_build_object('event','alliance_proposed','from_player_id',v_me.id,'from_house',v_me.house_slug)
  );

  RETURN jsonb_build_object('ok',true);
END;
$function$

-- ============================================================================
-- randomize_whisper_confidence()
-- ============================================================================
CREATE OR REPLACE FUNCTION public.randomize_whisper_confidence()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_variance INT;
BEGIN
  v_variance := CASE NEW.category
    WHEN 'combat_nearby'    THEN 15
    WHEN 'general_briefing' THEN 25
    ELSE 20
  END;
  NEW.confidence := LEAST(95, GREATEST(10,
    NEW.confidence + FLOOR(RANDOM() * (v_variance * 2 + 1) - v_variance)::INT
  ));
  RETURN NEW;
END;
$function$

-- ============================================================================
-- record_castle_capture_event()
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_castle_capture_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$

-- ============================================================================
-- record_intel_snapshot(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_intel_snapshot(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_tick   INT;
  v_count  INT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM game_players WHERE game_id = p_game_id AND user_id = v_caller
  ) THEN RAISE EXCEPTION 'Not a player in game %', p_game_id; END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;

  INSERT INTO intel_snapshots (
    game_id, player_id, tick,
    castles, troops, commanders,
    gold_level, industry_level, prestige_level,
    hand_level, coin_level, lord_commander_level,
    whisperers_level, grand_maester_level, laws_level
  )
  SELECT
    p_game_id, gp.id, v_tick,
    -- Castles
    (SELECT COUNT(*)::INT FROM game_castles
     WHERE game_id = p_game_id AND owner_player_id = gp.id),
    -- Troops (garrisoned + with commanders)
    COALESCE(
      (SELECT SUM(troops)::INT FROM game_castles
       WHERE game_id = p_game_id AND owner_player_id = gp.id), 0) +
    COALESCE(
      (SELECT SUM(cm.troops)::INT FROM commander_movements cm
       JOIN commanders c ON c.id = cm.commander_id
       WHERE cm.game_id = p_game_id AND c.owner_player_id = gp.id), 0),
    -- Commanders alive
    (SELECT COUNT(*)::INT FROM commanders
     WHERE game_id = p_game_id AND owner_player_id = gp.id AND status != 'dead'),
    -- Infrastructure totals
    COALESCE((SELECT SUM(gold_level)::INT FROM game_castles
              WHERE game_id = p_game_id AND owner_player_id = gp.id), 0),
    COALESCE((SELECT SUM(industry_level)::INT FROM game_castles
              WHERE game_id = p_game_id AND owner_player_id = gp.id), 0),
    COALESCE((SELECT SUM(prestige_level)::INT FROM game_castles
              WHERE game_id = p_game_id AND owner_player_id = gp.id), 0),
    -- Council seat levels
    COALESCE((SELECT level FROM council_seats WHERE game_id = p_game_id AND player_id = gp.id AND seat = 'hand'), 0),
    COALESCE((SELECT level FROM council_seats WHERE game_id = p_game_id AND player_id = gp.id AND seat = 'coin'), 0),
    COALESCE((SELECT level FROM council_seats WHERE game_id = p_game_id AND player_id = gp.id AND seat = 'lord_commander'), 0),
    COALESCE((SELECT level FROM council_seats WHERE game_id = p_game_id AND player_id = gp.id AND seat = 'whisperers'), 0),
    COALESCE((SELECT level FROM council_seats WHERE game_id = p_game_id AND player_id = gp.id AND seat = 'grand_maester'), 0),
    COALESCE((SELECT level FROM council_seats WHERE game_id = p_game_id AND player_id = gp.id AND seat = 'laws'), 0)
  FROM game_players gp
  WHERE gp.game_id = p_game_id
  ON CONFLICT (game_id, player_id, tick) DO UPDATE SET
    castles              = EXCLUDED.castles,
    troops               = EXCLUDED.troops,
    commanders           = EXCLUDED.commanders,
    gold_level           = EXCLUDED.gold_level,
    industry_level       = EXCLUDED.industry_level,
    prestige_level       = EXCLUDED.prestige_level,
    hand_level           = EXCLUDED.hand_level,
    coin_level           = EXCLUDED.coin_level,
    lord_commander_level = EXCLUDED.lord_commander_level,
    whisperers_level     = EXCLUDED.whisperers_level,
    grand_maester_level  = EXCLUDED.grand_maester_level,
    laws_level           = EXCLUDED.laws_level;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'tick', v_tick, 'snapshots_written', v_count);
END;
$function$

-- ============================================================================
-- recruit_commander(p_game_id bigint, p_castle_slug text, p_name text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.recruit_commander(p_game_id bigint, p_castle_slug text, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller    UUID;
  v_player    RECORD;
  v_castle    RECORD;
  v_game      RECORD;
  v_cost      INT := 100;
  v_clean     TEXT;
  v_is_named  BOOLEAN;
  v_new_id    BIGINT;
BEGIN
  v_caller := auth.uid();

  SELECT * INTO v_player
  FROM game_players
  WHERE game_id = p_game_id AND user_id = v_caller
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'You are not a player in this game';
  END IF;

  SELECT * INTO v_castle
  FROM game_castles
  WHERE game_id = p_game_id AND castle_slug = p_castle_slug;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Castle not found in this game';
  END IF;
  IF v_castle.owner_player_id IS DISTINCT FROM v_player.id THEN
    RAISE EXCEPTION 'You do not own that castle';
  END IF;

  v_clean := TRIM(COALESCE(p_name, ''));
  IF LENGTH(v_clean) < 2 THEN
    RAISE EXCEPTION 'Commander name must be at least 2 characters';
  END IF;
  IF LENGTH(v_clean) > 60 THEN
    RAISE EXCEPTION 'Commander name too long (max 60 characters)';
  END IF;

  IF v_player.gold < v_cost THEN
    RAISE EXCEPTION 'Not enough gold (need %, have %)', v_cost, v_player.gold;
  END IF;

  -- Was this name pulled from the lore-canonical pool for this house,
  -- and is it still available (not already used in this game)?
  SELECT EXISTS (
    SELECT 1 FROM commander_pool cp
    WHERE cp.house_slug = v_player.house_slug
      AND cp.name = v_clean
      AND NOT EXISTS (
        SELECT 1 FROM commanders c
        WHERE c.game_id = p_game_id
          AND c.owner_player_id = v_player.id
          AND c.name = cp.name
      )
  ) INTO v_is_named;

  UPDATE game_players SET gold = gold - v_cost WHERE id = v_player.id;

  INSERT INTO commanders (
    game_id, owner_player_id, name, is_named, level, experience,
    current_castle_slug, troops, status
  ) VALUES (
    p_game_id, v_player.id, v_clean, v_is_named, 1, 0,
    p_castle_slug, 0, 'idle'
  )
  RETURNING id INTO v_new_id;

  SELECT current_tick INTO v_game FROM games WHERE id = p_game_id;
  INSERT INTO game_events (game_id, tick, event_type, player_id, data)
  VALUES (
    p_game_id, v_game.current_tick, 'commander_recruited', v_player.id,
    jsonb_build_object(
      'commander_id', v_new_id,
      'name',         v_clean,
      'is_named',     v_is_named,
      'castle',       p_castle_slug,
      'cost',         v_cost
    )
  );

  RETURN jsonb_build_object(
    'success',      true,
    'commander_id', v_new_id,
    'name',         v_clean,
    'is_named',     v_is_named,
    'cost',         v_cost
  );
END;
$function$

-- ============================================================================
-- resolve_grace_periods(p_game_id bigint, p_current_tick integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.resolve_grace_periods(p_game_id bigint, p_current_tick integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE diplomacy SET status='neutral', updated_at=NOW()
  WHERE game_id=p_game_id AND status='grace_period' AND grace_ends_at_tick <= p_current_tick;
END;
$function$

-- ============================================================================
-- sally_out(p_game_id bigint, p_castle_slug text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.sally_out(p_game_id bigint, p_castle_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_player      RECORD;
  v_def_gc      RECORD;
  v_siege_cmd   RECORD;
  v_tick        INT;
  v_def_hand    INT;
  v_atk_hand    INT;
  v_def_cmd_lv  INT;
  v_atk_cmd_lv  INT;
  v_def_dmg     INT;
  v_atk_dmg     INT;
  v_r_def       INT;
  v_r_atk       INT;
  v_def_surv    INT;
  v_atk_surv    INT;
  v_def_name    TEXT;
  v_castle_name TEXT;
BEGIN
  SELECT gp.* INTO v_player FROM game_players gp
  WHERE gp.game_id = p_game_id AND gp.user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;

  SELECT gc.* INTO v_def_gc FROM game_castles gc
  WHERE gc.game_id = p_game_id AND gc.castle_slug = p_castle_slug
    AND gc.owner_player_id = v_player.id AND gc.is_under_siege = TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No active siege at this castle'; END IF;

  SELECT c.* INTO v_siege_cmd FROM commanders c
  WHERE c.game_id = p_game_id AND c.current_castle_slug = p_castle_slug AND c.status = 'sieging'
  ORDER BY c.troops DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'No besieging commander'; END IF;

  SELECT name INTO v_castle_name FROM castles WHERE slug = p_castle_slug;

  SELECT COALESCE(level, 1) INTO v_def_hand FROM council_seats
    WHERE game_id = p_game_id AND player_id = v_player.id AND seat = 'hand';
  SELECT COALESCE(level, 1) INTO v_atk_hand FROM council_seats
    WHERE game_id = p_game_id AND player_id = v_siege_cmd.owner_player_id AND seat = 'hand';

  SELECT COALESCE(MAX(level), 0) INTO v_def_cmd_lv FROM commanders
    WHERE game_id = p_game_id AND current_castle_slug = p_castle_slug
      AND status = 'idle' AND owner_player_id = v_player.id;
  v_atk_cmd_lv := v_siege_cmd.level;

  -- Defender fires first with +0.5 Hand (sallying bonus)
  v_def_dmg := GREATEST(1, ROUND((v_def_hand::NUMERIC + 0.5) * (1.0 + v_def_cmd_lv * 0.1))::INT);
  v_atk_dmg := GREATEST(1, ROUND(v_atk_hand::NUMERIC         * (1.0 + v_atk_cmd_lv * 0.1))::INT);

  v_r_def := CEIL(v_def_gc.troops::NUMERIC   / v_atk_dmg)::INT;
  v_r_atk := CEIL(v_siege_cmd.troops::NUMERIC / v_def_dmg)::INT;

  SELECT COALESCE(name,'Garrison') INTO v_def_name FROM commanders
    WHERE game_id = p_game_id AND current_castle_slug = p_castle_slug
      AND status = 'idle' AND owner_player_id = v_player.id ORDER BY level DESC LIMIT 1;

  IF v_r_atk <= v_r_def THEN
    -- Defender wins
    v_def_surv := GREATEST(1, v_def_gc.troops - (v_r_atk - 1) * v_atk_dmg);
    v_atk_surv := 0;
    UPDATE game_castles SET troops = v_def_surv, is_under_siege = FALSE, siege_started_at_tick = NULL
      WHERE game_id = p_game_id AND castle_slug = p_castle_slug;
    UPDATE commanders SET status = 'dead', troops = 0, current_castle_slug = NULL
      WHERE id = v_siege_cmd.id;
    UPDATE commander_routes SET status = 'cancelled'
      WHERE commander_id = v_siege_cmd.id AND status = 'active';
    INSERT INTO player_inbox (game_id, player_id, tick, type, title, body) VALUES
      (p_game_id, v_player.id, v_tick, 'combat', 'Sally Out — Victory',
       jsonb_build_object('combat_type','sally','result','defender_won','role','defender',
         'castle_slug',p_castle_slug,'def_name',v_def_name,'atk_name',v_siege_cmd.name,
         'def_troops_before',v_def_gc.troops,'atk_troops_before',v_siege_cmd.troops,
         'def_troops_after',v_def_surv,'atk_troops_after',0,'def_dmg',v_def_dmg,'atk_dmg',v_atk_dmg)),
      (p_game_id, v_siege_cmd.owner_player_id, v_tick, 'combat', 'Sally Repelled',
       jsonb_build_object('combat_type','sally','result','defender_won','role','attacker',
         'castle_slug',p_castle_slug,'def_name',v_def_name,'atk_name',v_siege_cmd.name,
         'def_troops_before',v_def_gc.troops,'atk_troops_before',v_siege_cmd.troops,
         'def_troops_after',v_def_surv,'atk_troops_after',0,'def_dmg',v_def_dmg,'atk_dmg',v_atk_dmg));
  ELSE
    -- Besieger repels sally — garrison wiped, castle falls
    v_atk_surv := GREATEST(1, v_siege_cmd.troops - v_r_def * v_def_dmg);
    v_def_surv := 0;
    UPDATE game_castles SET
      owner_player_id = v_siege_cmd.owner_player_id, troops = v_atk_surv,
      is_under_siege = FALSE, siege_started_at_tick = NULL
    WHERE game_id = p_game_id AND castle_slug = p_castle_slug;
    UPDATE commanders SET status = 'idle', troops = v_atk_surv WHERE id = v_siege_cmd.id;
    UPDATE commanders SET status = 'dead', current_castle_slug = NULL
      WHERE game_id = p_game_id AND current_castle_slug = p_castle_slug
        AND owner_player_id = v_player.id AND status = 'idle';
    INSERT INTO player_inbox (game_id, player_id, tick, type, title, body) VALUES
      (p_game_id, v_player.id, v_tick, 'combat', 'Sally Out — Failed',
       jsonb_build_object('combat_type','sally','result','attacker_won','role','defender',
         'castle_slug',p_castle_slug,'def_name',v_def_name,'atk_name',v_siege_cmd.name,
         'def_troops_before',v_def_gc.troops,'atk_troops_before',v_siege_cmd.troops,
         'def_troops_after',0,'atk_troops_after',v_atk_surv,'def_dmg',v_def_dmg,'atk_dmg',v_atk_dmg)),
      (p_game_id, v_siege_cmd.owner_player_id, v_tick, 'combat', 'Castle Taken — Sally Repelled',
       jsonb_build_object('combat_type','sally','result','attacker_won','role','attacker',
         'castle_slug',p_castle_slug,'def_name',v_def_name,'atk_name',v_siege_cmd.name,
         'def_troops_before',v_def_gc.troops,'atk_troops_before',v_siege_cmd.troops,
         'def_troops_after',0,'atk_troops_after',v_atk_surv,'def_dmg',v_def_dmg,'atk_dmg',v_atk_dmg));
  END IF;

  RETURN jsonb_build_object(
    'result',        CASE WHEN v_def_surv > 0 THEN 'defender_won' ELSE 'attacker_won' END,
    'def_survivors', v_def_surv,
    'atk_survivors', v_atk_surv
  );
END;
$function$

-- ============================================================================
-- send_chat_message(p_game_id bigint, p_player_id bigint, p_message text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_chat_message(p_game_id bigint, p_player_id bigint, p_message text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tick integer;
BEGIN
  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;
  -- Verify caller owns this player slot
  IF NOT EXISTS (
    SELECT 1 FROM game_players WHERE id = p_player_id AND user_id = auth.uid()
  ) THEN RAISE EXCEPTION 'not your player'; END IF;
  INSERT INTO game_chat(game_id, player_id, message, tick)
  VALUES (p_game_id, p_player_id, p_message, COALESCE(v_tick, 0));
END;
$function$

-- ============================================================================
-- send_commander(p_commander_id bigint, p_game_id bigint, p_to_castle text, p_troops integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_commander(p_commander_id bigint, p_game_id bigint, p_to_castle text, p_troops integer)
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

  -- Base speed: fixed 17.5 leagues/tick × game speed multiplier
  v_speed := COALESCE(v_game.commander_speed_mult, 1.0) * 17.5;

  -- Kings Road boost: both castles must have it
  v_from_road := COALESCE(v_from_cs.has_kings_road, FALSE);
  v_to_road   := COALESCE(v_to_cs.has_kings_road, FALSE);
  IF v_from_road AND v_to_road THEN
    v_speed := v_speed * SQRT(v_horses_lv::NUMERIC + 3.0);
  END IF;

  v_dist  := SQRT(
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
     departed_at_tick, arrives_at_tick, troops)
  VALUES
    (p_commander_id, p_game_id, v_cmd.current_castle_slug, p_to_castle,
     v_game.current_tick, v_game.current_tick + v_ticks, p_troops);

  RETURN jsonb_build_object('travel_ticks', v_ticks, 'troops', p_troops);
END;
$function$

-- ============================================================================
-- send_commander(p_commander_id bigint, p_game_id bigint, p_to_castle text, p_troops integer, p_march_type text DEFAULT 'assault'::text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_commander(p_commander_id bigint, p_game_id bigint, p_to_castle text, p_troops integer, p_march_type text DEFAULT 'assault'::text)
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

  -- Kings Road: flat 3× when both castles have the road
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
$function$

-- ============================================================================
-- send_council_knowledge(p_game_id bigint, p_target_player_id bigint, p_seat text, p_levels integer DEFAULT 1)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_council_knowledge(p_game_id bigint, p_target_player_id bigint, p_seat text, p_levels integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me        RECORD;
  v_them      RECORD;
  v_tick      INT;
  v_my_level  INT;
  v_tgt_level INT;
  v_max_level INT := 5;
  v_actual    INT;
  v_cost      INT;
  COST_PER    CONSTANT INT := 25;
BEGIN
  IF p_levels < 1 THEN RETURN jsonb_build_object('ok',false,'error','Levels must be >= 1'); END IF;
  SELECT * INTO v_me FROM game_players WHERE game_id=p_game_id AND user_id=auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;
  SELECT * INTO v_them FROM game_players WHERE id=p_target_player_id AND game_id=p_game_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Target not in game'); END IF;

  SELECT COALESCE(level,0) INTO v_my_level  FROM council_seats WHERE game_id=p_game_id AND player_id=v_me.id   AND seat=p_seat;
  SELECT COALESCE(level,0) INTO v_tgt_level FROM council_seats WHERE game_id=p_game_id AND player_id=p_target_player_id AND seat=p_seat;

  IF v_my_level = 0 THEN RETURN jsonb_build_object('ok',false,'error','You have no knowledge of ' || p_seat); END IF;

  -- Cap levels to transferable amount
  v_actual := LEAST(p_levels, v_my_level, v_max_level - v_tgt_level);
  IF v_actual <= 0 THEN RETURN jsonb_build_object('ok',false,'error','Target already at max level for ' || p_seat); END IF;

  v_cost := v_actual * COST_PER;
  IF v_me.gold < v_cost THEN
    RETURN jsonb_build_object('ok',false,'error','Need ' || v_cost || ' gold (have ' || v_me.gold || ')');
  END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id=p_game_id;
  UPDATE game_players SET gold = gold - v_cost WHERE id = v_me.id;

  -- Upsert council seat for target
  INSERT INTO council_seats(game_id, player_id, seat, level)
  VALUES (p_game_id, p_target_player_id, p_seat, v_actual)
  ON CONFLICT (game_id, player_id, seat) DO UPDATE
    SET level = LEAST(council_seats.level + v_actual, v_max_level);

  INSERT INTO player_inbox(game_id, player_id, tick, type, title, body) VALUES
    (p_game_id, v_me.id, v_tick, 'diplomacy',
     'Council knowledge sent to House ' || v_them.house_slug,
     jsonb_build_object('event','knowledge_sent','seat',p_seat,'levels',v_actual,'cost',v_cost,'to_house',v_them.house_slug)),
    (p_game_id, p_target_player_id, v_tick, 'diplomacy',
     'Council knowledge received from House ' || v_me.house_slug,
     jsonb_build_object('event','knowledge_received','seat',p_seat,'levels',v_actual,'from_house',v_me.house_slug));

  RETURN jsonb_build_object('ok',true,'levels_sent',v_actual,'cost',v_cost);
END;
$function$

-- ============================================================================
-- send_gold(p_game_id bigint, p_target_player_id bigint, p_amount integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_gold(p_game_id bigint, p_target_player_id bigint, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me   RECORD;
  v_them RECORD;
  v_tick INT;
BEGIN
  IF p_amount <= 0 THEN RETURN jsonb_build_object('ok',false,'error','Amount must be positive'); END IF;
  SELECT * INTO v_me FROM game_players WHERE game_id=p_game_id AND user_id=auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;
  IF v_me.gold < p_amount THEN RETURN jsonb_build_object('ok',false,'error','Insufficient gold'); END IF;
  SELECT * INTO v_them FROM game_players WHERE id=p_target_player_id AND game_id=p_game_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Target not in game'); END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id=p_game_id;
  UPDATE game_players SET gold = gold - p_amount WHERE id = v_me.id;
  UPDATE game_players SET gold = gold + p_amount WHERE id = p_target_player_id;

  INSERT INTO player_inbox(game_id, player_id, tick, type, title, body) VALUES
    (p_game_id, v_me.id,   v_tick, 'diplomacy', 'Gold sent to House ' || v_them.house_slug,
     jsonb_build_object('event','gold_sent','amount',p_amount,'to_house',v_them.house_slug,'to_player_id',p_target_player_id)),
    (p_game_id, p_target_player_id, v_tick, 'diplomacy', 'Gold received from House ' || v_me.house_slug,
     jsonb_build_object('event','gold_received','amount',p_amount,'from_house',v_me.house_slug,'from_player_id',v_me.id));

  RETURN jsonb_build_object('ok',true,'new_gold', v_me.gold - p_amount);
END;
$function$

-- ============================================================================
-- send_gold_to_player(p_game_id bigint, p_target_player_id bigint, p_amount integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_gold_to_player(p_game_id bigint, p_target_player_id bigint, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_me     RECORD;
  v_target RECORD;
  v_tick   INT;
BEGIN
  IF p_amount < 1 THEN RAISE EXCEPTION 'Must send at least 1 gold'; END IF;

  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = v_caller FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;
  IF v_me.id = p_target_player_id THEN RAISE EXCEPTION 'Cannot send gold to yourself'; END IF;
  IF v_me.gold < p_amount THEN RAISE EXCEPTION 'Not enough gold'; END IF;

  SELECT * INTO v_target FROM game_players WHERE id = p_target_player_id AND game_id = p_game_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Target player not found'; END IF;
  IF v_target.eliminated_at_tick IS NOT NULL THEN RAISE EXCEPTION 'Target has been eliminated'; END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;

  UPDATE game_players SET gold = gold - p_amount WHERE id = v_me.id;
  UPDATE game_players SET gold = gold + p_amount WHERE id = v_target.id;

  -- Notify recipient
  INSERT INTO player_inbox (game_id, player_id, tick, type, title, body) VALUES (
    p_game_id, v_target.id, v_tick, 'system',
    p_amount || ' gold received from ' || (SELECT name FROM houses WHERE slug = v_me.house_slug),
    jsonb_build_object('gift_type','gold','from_house',v_me.house_slug,'from_player_id',v_me.id,'amount',p_amount)
  );

  -- Ledger: you sent them gold → they owe you that amount
  INSERT INTO ledger (game_id, payer_player_id, receiver_player_id, amount, description, tick)
  VALUES (p_game_id, v_me.id, v_target.id, p_amount, 'Gold sent', v_tick);

  RETURN jsonb_build_object('success', true, 'amount', p_amount);
END;
$function$

-- ============================================================================
-- send_on_route(p_game_id bigint, p_commander_id bigint, p_troops integer, p_waypoints jsonb, p_is_loop boolean DEFAULT false)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_on_route(p_game_id bigint, p_commander_id bigint, p_troops integer, p_waypoints jsonb, p_is_loop boolean DEFAULT false)
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

  -- Speed: game multiplier × 17.5, flat 3× if both endpoints have Kings Road
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
$function$

-- ============================================================================
-- send_player_raven(p_game_id bigint, p_target_player_id bigint, p_message text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_player_raven(p_game_id bigint, p_target_player_id bigint, p_message text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_me     RECORD;
  v_target RECORD;
  v_clean  TEXT := TRIM(COALESCE(p_message, ''));
  v_house  TEXT;
BEGIN
  IF LENGTH(v_clean) < 1  THEN RAISE EXCEPTION 'Message cannot be empty'; END IF;
  IF LENGTH(v_clean) > 1000 THEN RAISE EXCEPTION 'Message too long (max 1000 characters)'; END IF;

  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;
  IF v_me.id = p_target_player_id THEN RAISE EXCEPTION 'Cannot raven yourself'; END IF;

  SELECT * INTO v_target FROM game_players WHERE id = p_target_player_id AND game_id = p_game_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Target player not found'; END IF;

  SELECT name INTO v_house FROM houses WHERE slug = v_me.house_slug;

  INSERT INTO player_inbox (game_id, player_id, tick, type, title, body)
  SELECT p_game_id, v_target.id, g.current_tick, 'raven',
    'Raven from ' || COALESCE(v_house, v_me.house_slug),
    jsonb_build_object(
      'from_house',      v_me.house_slug,
      'from_player_id',  v_me.id,
      'from_house_name', COALESCE(v_house, v_me.house_slug),
      'message',         v_clean
    )
  FROM games g WHERE g.id = p_game_id;

  RETURN jsonb_build_object('success', true);
END;
$function$

-- ============================================================================
-- send_thread_message(p_thread_id bigint, p_player_id bigint, p_message text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.send_thread_message(p_thread_id bigint, p_player_id bigint, p_message text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_game_id bigint;
  v_tick    integer;
BEGIN
  SELECT mt.game_id INTO v_game_id FROM message_threads mt WHERE mt.id = p_thread_id;
  SELECT current_tick INTO v_tick FROM games WHERE id = v_game_id;

  IF NOT EXISTS (
    SELECT 1 FROM game_players WHERE id = p_player_id AND user_id = auth.uid()
  ) THEN RAISE EXCEPTION 'not your player'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM thread_participants WHERE thread_id = p_thread_id AND player_id = p_player_id
  ) THEN RAISE EXCEPTION 'not a participant'; END IF;

  INSERT INTO thread_messages(thread_id, player_id, message, tick)
  VALUES (p_thread_id, p_player_id, p_message, COALESCE(v_tick, 0));
END;
$function$

-- ============================================================================
-- set_council_focus(p_game_id bigint, p_seat text, p_next_seat text DEFAULT NULL::text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.set_council_focus(p_game_id bigint, p_seat text, p_next_seat text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_player RECORD;
BEGIN
  SELECT gp.* INTO v_player FROM game_players gp
  WHERE gp.game_id = p_game_id AND gp.user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  IF p_seat IS NOT NULL AND p_seat NOT IN (
    'hand','coin','lord_commander','whisperers','grand_maester','laws','horses'
  ) THEN
    RAISE EXCEPTION 'Invalid council seat: %', p_seat;
  END IF;

  IF p_next_seat IS NOT NULL AND p_next_seat NOT IN (
    'hand','coin','lord_commander','whisperers','grand_maester','laws','horses'
  ) THEN
    RAISE EXCEPTION 'Invalid next seat: %', p_next_seat;
  END IF;

  UPDATE game_players SET
    research_seat      = p_seat,
    next_research_seat = p_next_seat
  WHERE id = v_player.id;

  RETURN jsonb_build_object('seat', p_seat, 'next_seat', p_next_seat);
END;
$function$

-- ============================================================================
-- set_diplomacy(p_game_id bigint, p_target_player_id bigint, p_status text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.set_diplomacy(p_game_id bigint, p_target_player_id bigint, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_me     RECORD;
  v_target RECORD;
  v_tick   INT;
BEGIN
  IF p_status NOT IN ('neutral','allied','war') THEN
    RAISE EXCEPTION 'Invalid status. Use: neutral, allied, war';
  END IF;

  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;
  IF v_me.id = p_target_player_id THEN RAISE EXCEPTION 'Cannot set diplomacy with yourself'; END IF;

  SELECT * INTO v_target FROM game_players WHERE id = p_target_player_id AND game_id = p_game_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Target player not found'; END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;

  -- Update (or insert) both directions
  INSERT INTO diplomacy (game_id, player_id, target_player_id, status, updated_at)
  VALUES (p_game_id, v_me.id,     v_target.id, p_status, NOW()),
         (p_game_id, v_target.id, v_me.id,     p_status, NOW())
  ON CONFLICT (game_id, player_id, target_player_id)
  DO UPDATE SET status = EXCLUDED.status, updated_at = NOW();

  -- Notify target
  INSERT INTO player_inbox (game_id, player_id, tick, type, title, body)
  VALUES (
    p_game_id, v_target.id, v_tick, 'system',
    CASE p_status
      WHEN 'allied' THEN (SELECT name FROM houses WHERE slug = v_me.house_slug) || ' has proposed a Formal Alliance'
      WHEN 'war'    THEN (SELECT name FROM houses WHERE slug = v_me.house_slug) || ' has declared WAR'
      ELSE                (SELECT name FROM houses WHERE slug = v_me.house_slug) || ' has ended the alliance'
    END,
    jsonb_build_object(
      'from_house', v_me.house_slug,
      'new_status', p_status,
      'gift_type',  'diplomacy'
    )
  );

  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$function$

-- ============================================================================
-- set_enemy(p_game_id bigint, p_target_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.set_enemy(p_game_id bigint, p_target_player_id bigint)
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
$function$

-- ============================================================================
-- set_neutral(p_game_id bigint, p_target_player_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.set_neutral(p_game_id bigint, p_target_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me  RECORD;
  v_pa  BIGINT;  v_pb BIGINT;
BEGIN
  SELECT * INTO v_me FROM game_players WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','Not in game'); END IF;
  SELECT pa, pb INTO v_pa, v_pb FROM _diplomacy_pair(v_me.id, p_target_player_id);

  UPDATE diplomacy SET status='neutral', updated_at=NOW()
  WHERE game_id=p_game_id AND player_a_id=v_pa AND player_b_id=v_pb;

  RETURN jsonb_build_object('ok',true);
END;
$function$

-- ============================================================================
-- set_research_seat(p_game_id bigint, p_seat text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.set_research_seat(p_game_id bigint, p_seat text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ SELECT set_council_focus(p_game_id, p_seat, NULL); $function$

-- ============================================================================
-- share_council_tech(p_game_id bigint, p_target_player_id bigint, p_seat text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.share_council_tech(p_game_id bigint, p_target_player_id bigint, p_seat text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_me     RECORD;
  v_target RECORD;
  v_my_seat  RECORD;
  v_tgt_seat RECORD;
  v_cost   INT;
  v_tick   INT;
BEGIN
  SELECT * INTO v_me     FROM game_players WHERE game_id = p_game_id AND user_id = v_caller FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;
  IF v_me.id = p_target_player_id THEN RAISE EXCEPTION 'Cannot share with yourself'; END IF;

  SELECT * INTO v_target FROM game_players WHERE id = p_target_player_id AND game_id = p_game_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Target player not found'; END IF;
  IF v_target.eliminated_at_tick IS NOT NULL THEN RAISE EXCEPTION 'Target has been eliminated'; END IF;

  SELECT * INTO v_my_seat  FROM council_seats WHERE game_id = p_game_id AND player_id = v_me.id     AND seat = p_seat;
  SELECT * INTO v_tgt_seat FROM council_seats WHERE game_id = p_game_id AND player_id = v_target.id AND seat = p_seat FOR UPDATE;

  IF NOT FOUND OR v_my_seat.level = 0 THEN RAISE EXCEPTION 'You have not trained this council seat'; END IF;
  IF v_tgt_seat.level >= v_my_seat.level THEN RAISE EXCEPTION 'Target already has this seat at your level or above'; END IF;

  v_cost := v_my_seat.level * 25;
  IF v_me.gold < v_cost THEN RAISE EXCEPTION 'Not enough gold (need %, have %)', v_cost, v_me.gold; END IF;

  SELECT current_tick INTO v_tick FROM games WHERE id = p_game_id;

  UPDATE game_players SET gold = gold - v_cost WHERE id = v_me.id;
  UPDATE council_seats SET level = v_my_seat.level WHERE game_id = p_game_id AND player_id = v_target.id AND seat = p_seat;

  -- Notify recipient
  INSERT INTO player_inbox (game_id, player_id, tick, type, title, body) VALUES (
    p_game_id, v_target.id, v_tick, 'system',
    'Council training received from ' || (SELECT name FROM houses WHERE slug = v_me.house_slug),
    jsonb_build_object('gift_type','council_tech','from_house',v_me.house_slug,'seat',p_seat,'new_level',v_my_seat.level,'cost',v_cost)
  );

  -- Ledger: you paid v_cost to give them value → they owe you v_cost
  INSERT INTO ledger (game_id, payer_player_id, receiver_player_id, amount, description, tick)
  VALUES (p_game_id, v_me.id, v_target.id, v_cost,
    'Council shared: ' || p_seat || ' (Lv' || v_my_seat.level || ')', v_tick);

  RETURN jsonb_build_object('success', true, 'seat', p_seat, 'new_level', v_my_seat.level, 'cost', v_cost);
END;
$function$

-- ============================================================================
-- start_game(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.start_game(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_game        RECORD;
  v_player      RECORD;
  v_starting    RECORD;
  v_house       TEXT;
  v_ai_count    INT := 0;
  v_player_cnt  INT;
  v_caller      UUID;
BEGIN
  v_caller := auth.uid();

  SELECT * INTO v_game FROM games WHERE id = p_game_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game % not found', p_game_id; END IF;
  IF v_game.status <> 'lobby' THEN RAISE EXCEPTION 'Game is not in lobby status (current: %)', v_game.status; END IF;
  IF v_game.created_by IS DISTINCT FROM v_caller THEN RAISE EXCEPTION 'Only the game creator may start the game'; END IF;

  SELECT COUNT(*) INTO v_player_cnt FROM game_players WHERE game_id = p_game_id;
  IF v_player_cnt < 1 THEN RAISE EXCEPTION 'Game has no players'; END IF;
  IF v_player_cnt < 2 AND NOT v_game.fill_with_ai THEN RAISE EXCEPTION 'Game needs at least 2 players (or enable AI fill)'; END IF;

  -- 1. Fill with AI
  IF v_game.fill_with_ai THEN
    FOR v_house IN
      SELECT h.slug FROM houses h
      WHERE h.slug NOT IN (SELECT house_slug FROM game_players WHERE game_id = p_game_id)
      ORDER BY h.slug
      LIMIT v_game.max_players - v_player_cnt
    LOOP
      INSERT INTO game_players (game_id, user_id, is_ai, ai_profile, house_slug, display_name)
      VALUES (p_game_id, NULL, TRUE, 'standard', v_house, 'AI ' || (SELECT name FROM houses WHERE slug = v_house));
      v_ai_count := v_ai_count + 1;
    END LOOP;
  END IF;

  -- 2. Starting gold
  UPDATE game_players SET gold = 100 WHERE game_id = p_game_id;

  -- 3. Initialize 188 castles
  INSERT INTO game_castles (game_id, castle_slug, owner_player_id, gold_level, industry_level, prestige_level, troops, base_influence, effective_influence)
  SELECT p_game_id, c.slug, NULL, 0, 0, 0, 0, c.base_influence, c.base_influence FROM castles c;

  -- 4. Assign starting castles
  FOR v_player IN SELECT * FROM game_players WHERE game_id = p_game_id LOOP
    FOR v_starting IN SELECT hsc.castle_slug, hsc.is_seat FROM house_starting_castles hsc WHERE hsc.house_slug = v_player.house_slug LOOP
      UPDATE game_castles SET
        owner_player_id     = v_player.id,
        gold_level          = CASE WHEN v_starting.is_seat THEN 10 ELSE 0 END,
        industry_level      = CASE WHEN v_starting.is_seat THEN 5  ELSE 0 END,
        prestige_level      = CASE WHEN v_starting.is_seat THEN 2  ELSE 0 END,
        troops              = 10,
        base_influence      = CASE WHEN v_starting.is_seat THEN 45 ELSE 25 END,
        effective_influence = CASE WHEN v_starting.is_seat THEN 45 ELSE 25 END
      WHERE game_id = p_game_id AND castle_slug = v_starting.castle_slug;
    END LOOP;
  END LOOP;

  -- 5. Head-of-house commanders
  INSERT INTO commanders (game_id, owner_player_id, name, is_named, level, experience, current_castle_slug, troops, status)
  SELECT p_game_id, gp.id, cp.name, TRUE, 5, 0, h.seat_castle_slug, 0, 'idle'
  FROM game_players gp
  JOIN houses h ON h.slug = gp.house_slug
  JOIN commander_pool cp ON cp.house_slug = gp.house_slug AND cp.is_head_of_house = TRUE
  WHERE gp.game_id = p_game_id;

  -- 6. All 7 council seats at level 1
  INSERT INTO council_seats (game_id, player_id, seat, level, research_progress)
  SELECT p_game_id, gp.id, s.seat, 1, 0
  FROM game_players gp
  CROSS JOIN (VALUES ('hand'),('coin'),('lord_commander'),('whisperers'),('grand_maester'),('laws'),('horses')) AS s(seat)
  WHERE gp.game_id = p_game_id;

  -- 7. Diplomacy
  INSERT INTO diplomacy (game_id, player_a_id, player_b_id, status)
  SELECT p_game_id, LEAST(p1.id, p2.id), GREATEST(p1.id, p2.id), 'neutral'
  FROM game_players p1 JOIN game_players p2 ON p1.game_id = p2.game_id AND p1.id < p2.id
  WHERE p1.game_id = p_game_id;

  -- 8. Log and activate
  INSERT INTO game_events (game_id, tick, event_type, data)
  VALUES (p_game_id, 0, 'game_started', jsonb_build_object('human_players', v_player_cnt, 'ai_players', v_ai_count, 'total_players', v_player_cnt + v_ai_count));

  UPDATE games SET status = 'active', started_at = NOW(), last_tick_processed_at = NOW() WHERE id = p_game_id;

  RETURN jsonb_build_object('success', true, 'game_id', p_game_id, 'human_players', v_player_cnt, 'ai_players', v_ai_count, 'total_players', v_player_cnt + v_ai_count);
END;
$function$

-- ============================================================================
-- submit_turn(p_game_id bigint)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.submit_turn(p_game_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_player_id BIGINT;
  v_all_in    BOOLEAN;
BEGIN
  SELECT id INTO v_player_id
  FROM game_players
  WHERE game_id = p_game_id AND user_id = auth.uid() AND eliminated_at_tick IS NULL;

  IF v_player_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not a player');
  END IF;

  UPDATE game_players
  SET turn_submitted = TRUE, turn_submitted_at = NOW()
  WHERE id = v_player_id;

  SELECT NOT EXISTS (
    SELECT 1 FROM game_players
    WHERE game_id = p_game_id
      AND eliminated_at_tick IS NULL
      AND NOT is_ai
      AND NOT turn_submitted
  ) INTO v_all_in;

  IF v_all_in THEN
    PERFORM process_ticks(p_game_id);
  END IF;

  RETURN jsonb_build_object('ok', true, 'all_submitted', v_all_in);
END;
$function$

-- ============================================================================
-- tick_all_games()
-- ============================================================================
CREATE OR REPLACE FUNCTION public.tick_all_games()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Simple rate-limit: only one caller can run at a time
  -- (process_ticks self-throttles anyway based on elapsed time)
  RETURN process_all_active_games();
END;
$function$

-- ============================================================================
-- transfer_troops(p_game_id bigint, p_commander_id bigint, p_amount integer)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.transfer_troops(p_game_id bigint, p_commander_id bigint, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_me   RECORD;
  v_cmd  RECORD;
  v_gc   RECORD;
  v_abs  INT := ABS(p_amount);
BEGIN
  IF p_amount = 0 THEN RETURN jsonb_build_object('ok', true, 'changed', 0); END IF;

  -- Caller must be in the game
  SELECT * INTO v_me FROM game_players
    WHERE game_id = p_game_id AND user_id = auth.uid();
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Not in game');
  END IF;

  -- Commander must be idle and owned by caller
  SELECT * INTO v_cmd FROM commanders
    WHERE id = p_commander_id
      AND game_id = p_game_id
      AND owner_player_id = v_me.id
      AND status = 'idle';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Commander not found, not idle, or not yours');
  END IF;

  -- Castle must be owned by caller
  SELECT * INTO v_gc FROM game_castles
    WHERE game_id = p_game_id
      AND castle_slug = v_cmd.current_castle_slug
      AND owner_player_id = v_me.id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Castle not found or not yours');
  END IF;

  IF p_amount > 0 THEN
    -- ── Garrison → Commander ──────────────────────────────────────
    IF v_gc.troops < v_abs THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Garrison only has ' || v_gc.troops || ' troops (need ' || v_abs || ')');
    END IF;
    UPDATE game_castles SET troops = troops - v_abs
      WHERE game_id = p_game_id AND castle_slug = v_cmd.current_castle_slug;
    UPDATE commanders   SET troops = troops + v_abs
      WHERE id = p_commander_id;
  ELSE
    -- ── Commander → Garrison ──────────────────────────────────────
    IF v_cmd.troops < v_abs THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Commander only has ' || v_cmd.troops || ' troops (need ' || v_abs || ')');
    END IF;
    UPDATE commanders   SET troops = troops - v_abs
      WHERE id = p_commander_id;
    UPDATE game_castles SET troops = troops + v_abs
      WHERE game_id = p_game_id AND castle_slug = v_cmd.current_castle_slug;
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'garrison_troops', v_gc.troops  - (CASE WHEN p_amount > 0 THEN v_abs ELSE -v_abs END),
    'commander_troops',v_cmd.troops + p_amount
  );
END;
$function$

-- ============================================================================
-- update_route(p_game_id bigint, p_commander_id bigint, p_new_remaining jsonb, p_is_loop boolean DEFAULT false)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_route(p_game_id bigint, p_commander_id bigint, p_new_remaining jsonb, p_is_loop boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_caller         UUID;
  v_player         RECORD;
  v_commander      RECORD;
  v_route          RECORD;
  v_movement       RECORD;
  v_cur_dest       TEXT;
  v_new_wps        JSONB;
  v_kept_wps       JSONB;
  v_norm_remaining JSONB;
  v_wp             JSONB;
  v_last_idx       INT;
  v_route_found    BOOLEAN := false;
BEGIN
  v_caller := auth.uid();
  SELECT * INTO v_player FROM game_players WHERE game_id = p_game_id AND user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  SELECT * INTO v_commander FROM commanders WHERE id = p_commander_id FOR UPDATE;
  IF NOT FOUND OR v_commander.game_id <> p_game_id THEN RAISE EXCEPTION 'Commander not found'; END IF;
  IF v_commander.owner_player_id <> v_player.id THEN RAISE EXCEPTION 'Not your commander'; END IF;
  IF v_commander.status <> 'moving' THEN RAISE EXCEPTION 'Commander is not marching'; END IF;

  SELECT * INTO v_movement FROM commander_movements
  WHERE commander_id = p_commander_id AND game_id = p_game_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No active movement leg found'; END IF;

  v_cur_dest := v_movement.to_castle_slug;

  -- Normalize p_new_remaining to [{castle_slug, action, delay, amount}]
  v_norm_remaining := '[]'::JSONB;
  FOR v_wp IN SELECT * FROM jsonb_array_elements(p_new_remaining)
  LOOP
    IF jsonb_typeof(v_wp) = 'string' THEN
      v_norm_remaining := v_norm_remaining || jsonb_build_array(
        jsonb_build_object('castle_slug', v_wp #>> '{}', 'action', 'pass', 'delay', 0)
      );
    ELSE
      v_norm_remaining := v_norm_remaining || jsonb_build_array(
        jsonb_build_object(
          'castle_slug', v_wp->>'castle_slug',
          'action',      COALESCE(v_wp->>'action', 'pass'),
          'delay',       COALESCE((v_wp->>'delay')::int, 0)
        ) ||
        CASE WHEN v_wp ? 'amount'
          THEN jsonb_build_object('amount', (v_wp->>'amount')::int)
          ELSE '{}'::jsonb
        END
      );
    END IF;
  END LOOP;

  -- Check if an active route exists
  SELECT * INTO v_route FROM commander_routes
  WHERE commander_id = p_commander_id AND game_id = p_game_id AND status = 'active';
  v_route_found := FOUND;

  IF v_route_found THEN
    -- Keep waypoints 0..current_idx (the locked current leg destination)
    SELECT jsonb_agg(elem ORDER BY ord) INTO v_kept_wps
    FROM jsonb_array_elements(v_route.waypoints) WITH ORDINALITY AS t(elem, ord)
    WHERE ord <= v_route.current_idx + 1;

    v_new_wps := COALESCE(v_kept_wps, '[]'::JSONB) || v_norm_remaining;
  ELSE
    -- No route yet: build one starting from current movement destination
    v_new_wps := jsonb_build_array(
      jsonb_build_object('castle_slug', v_cur_dest, 'action', 'pass', 'delay', 0)
    ) || v_norm_remaining;
  END IF;

  -- Ensure last waypoint uses deposit_all when not looping
  IF NOT p_is_loop AND jsonb_array_length(v_new_wps) > 0 THEN
    v_last_idx := jsonb_array_length(v_new_wps) - 1;
    IF v_new_wps->v_last_idx->>'action' = 'pass' THEN
      v_new_wps := jsonb_set(v_new_wps, ARRAY[v_last_idx::TEXT, 'action'], '"deposit_all"');
    END IF;
  END IF;

  IF v_route_found THEN
    UPDATE commander_routes SET waypoints = v_new_wps, is_loop = p_is_loop
    WHERE id = v_route.id;
  ELSE
    INSERT INTO commander_routes (commander_id, game_id, waypoints, current_idx, is_loop, status)
    VALUES (p_commander_id, p_game_id, v_new_wps, 0, p_is_loop, 'active');
  END IF;

  RETURN jsonb_build_object(
    'success',   true,
    'waypoints', jsonb_array_length(v_new_wps),
    'is_loop',   p_is_loop,
    'is_recall', jsonb_array_length(v_norm_remaining) = 0
  );
END;
$function$

-- ============================================================================
-- update_route(p_game_id bigint, p_commander_id bigint, p_new_remaining jsonb, p_is_loop boolean DEFAULT false, p_current_dest jsonb DEFAULT NULL::jsonb)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_route(p_game_id bigint, p_commander_id bigint, p_new_remaining jsonb, p_is_loop boolean DEFAULT false, p_current_dest jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_caller         UUID;
  v_player         RECORD;
  v_commander      RECORD;
  v_route          RECORD;
  v_movement       RECORD;
  v_cur_dest       TEXT;
  v_new_wps        JSONB;
  v_kept_wps       JSONB;
  v_norm_remaining JSONB;
  v_wp             JSONB;
  v_last_idx       INT;
  v_route_found    BOOLEAN := false;
BEGIN
  v_caller := auth.uid();
  SELECT * INTO v_player FROM game_players WHERE game_id = p_game_id AND user_id = v_caller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a player in this game'; END IF;

  SELECT * INTO v_commander FROM commanders WHERE id = p_commander_id FOR UPDATE;
  IF NOT FOUND OR v_commander.game_id <> p_game_id THEN RAISE EXCEPTION 'Commander not found'; END IF;
  IF v_commander.owner_player_id <> v_player.id THEN RAISE EXCEPTION 'Not your commander'; END IF;
  IF v_commander.status <> 'moving' THEN RAISE EXCEPTION 'Commander is not marching'; END IF;

  SELECT * INTO v_movement FROM commander_movements
  WHERE commander_id = p_commander_id AND game_id = p_game_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No active movement leg found'; END IF;

  v_cur_dest := v_movement.to_castle_slug;

  -- Normalize p_new_remaining to [{castle_slug, action, delay, amount?}]
  v_norm_remaining := '[]'::JSONB;
  FOR v_wp IN SELECT * FROM jsonb_array_elements(p_new_remaining)
  LOOP
    IF jsonb_typeof(v_wp) = 'string' THEN
      v_norm_remaining := v_norm_remaining || jsonb_build_array(
        jsonb_build_object('castle_slug', v_wp #>> '{}', 'action', 'pass', 'delay', 0)
      );
    ELSE
      v_norm_remaining := v_norm_remaining || jsonb_build_array(
        jsonb_build_object(
          'castle_slug', v_wp->>'castle_slug',
          'action',      COALESCE(v_wp->>'action', 'pass'),
          'delay',       COALESCE((v_wp->>'delay')::int, 0)
        ) ||
        CASE WHEN v_wp ? 'amount'
          THEN jsonb_build_object('amount', (v_wp->>'amount')::int)
          ELSE '{}'::jsonb
        END
      );
    END IF;
  END LOOP;

  -- Check if an active route exists
  SELECT * INTO v_route FROM commander_routes
  WHERE commander_id = p_commander_id AND game_id = p_game_id AND status = 'active';
  v_route_found := FOUND;

  IF v_route_found THEN
    SELECT jsonb_agg(elem ORDER BY ord) INTO v_kept_wps
    FROM jsonb_array_elements(v_route.waypoints) WITH ORDINALITY AS t(elem, ord)
    WHERE ord <= v_route.current_idx + 1;

    v_new_wps := COALESCE(v_kept_wps, '[]'::JSONB) || v_norm_remaining;

    -- Merge updated action/amount into the current leg destination waypoint
    IF p_current_dest IS NOT NULL THEN
      v_new_wps := jsonb_set(
        v_new_wps,
        ARRAY[v_route.current_idx::TEXT],
        (v_new_wps -> v_route.current_idx) || p_current_dest
      );
    END IF;
  ELSE
    v_new_wps := jsonb_build_array(
      jsonb_build_object('castle_slug', v_cur_dest, 'action', 'pass', 'delay', 0)
    ) || v_norm_remaining;
  END IF;

  -- Ensure last waypoint uses deposit_all when not looping (only if still 'pass')
  IF NOT p_is_loop AND jsonb_array_length(v_new_wps) > 0 THEN
    v_last_idx := jsonb_array_length(v_new_wps) - 1;
    -- Only auto-set if it wasn't explicitly overridden by p_current_dest
    IF v_new_wps->v_last_idx->>'action' = 'pass' THEN
      v_new_wps := jsonb_set(v_new_wps, ARRAY[v_last_idx::TEXT, 'action'], '"deposit_all"');
    END IF;
  END IF;

  IF v_route_found THEN
    UPDATE commander_routes SET waypoints = v_new_wps, is_loop = p_is_loop
    WHERE id = v_route.id;
  ELSE
    INSERT INTO commander_routes (commander_id, game_id, waypoints, current_idx, is_loop, status)
    VALUES (p_commander_id, p_game_id, v_new_wps, 0, p_is_loop, 'active');
  END IF;

  RETURN jsonb_build_object(
    'success',   true,
    'waypoints', jsonb_array_length(v_new_wps),
    'is_loop',   p_is_loop,
    'is_recall', jsonb_array_length(v_norm_remaining) = 0
  );
END;
$function$

-- ============================================================================
-- upgrade_castle_infrastructure(p_game_id bigint, p_castle_slug text, p_type text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.upgrade_castle_infrastructure(p_game_id bigint, p_castle_slug text, p_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller        UUID;
  v_player        RECORD;
  v_castle        RECORD;
  v_current_level INT;
  v_base          INT;
  v_cost          INT;
  v_current_tick  INT;
BEGIN
  v_caller := auth.uid();

  IF p_type NOT IN ('gold', 'industry', 'prestige') THEN
    RAISE EXCEPTION 'Invalid infrastructure type: % (must be gold, industry, or prestige)', p_type;
  END IF;

  SELECT * INTO v_player
  FROM game_players
  WHERE game_id = p_game_id AND user_id = v_caller;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'You are not a player in this game';
  END IF;

  SELECT * INTO v_castle
  FROM game_castles
  WHERE game_id = p_game_id AND castle_slug = p_castle_slug
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Castle not found in this game';
  END IF;
  IF v_castle.owner_player_id IS DISTINCT FROM v_player.id THEN
    RAISE EXCEPTION 'You do not own this castle';
  END IF;
  IF v_castle.is_under_siege THEN
    RAISE EXCEPTION 'Cannot upgrade a castle under siege';
  END IF;

  v_current_level := CASE p_type
    WHEN 'gold'     THEN v_castle.gold_level
    WHEN 'industry' THEN v_castle.industry_level
    WHEN 'prestige' THEN v_castle.prestige_level
  END;

  v_base := CASE p_type
    WHEN 'gold'     THEN 500
    WHEN 'industry' THEN 1000
    WHEN 'prestige' THEN 4000
  END;

  v_cost := FLOOR(v_base::NUMERIC * (v_current_level + 1) / GREATEST(v_castle.effective_influence, 1));

  IF v_player.gold < v_cost THEN
    RAISE EXCEPTION 'Insufficient gold: need %, have %', v_cost, v_player.gold;
  END IF;

  UPDATE game_players SET gold = gold - v_cost WHERE id = v_player.id;

  IF p_type = 'gold' THEN
    UPDATE game_castles SET gold_level = gold_level + 1
    WHERE game_id = p_game_id AND castle_slug = p_castle_slug;
  ELSIF p_type = 'industry' THEN
    UPDATE game_castles SET industry_level = industry_level + 1
    WHERE game_id = p_game_id AND castle_slug = p_castle_slug;
  ELSE
    UPDATE game_castles SET prestige_level = prestige_level + 1
    WHERE game_id = p_game_id AND castle_slug = p_castle_slug;
  END IF;

  SELECT current_tick INTO v_current_tick FROM games WHERE id = p_game_id;

  INSERT INTO game_events (game_id, tick, event_type, player_id, data)
  VALUES (
    p_game_id, v_current_tick, 'infrastructure_upgraded', v_player.id,
    jsonb_build_object(
      'castle_slug', p_castle_slug,
      'type',        p_type,
      'new_level',   v_current_level + 1,
      'cost',        v_cost
    )
  );

  RETURN jsonb_build_object(
    'success',        true,
    'castle_slug',    p_castle_slug,
    'type',           p_type,
    'new_level',      v_current_level + 1,
    'cost',           v_cost,
    'gold_remaining', v_player.gold - v_cost
  );
END;
$function$

-- ============================================================================
-- upgrade_council_seat(p_game_id bigint, p_seat text)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.upgrade_council_seat(p_game_id bigint, p_seat text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller   UUID;
  v_player   RECORD;
  v_cur_lv   INT;
  v_cost     INT;
BEGIN
  v_caller := auth.uid();
  SELECT * INTO v_player FROM game_players
  WHERE game_id = p_game_id AND user_id = v_caller FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'You are not a player in this game'; END IF;

  -- Get current level; default to 1 if seat row not yet created
  SELECT level INTO v_cur_lv FROM council_seats
  WHERE game_id = p_game_id AND player_id = v_player.id AND seat = p_seat;
  v_cur_lv := COALESCE(v_cur_lv, 1);

  -- Cost: 144 × current_level  (1→2 = 144, 2→3 = 288, 3→4 = 432, …)
  v_cost := 144 * v_cur_lv;

  IF v_player.prestige < v_cost THEN
    RAISE EXCEPTION 'Not enough prestige (need %, have %)', v_cost, v_player.prestige;
  END IF;

  UPDATE game_players SET prestige = prestige - v_cost WHERE id = v_player.id;

  INSERT INTO council_seats (game_id, player_id, seat, level, research_progress)
  VALUES (p_game_id, v_player.id, p_seat, v_cur_lv + 1, 0)
  ON CONFLICT (game_id, player_id, seat) DO UPDATE
    SET level = v_cur_lv + 1, research_progress = 0;

  INSERT INTO game_events (game_id, tick, event_type, player_id, data)
  SELECT p_game_id, current_tick, 'council_upgraded', v_player.id,
    jsonb_build_object('seat', p_seat, 'new_level', v_cur_lv + 1, 'cost', v_cost)
  FROM games WHERE id = p_game_id;

  RETURN jsonb_build_object(
    'success',    true,
    'seat',       p_seat,
    'new_level',  v_cur_lv + 1,
    'cost',       v_cost
  );
END;
$function$

