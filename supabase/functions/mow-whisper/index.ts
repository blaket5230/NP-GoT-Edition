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

// ── Voice templates — rotated by tick to break repetition ─────────────────────

const VOICES: Array<(house: string, label: string) => string> = [
  (house, label) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} to your lord as a careful spymaster would: name your source type briefly, note what could not be confirmed, and say no more than the intelligence warrants. 2-3 sentences. No markdown. No modern language.`,
  (house, label) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} to your lord with barely concealed urgency — the informant came to you only hours ago, you have not had time to verify everything, and you say so plainly. 2-3 sentences. No markdown. No modern language.`,
  (house, label) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} to your lord in the manner of Varys of King's Landing — oblique, layered, never quite saying what you mean but meaning every word. 2 sentences. No markdown. No modern language.`,
  (house, label) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} to your lord as a strategist would: interpret what the intelligence means, what it implies about your enemies' intentions, what your lord ought to consider. 2-3 sentences. No markdown. No modern language.`,
  (house, label) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} to your lord drily — you are a man who has seen too much to be surprised, and you report the world as it is, without embellishment. 2 sentences. No markdown. No modern language.`,
  (house, label) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} to your lord in the manner of a cautious Maester — measured, clinical, aware that intelligence is rarely clean, hedging only where the facts demand it. 2-3 sentences. No markdown. No modern language.`,
  (house, label) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} to your lord with the weariness of a man who carries too many secrets — note the limits of what you know, and remind your lord that men have made grave errors on better intelligence than this. 2-3 sentences. No markdown. No modern language.`,
];

// ── Confidence instruction — shapes hedging without prescribing exact words ───

function confidenceInstruction(confidence: number): string {
  if (confidence >= 80) return `This intelligence is confirmed by multiple independent sources. Write with conviction — no hedging, no qualification.`;
  if (confidence >= 60) return `This comes from a source you trust, but is not corroborated. Convey reliability alongside mild uncertainty.`;
  if (confidence >= 40) return `This is unverified — a single informant, motivation unclear. Let your lord feel genuine doubt without dismissing the report.`;
  return `This is rumor only, passed through too many hands to fully trust. Be frank that it may be false, but worth your lord's awareness.`;
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
      const castleName   = body.castle_name as string ?? 'an unnamed keep';
      const captureHouse = body.player_id ? await houseName(body.player_id as string) : 'an unknown house';
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
  const voice  = VOICES[tick % VOICES.length];
  const system = `${voice(myHouse, label)} ${confidenceInstruction(confidence)}`;
  const user   = `${context} Write the dispatch now.`;

  const resp = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key':         ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'content-type':      'application/json',
    },
    body: JSON.stringify({
      model:      'claude-haiku-4-5-20251001',
      max_tokens: 200,
      system,
      messages: [{ role: 'user', content: user }],
    }),
  });

  const json = await resp.json();
  const text = json.content?.[0]?.text?.trim();
  if (!text) {
    console.error('Anthropic returned no content:', JSON.stringify(json).slice(0, 300));
  }
  return text ?? null;
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

    const { data: whisper, error: wErr } = await db
      .from('whispers')
      .select('*')
      .eq('id', whisper_id)
      .single();

    if (wErr || !whisper) {
      return new Response(JSON.stringify({ error: 'Whisper not found' }), { status: 404, headers: CORS });
    }

    if (whisper.text !== null) {
      return new Response(JSON.stringify({ ok: true, skipped: true }), {
        headers: { 'Content-Type': 'application/json', ...CORS },
      });
    }

    const myHouse = await houseName(whisper.player_id);

    const context = await buildContext(
      whisper.category,
      whisper.body ?? {},
      myHouse,
      whisper.tick,
      whisper.game_id,
      whisper.player_id,
    );

    const text = await generateText(
      myHouse,
      whisper.confidence,
      context,
      whisper.tick,
      whisper.category,
    );

    if (!text) {
      return new Response(JSON.stringify({ error: 'AI generation returned no content' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json', ...CORS },
      });
    }

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
