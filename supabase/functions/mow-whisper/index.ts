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

function pick<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)];
}

// ── Category labels ────────────────────────────────────────────────────────────

const CATEGORY_LABEL: Record<string, string> = {
  general_briefing: 'general intelligence briefing',
  combat_nearby:    'battle report',
  army_movement:    'troop movement sighting',
  castle_captured:  'castle change of hands',
  diplomacy_shift:  'diplomatic intelligence',
};

// ── Source types — injected randomly to give Claude textural variety ──────────

const SOURCES = [
  'a paid informant within their household',
  'a raven intercepted en route',
  'a merchant who passed through the region',
  'a wandering Maester who stopped at our gates',
  'a stable hand with loose lips and a taste for coin',
  'a sellsword who once rode with their banners',
  'a septon whose parish sits near the action',
  'a hedge knight who owes us a debt',
  'whispers from the dockside taverns',
  'a disgraced steward seeking a new lord',
  'a minstrel who plays at their feasts',
  'an innkeeper on the road between our keeps',
];

// ── Voice pool — chosen randomly each call ────────────────────────────────────

const VOICES: Array<(house: string, label: string, source: string) => string> = [
  (house, label, source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} to your lord as a careful spymaster: name the source type (${source}), note what you could not confirm, and say no more than the intelligence warrants. 2-3 sentences. No markdown. No modern language.`,

  (house, label, source) =>
    `You are the Master of Whisperers serving House ${house}. This ${label} came from ${source} only hours ago — you have had no time to corroborate it, and you say so plainly, with barely concealed urgency. 2-3 sentences. No markdown. No modern language.`,

  (house, label, _source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} in the manner of Varys of King's Landing — oblique, layered, never quite saying what you mean but meaning every word. Leave your lord to draw the obvious conclusion. 2 sentences. No markdown. No modern language.`,

  (house, label, _source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} as a strategist: interpret what the intelligence implies about your enemies' intentions and what your lord ought to consider. Do not merely state facts — read between them. 2-3 sentences. No markdown. No modern language.`,

  (house, label, _source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} drily. You have seen too much to be surprised by anything. Report the world as it is, without embellishment or alarm. 2 sentences. No markdown. No modern language.`,

  (house, label, source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} in the manner of a cautious Maester: measured, clinical, careful to note that the source (${source}) is not infallible. Hedge only where the facts genuinely demand it. 2-3 sentences. No markdown. No modern language.`,

  (house, label, _source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} with the weariness of a man who carries too many secrets. Remind your lord gently that men have made grave errors on better intelligence than this. 2-3 sentences. No markdown. No modern language.`,

  (house, label, source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} like a man who looks over his shoulder before speaking — conspiratorial, low-voiced, alive to the danger of being overheard. The source (${source}) must not be named aloud. 2 sentences. No markdown. No modern language.`,

  (house, label, _source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} with cold professionalism — this is a transaction, not a council. State what you know, state what you do not know, and stop. 2 sentences. No markdown. No modern language.`,

  (house, label, source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} with the quiet bitterness of a man who has seen lords ignore good intelligence before. You tell them anyway. The source is ${source}. 2-3 sentences. No markdown. No modern language.`,

  (house, label, _source) =>
    `You are the Master of Whisperers serving House ${house}. You are a nervous subordinate reporting to a powerful lord — slightly over-explaining, apologizing for the gaps in what you know, but accurate in what you do report. Deliver this ${label}. 2-3 sentences. No markdown. No modern language.`,

  (house, label, _source) =>
    `You are the Master of Whisperers serving House ${house}. Deliver this ${label} as though the weight of it has just settled on you — your lord will want to know, you are not certain how they will receive it, and that tension shows in how you present it. 2-3 sentences. No markdown. No modern language.`,
];

// ── Confidence instruction ────────────────────────────────────────────────────

function confidenceInstruction(confidence: number): string {
  if (confidence >= 80) return `This intelligence is confirmed by multiple independent sources. Write with conviction — no hedging, no qualification.`;
  if (confidence >= 60) return `This comes from a reliable source, but is not corroborated. Convey confidence alongside mild uncertainty.`;
  if (confidence >= 40) return `This is unverified — a single informant, motivation unclear. Let your lord feel genuine doubt without dismissing the report.`;
  if (confidence >= 25) return `This is little better than rumor — secondhand at best, the source's reliability uncertain. Be frank that it may be wrong, but it is worth your lord's attention.`;
  return `This is barely more than tavern gossip, passed through too many hands to trust. Report it as such — do not dress it up.`;
}

// ── Fetch house name ──────────────────────────────────────────────────────────

async function houseName(playerId: string | number): Promise<string> {
  const { data } = await db
    .from('game_players')
    .select('house_slug, houses(name)')
    .eq('id', playerId)
    .single();
  return (data as any)?.houses?.name ?? 'an unknown house';
}

// ── Build context string ──────────────────────────────────────────────────────

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
      const won        = body.result === 'attacker_won';
      const outcome    = won ? `${atkHouse} took the castle` : `${defHouse} held the walls`;
      const coda = pick([
        `Casualty figures are unconfirmed.`,
        `The scale of the engagement remains unclear.`,
        `What survives of the garrison is unknown.`,
        `Whether this signals a wider campaign is not yet clear.`,
      ]);
      return `${atkHouse} assaulted ${defHouse} at ${castleName}. ${outcome}. ${coda}`;
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
      const sorted     = Object.entries(counts).sort((a, b) => b[1] - a[1]);
      const largest    = sorted[0];
      const largestId  = largest?.[0];
      const second     = sorted[1];

      let realmLine = `${houseCount} house${houseCount !== 1 ? 's' : ''} remain active in the realm.`;
      if (largestId && Number(largestId) !== playerId) {
        const largestHouse = await houseName(largestId);
        realmLine += ` ${largestHouse} leads with ${largest[1]} castle${largest[1] !== 1 ? 's' : ''}.`;
        if (second && Number(second[0]) !== playerId && Number(second[0]) !== Number(largestId)) {
          const secondHouse = await houseName(second[0]);
          realmLine += ` ${secondHouse} holds ${second[1]}.`;
        }
      }

      const angle = pick([
        `The balance of power shifts. ${myHouse} holds ${myCount} castle${myCount !== 1 ? 's' : ''}. ${realmLine}`,
        `A survey of the realm as it stands at tick ${tick}: ${myHouse} controls ${myCount} castle${myCount !== 1 ? 's' : ''}. ${realmLine}`,
        `Intelligence gathered from across the realm. ${myHouse} holds ${myCount} castle${myCount !== 1 ? 's' : ''} at present. ${realmLine}`,
      ]);
      return angle;
    }

    case 'army_movement': {
      const castleName  = body.castle_name as string ?? 'unknown lands';
      const movingHouse = body.player_id ? await houseName(body.player_id as string) : 'an unknown house';
      const coda = pick([
        `Their purpose is not yet known.`,
        `Whether this is a feint or a true advance, we cannot say.`,
        `The size of the force is not confirmed.`,
        `When they departed and by what road remains uncertain.`,
      ]);
      return `${movingHouse} has moved forces toward ${castleName}. ${coda}`;
    }

    case 'castle_captured': {
      const castleName   = body.castle_name as string ?? 'an unnamed keep';
      const captureHouse = body.player_id ? await houseName(body.player_id as string) : 'an unknown house';
      const coda = pick([
        `The circumstances of the transfer are unclear.`,
        `Under what terms the garrison surrendered, if it did, is not known.`,
        `Whether this was taken by assault or yielded is unconfirmed.`,
      ]);
      return `${captureHouse} now holds ${castleName}. ${coda}`;
    }

    case 'diplomacy_shift': {
      const houseA = body.player_a_id ? await houseName(body.player_a_id as string) : 'a house';
      const houseB = body.player_b_id ? await houseName(body.player_b_id as string) : 'another house';
      const change = body.change as string ?? 'altered their relationship';
      const coda = pick([
        `What terms were agreed, if any, is not known.`,
        `Our source was not present for any exchange — only the aftermath.`,
        `Whether this holds is another matter entirely.`,
        `The full implications for the realm remain to be seen.`,
      ]);
      return `${houseA} and ${houseB} have ${change}. ${coda}`;
    }

    default:
      return `Intelligence of category "${category}" was gathered at tick ${tick}.`;
  }
}

// ── Claude call ───────────────────────────────────────────────────────────────

async function generateText(
  myHouse: string,
  confidence: number,
  context: string,
  category: string,
): Promise<string> {
  const label  = CATEGORY_LABEL[category] ?? 'intelligence report';
  const source = pick(SOURCES);
  const voice  = pick(VOICES);
  const system = `${voice(myHouse, label, source)} ${confidenceInstruction(confidence)}`;
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
