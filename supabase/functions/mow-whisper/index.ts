import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL       = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// ── Category labels ────────────────────────────────────────────────────────────

const CATEGORY_CONTEXT: Record<string, string> = {
  general_briefing: 'general intelligence briefing',
  combat_nearby:    'battle report',
  army_movement:    'troop movement sighting',
  castle_captured:  'castle change of hands',
  diplomacy_shift:  'diplomatic intelligence',
};

// ── Confidence phrase ──────────────────────────────────────────────────────────

function certaintyPhrase(confidence: number): string {
  if (confidence >= 80) return 'My lord, our sources confirm —';
  if (confidence >= 60) return 'Our ravens suggest —';
  if (confidence >= 40) return 'Word reaches us, though the source is uncertain —';
  return 'Rumor alone carries this word, my lord —';
}

// ── Fetch house name for a game_player id ─────────────────────────────────────

async function houseName(playerId: string | number): Promise<string> {
  const { data } = await db
    .from('game_players')
    .select('house_slug, houses(name)')
    .eq('id', playerId)
    .single();
  return (data as any)?.houses?.name ?? 'an unknown house';
}

// ── Build event context string from category + body ───────────────────────────

async function buildContext(
  category: string,
  body: Record<string, unknown>,
  myHouse: string,
  tick: number,
  gameId: number,
  playerId: number,
): Promise<string> {
  switch (category) {
    case 'combat_nearby': {
      const castleName = body.castle_name as string ?? 'an unnamed keep';
      const atkHouse   = await houseName(body.attacker_player_id as string);
      const defHouse   = await houseName(body.defender_player_id as string);
      const outcome    = body.result === 'attacker_won'
        ? `${atkHouse} seized it`
        : `${defHouse} held against the assault`;
      return `A battle was fought at ${castleName}. ${atkHouse} attacked ${defHouse}. ${outcome}.`;
    }

    case 'general_briefing': {
      const { data: castleRows } = await db
        .from('game_castles')
        .select('owner_player_id')
        .eq('game_id', gameId)
        .not('owner_player_id', 'is', null);

      const counts: Record<number, number> = {};
      for (const row of castleRows ?? []) {
        counts[row.owner_player_id] = (counts[row.owner_player_id] ?? 0) + 1;
      }
      const myCount    = counts[playerId] ?? 0;
      const houseCount = Object.keys(counts).length;
      const largest    = Object.entries(counts).sort((a, b) => b[1] - a[1])[0];
      const largestId  = largest?.[0];
      let largestLine  = '';
      if (largestId && Number(largestId) !== playerId) {
        const largestHouse = await houseName(largestId);
        largestLine = ` ${largestHouse} holds the most castles at ${largest[1]}.`;
      }
      return `Tick ${tick}. ${myHouse} controls ${myCount} castles. ${houseCount} houses remain active in the realm.${largestLine}`;
    }

    case 'army_movement': {
      const castleName  = body.castle_name as string ?? 'unknown lands';
      const movingHouse = body.player_id ? await houseName(body.player_id as string) : 'an unknown house';
      return `Our scouts report ${movingHouse} has dispatched forces toward ${castleName}.`;
    }

    case 'castle_captured': {
      const castleName    = body.castle_name as string ?? 'an unnamed keep';
      const captureHouse  = body.player_id ? await houseName(body.player_id as string) : 'an unknown house';
      return `${captureHouse} has taken control of ${castleName}.`;
    }

    case 'diplomacy_shift': {
      const houseA = body.player_a_id ? await houseName(body.player_a_id as string) : 'a house';
      const houseB = body.player_b_id ? await houseName(body.player_b_id as string) : 'another house';
      const change = body.change as string ?? 'changed their relationship';
      return `${houseA} and ${houseB} have ${change}.`;
    }

    default:
      return `Intelligence of category "${category}" has been gathered at tick ${tick}.`;
  }
}

// ── Claude call ───────────────────────────────────────────────────────────────

async function generateText(
  myHouse: string,
  confidence: number,
  context: string,
  tick: number,
  category: string,
): Promise<string> {
  const label  = CATEGORY_CONTEXT[category] ?? 'intelligence report';
  const phrase = certaintyPhrase(confidence);

  const system = [
    `You are the Master of Whisperers serving House ${myHouse} in the realm of Westeros.`,
    `Write a brief ${label} to your lord. Exactly 2–3 sentences. No markdown. No bullet points. No modern language.`,
    `Your confidence in this intelligence is ${confidence}%. Your tone, hedging, and certainty must reflect this exactly.`,
    `Open the dispatch with: "${phrase}" — then continue naturally from there.`,
  ].join(' ');

  const user = `Tick ${tick}. ${context} Write the dispatch now.`;

  const resp = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key':         ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'content-type':      'application/json',
    },
    body: JSON.stringify({
      model:      'claude-haiku-20240307',
      max_tokens: 200,
      system,
      messages: [{ role: 'user', content: user }],
    }),
  });

  const json = await resp.json();
  return json.content?.[0]?.text?.trim() ?? null;
}

// ── Main handler ──────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  try {
    const { whisper_id } = await req.json();
    if (!whisper_id) {
      return new Response(JSON.stringify({ error: 'Missing whisper_id' }), { status: 400, headers: CORS });
    }

    // Fetch the whisper
    const { data: whisper, error: wErr } = await db
      .from('whispers')
      .select('*')
      .eq('id', whisper_id)
      .single();

    if (wErr || !whisper) {
      return new Response(JSON.stringify({ error: 'Whisper not found' }), { status: 404, headers: CORS });
    }

    // Idempotent — skip if already generated
    if (whisper.text !== null) {
      return new Response(JSON.stringify({ ok: true, skipped: true }), {
        headers: { 'Content-Type': 'application/json', ...CORS },
      });
    }

    // Fetch the player's house name
    const myHouse = await houseName(whisper.player_id);

    // Build event context
    const context = await buildContext(
      whisper.category,
      whisper.body ?? {},
      myHouse,
      whisper.tick,
      whisper.game_id,
      whisper.player_id,
    );

    // Generate text
    const text = await generateText(
      myHouse,
      whisper.confidence,
      context,
      whisper.tick,
      whisper.category,
    );

    // Write back
    await db.from('whispers').update({ text }).eq('id', whisper_id);

    return new Response(JSON.stringify({ ok: true }), {
      headers: { 'Content-Type': 'application/json', ...CORS },
    });
  } catch (err) {
    console.error('mow-whisper error:', err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', ...CORS },
    });
  }
});
