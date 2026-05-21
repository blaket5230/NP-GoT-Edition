import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const SUPABASE_URL       = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// ─── Types ────────────────────────────────────────────────────────────────────

interface Ctx {
  ai_house_name:     string;
  human_house_name:  string;
  current_tick:      number;
  ai_castle_count?:  number;
  human_castle_count?: number;
  castle_name?:      string;       // for combat / expansion triggers
  combat_outcome?:   'won' | 'lost'; // from the AI's perspective
  prior_messages?:   { sender: string; text: string }[];
}

interface Request {
  trigger:         'player_message' | 'combat' | 'expansion_near' | 'production_milestone' | 'near_elimination';
  game_id:         number;
  ai_player_id:    number;
  human_player_id: number;
  thread_id?:      number | null;
  ctx:             Ctx;
}

// ─── Prompt builders ──────────────────────────────────────────────────────────

function systemPrompt(ctx: Ctx): string {
  return [
    `You are a lord of ${ctx.ai_house_name}, a great house in the realm of Westeros.`,
    `You are writing a raven dispatch to ${ctx.human_house_name}.`,
    `Rules: 2–4 sentences. No modern language. No markdown. No meta-references to games or simulations.`,
    `Write as a medieval lord would — measured, political, occasionally veiled in courtesy.`,
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

    // Basic validation
    if (!trigger || !game_id || !ai_player_id || !human_player_id) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), { status: 400 });
    }

    const replyText = await generateReply(trigger, ctx);

    if (thread_id) {
      // Reply into existing thread
      const { error } = await supabase.rpc('ai_send_thread_message', {
        p_thread_id: thread_id,
        p_player_id: ai_player_id,
        p_message:   replyText,
      });
      if (error) throw error;
    } else {
      // Create a new thread initiated by the AI
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
