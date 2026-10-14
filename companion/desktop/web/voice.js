// The window's live transcript of a Mac voice conversation. The voice itself is native (MacVoice, Sources/Voice*.swift:
// one audio engine, the wake phrase, the streaming turns); the shell pushes its published state here
// ({state, error, heard, caption, level, micMuted, brain, conversationId}) and this turns the snapshots into turns:
// each new `heard` is a line of yours, `caption` streams the reply. Pure (tests/voice.test.mjs).

const ACTIVE = new Set(['starting', 'listening', 'thinking', 'speaking']);
export const MAX_TURNS = 40;

function text(value) {
  return typeof value === 'string' ? value : '';
}

/** A snapshot as the page uses it (the shell's names; anything missing reads as idle and empty). */
export function normalizeVoice(raw) {
  const value = raw && typeof raw === 'object' ? raw : {};
  const state = ['idle', 'starting', 'listening', 'thinking', 'speaking', 'error'].includes(value.state) ? value.state : 'idle';
  const level = Number(value.level);
  return {
    state,
    error: text(value.error),
    heard: text(value.heard).trim(),
    caption: text(value.caption),
    level: Number.isFinite(level) ? Math.max(0, Math.min(1, level)) : 0,
    micMuted: value.micMuted === true,
    wakeArmed: value.wakeArmed === true,
    wakeEnabled: value.wakeEnabled !== false,
    wakeProblem: text(value.wakeProblem) || null,
    brain: text(value.brain) || null,
    conversationId: text(value.conversationId) || null,
    shortcut: text(value.shortcut),
    shortcutProblem: text(value.shortcutProblem) || null,
  };
}

export function isActive(snapshot) {
  return Boolean(snapshot) && ACTIVE.has(snapshot.state);
}

/** The voice bar's label and tone: LISTENING, THINKING, SPEAKING, MUTED, VOICE PROBLEM. */
export function voiceLabel(snapshot) {
  if (!snapshot) return { label: '', tone: 'idle' };
  switch (snapshot.state) {
    case 'starting': return { label: 'Starting', tone: 'active' };
    case 'listening': return snapshot.micMuted ? { label: 'Muted', tone: 'muted' } : { label: 'Listening', tone: 'active' };
    case 'thinking': return { label: 'Thinking', tone: 'active' };
    case 'speaking': return { label: 'Speaking', tone: 'active' };
    case 'error': return { label: 'Voice problem', tone: 'error' };
    default: return { label: 'Ended', tone: 'idle' };
  }
}

/** What the line under the label says while nothing has been said yet. */
export function idleCaption(snapshot) {
  switch (snapshot && snapshot.state) {
    case 'starting': return 'One moment…';
    case 'listening': return snapshot.micMuted ? 'The microphone is muted.' : 'Go ahead, I’m listening.';
    case 'thinking': return 'Working on it…';
    default: return '';
  }
}

/**
 * The conversation so far, built from snapshots. A new `heard` adds your line and closes the reply before it; a
 * `caption` going empty closes the reply (the next one is a new turn, e.g. an announcement); a caption that doesn't
 * continue the open reply starts a new one. A conversation that starts clears the old one.
 */
export class VoiceTranscript {
  constructor() {
    this.reset();
  }

  reset() {
    this.turns = [];
    this.snapshot = normalizeVoice(null);
    this.active = false;
    this.ended = false;
    this.endedAt = null;
    this.conversationId = null;
    this.error = '';
    this.lastHeard = '';
    this.lastCaption = '';
  }

  /** Applies one snapshot; returns true when anything on screen changes. */
  apply(raw, now = Date.now()) {
    const next = normalizeVoice(raw);
    const before = JSON.stringify([this.turns, this.active, this.ended, this.snapshot]);
    const wasActive = this.active;
    const active = isActive(next);
    if (active && !wasActive) {
      this.reset();
      this.active = true;
    }
    if (next.conversationId) this.conversationId = next.conversationId;
    if (next.heard && next.heard !== this.lastHeard) {
      this.closeReply();
      this.turns.push({ role: 'user', text: next.heard, final: true });
    }
    this.lastHeard = next.heard;
    if (next.caption !== this.lastCaption) {
      if (!next.caption.trim()) {
        this.closeReply();
      } else {
        const last = this.turns[this.turns.length - 1];
        const continues = last && last.role === 'assistant' && !last.final && continuation(last.text, next.caption);
        if (continues) last.text = next.caption;
        else {
          this.closeReply();
          this.turns.push({ role: 'assistant', text: next.caption, final: false });
        }
      }
      this.lastCaption = next.caption;
    }
    if (next.state === 'error') this.error = next.error || 'Something went wrong.';
    if (!active && wasActive) {
      this.closeReply();
      this.active = false;
      this.ended = true;
      this.endedAt = now;
    } else if (!active && !wasActive && next.state === 'error') {
      // A conversation that failed to start: shown as ended, with its problem.
      this.ended = true;
      this.endedAt = now;
    }
    if (this.turns.length > MAX_TURNS) this.turns = this.turns.slice(-MAX_TURNS);
    this.snapshot = next;
    return JSON.stringify([this.turns, this.active, this.ended, this.snapshot]) !== before;
  }

  closeReply() {
    const last = this.turns[this.turns.length - 1];
    if (last && last.role === 'assistant') last.final = true;
  }

  /** Whether the panel shows: during a conversation, and for a while after (until dismissed). */
  visible(now = Date.now(), linger = 12_000) {
    if (this.active) return true;
    return this.ended && this.endedAt != null && now - this.endedAt < linger;
  }

  dismiss() {
    this.ended = false;
    this.endedAt = null;
  }
}

/** A streamed caption grows from the text before it (allowing a rewrite of the last word or two). */
export function continuation(previous, next) {
  const a = String(previous || '').trim();
  const b = String(next || '').trim();
  if (!a) return true;
  if (b.startsWith(a)) return true;
  const head = a.slice(0, Math.max(1, Math.min(a.length - 12, 48)));
  return head.length >= 8 && b.startsWith(head);
}
