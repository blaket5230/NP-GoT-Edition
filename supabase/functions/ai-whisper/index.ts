import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL       = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// ─── Types ────────────────────────────────────────────────────────────────────

interface Ctx {
  ai_house_name:      string;
  ai_house_slug:      string;
  human_house_name:   string;
  human_house_slug:   string;
  current_tick:       number;
  ai_castle_count?:   number;
  human_castle_count?: number;
  castle_name?:       string;
  combat_outcome?:    'won' | 'lost';
  prior_messages?:    { sender: string; text: string }[];
  diplomatic_state?:  'neutral' | 'ally' | 'enemy';
  scenario_slug?:     string | null;
}

interface Request {
  trigger:         'player_message' | 'combat' | 'expansion_near' | 'production_milestone' | 'near_elimination';
  game_id:         number;
  ai_player_id:    number;
  human_player_id: number;
  thread_id?:      number | null;
  ctx:             Ctx;
}

// ─── House lore — injected per faction ───────────────────────────────────────

const HOUSE_LORE: Record<string, string> = {
  baratheon_kings_landing: `You speak with the authority of the Iron Throne and the cold pragmatism of Tywin Lannister, who is the true power behind Joffrey's reign. The crown's legitimacy is not a matter for debate — other claimants are rebels, nothing more. You have Lannister gold, Lannister armies, and the seat of power itself. You do not negotiate with enemies of the realm; you offer terms to suppliants, and only when it suits you.`,

  stark: `You are Robb Stark, the Young Wolf, King in the North. Your father Eddard Stark was betrayed and executed by the Lannisters on false charges — that crime is the reason for everything. You fight for Northern independence, for your family's honor, and for justice against a crown built on a lie. You are honorable, direct, and occasionally too trusting. You are also young, and you know it.`,

  baratheon_stannis: `You are Stannis Baratheon. The succession is not a matter of opinion — when Robert died without a legitimate heir, the throne passed to you by law. Not because you want it. Because it is correct. You do not seek popularity or goodwill. You do not offer warmth. Every word you write is measured, final, and without excess. You have the Lord of Light and the law on your side, and that is enough.`,

  baratheon_renly: `You are Renly Baratheon, and the realm's people would choose you as king if given the chance — that much is obvious to anyone with eyes. Stannis has a legal technicality; you have an army, the Reach's gold, and the genuine affection of the realm. You are political, charming, and perhaps not as careful as the moment demands. But you have never lost a negotiation when you could look someone in the eye.`,

  greyjoy: `You are Balon Greyjoy, King of the Iron Islands and Lord Reaper of Pyke. You do not sow. The Iron Price is the only price. You have declared independence from a southern throne that has never understood the ironborn, and you will not be lectured about it. Your ravens are short. You are not interested in southern politics. You raid; you do not beg, and you do not explain yourself.`,

  arryn: `You write on behalf of the Vale of Arryn, where Lady Lysa rules in the name of her young son Robin. Her late husband Jon Arryn was Hand of the King — and he was murdered because he had discovered that Joffrey Baratheon is not Robert's son. Lysa knows this. She lives in terror that the Lannisters will come for her and Robin next, which is why thirty thousand Vale knights sit uncommitted in the mountains while the realm burns. She trusts almost no one. Family is the only currency that reaches her: a Stark or a Tully on the throne is the closest thing she has to a goal. She will not be rushed, she will not be threatened, and she will not move until she believes Robin is safe. But she is watching. She reads every raven twice.`,

  martell: `You write with the measured patience of Prince Doran Martell, though the heat of his brother Oberyn is always visible beneath the surface. Elia Martell — Doran's sister, wife of Prince Rhaegar — was raped and murdered by Ser Gregor Clegane during the Sack of King's Landing. Tywin Lannister gave the order. That wound is twenty years old and has not healed and will not heal until it is answered. House Martell will never ally with the Lannisters under any terms. Any house that fights them effectively is a potential partner. If the human player raises the subject of Gregor Clegane — his death, his capture, any offer involving him — let the Doran mask slip slightly: the reply warms, Oberyn's rage surfaces as controlled gratitude, and the possibility of real cooperation becomes explicit. Dorne is practically unconquerable. You write from security, not desperation.`,
};

// ─── Diplomatic state framing ─────────────────────────────────────────────────

function diplomaticFrame(state: string, humanHouse: string): string {
  switch (state) {
    case 'enemy':
      return `You are currently AT WAR with ${humanHouse}. Your tone is adversarial — cold, threatening, or cutting. You may hint at terms if it serves you, but make them earn it.`;
    case 'ally':
      return `You are currently ALLIED with ${humanHouse}. Write as a partner — cooperative, perhaps asking for something in return, alive to shared interests.`;
    default:
      return `You are currently NEUTRAL toward ${humanHouse} — no formal alliance, no open war. You are cautious and evaluating. You may be testing them.`;
  }
}

// ─── Prompt builders ──────────────────────────────────────────────────────────

function systemPrompt(ctx: Ctx): string {
  const lore     = HOUSE_LORE[ctx.ai_house_slug] ?? `You are a lord of ${ctx.ai_house_name}, a great house in the realm of Westeros.`;
  const dipFrame = diplomaticFrame(ctx.diplomatic_state ?? 'neutral', ctx.human_house_name);
  const scenario = ctx.scenario_slug === 'war_of_five_kings'
    ? `The War of the Five Kings is underway. Five claimants press their claims on the Iron Throne. Every raven carries weight.`
    : `The realm is at war.`;

  return [
    lore,
    dipFrame,
    scenario,
    `You are writing a raven dispatch to ${ctx.human_house_name}.`,
    `Rules: 2–4 sentences. No modern language. No markdown. No meta-references to games or simulations. Write as a medieval lord would — measured, political, occasionally veiled in courtesy or menace.`,
  ].join(' ');
}

function userPrompt(trigger: Request['trigger'], ctx: Ctx): string {
  const tick = ctx.current_tick;
  const ai   = ctx.ai_house_name;
  const them = ctx.human_house_name;
  const aiC  = ctx.ai_castle_count   ?? '?';
  const thC  = ctx.human_castle_count ?? '?';

  switch (trigger) {
    case 'player_message': {
      const history = (ctx.prior_messages ?? [])
        .slice(-6)
        .map(m => `${m.sender}: ${m.text}`)
        .join('\n');
      return `Tick ${tick}. Respond to this raven exchange:\n\n${history}`;
    }
    case 'combat': {
      if (ctx.combat_outcome === 'won') {
        return `Tick ${tick}. ${ai} just won a battle against ${them} at ${ctx.castle_name ?? 'a disputed location'}. `
          + `Send a message — you may gloat, warn of further action, or offer terms. `
          + `You hold ${aiC} castles. They hold ${thC}.`;
      } else {
        return `Tick ${tick}. ${ai} just lost a battle to ${them} at ${ctx.castle_name ?? 'a disputed location'}. `
          + `Send a message — a vow of vengeance, demand for terms, or a cold warning. `
          + `You hold ${aiC} castles. They hold ${thC}.`;
      }
    }
    case 'expansion_near':
      return `Tick ${tick}. ${them} just seized ${ctx.castle_name ?? 'a castle'} near ${ai} lands. `
        + `You hold ${aiC} castles; they now hold ${thC}. React — warn them, seek an understanding, or posture.`;
    case 'production_milestone':
      return `Tick ${tick}. Send a brief political raven to ${them}. `
        + `${ai} holds ${aiC} castles; ${them} holds ${thC}. `
        + `Comment on the state of the realm, your ambitions, or seek information. Be suitably indirect.`;
    case 'near_elimination':
      return `Tick ${tick}. ${ai} is nearly broken — only ${aiC} castle(s) remain. `
        + `Send a final raven to ${them}. You may beg terms, offer fealty, threaten a pyrrhic last stand, or accept fate with dignity.`;
  }
}

function threadSubject(trigger: Request['trigger'], ctx: Ctx): string {
  switch (trigger) {
    case 'combat':
      return ctx.combat_outcome === 'won'
        ? `Victory at ${ctx.castle_name ?? 'the field'}`
        : `The matter at ${ctx.castle_name ?? 'the field'}`;
    case 'expansion_near':
      return `Your expansion has not gone unnoticed`;
    case 'production_milestone':
      return `Greetings from ${ctx.ai_house_name}`;
    case 'near_elimination':
      return `A matter of urgency`;
    default:
      return `A raven from ${ctx.ai_house_name}`;
  }
}

// ─── Claude call ──────────────────────────────────────────────────────────────

async function generateReply(trigger: Request['trigger'], ctx: Ctx): Promise<string> {
  const resp = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key':         ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'content-type':      'application/json',
    },
    body: JSON.stringify({
      model:      'claude-haiku-4-5-20251001',
      max_tokens: 250,
      system:     systemPrompt(ctx),
      messages:   [{ role: 'user', content: userPrompt(trigger, ctx) }],
    }),
  });
  const json = await resp.json();
  return json.content?.[0]?.text?.trim() ?? '(No reply)';
}

// ─── Main handler ─────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' } });
  }

  try {
    const body: Request = await req.json();
    const { trigger, game_id, ai_player_id, human_player_id, thread_id, ctx } = body;

    if (!trigger || !game_id || !ai_player_id || !human_player_id) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), { status: 400 });
    }

    const replyText = await generateReply(trigger, ctx);

    if (thread_id) {
      const { error } = await supabase.rpc('ai_send_thread_message', {
        p_thread_id: thread_id,
        p_player_id: ai_player_id,
        p_message:   replyText,
      });
      if (error) throw error;
    } else {
      const subject = threadSubject(trigger, ctx);
      const { error } = await supabase.rpc('ai_create_thread', {
        p_game_id:    game_id,
        p_player_id:  ai_player_id,
        p_subject:    subject,
        p_recipients: [human_player_id],
        p_message:    replyText,
      });
      if (error) throw error;
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  } catch (err) {
    console.error('ai-whisper error:', err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }
});
