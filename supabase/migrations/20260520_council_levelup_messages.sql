-- ============================================================
-- process_ticks — council level-up messages + GM seat in Castellan report
-- Changes:
--   1. v_gm_rand_seat TEXT added to outer DECLARE
--   2. GM bonus block captures seat name and sends level-up inbox on promotion
--   3. Research seat block sends level-up inbox on promotion
--   4. Castellan Report body now includes gm_rand_seat
-- ============================================================
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
  SELECT * INTO v_game FROM games WHERE id = p_game_id;
  IF v_game.status NOT IN ('active') THEN
    RETURN jsonb_build_object('pending_ticks',0,'cycles_fired',0,'combats',0,'new_whisper_ids',ARRAY[]::BIGINT[]);
  END IF;

  v_pending := CASE v_game.tick_speed
    WHEN 'slow'       THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 7200)
    WHEN 'normal'     THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 3600)
    WHEN 'fast'       THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 1800)
    WHEN 'quad'       THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 900)
    WHEN 'turn_based' THEN FLOOR(EXTRACT(EPOCH FROM (v_now - v_game.last_tick_processed_at)) / 86400)
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
  RETURN jsonb_build_object('pending_ticks',v_pending,'cycles_fired',v_cycles_fired,'combats',v_combats,'new_whisper_ids',v_new_whisper_ids);
END;
$function$;
