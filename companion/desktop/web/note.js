// Home's "Voice note" quick action (CONTRACTS-WAVE8 §D1). The recording is the shell's (Sources/VoiceNote.swift: ⌃⌥N
// held or tapped, the dock's note button): the page only asks ({type: "note", action: toggle|send|cancel}) and reads
// what the shell pushes as `note` ({state, held, line, detail, shortcut, waiting, startedAt}). The dock's bar shows the
// note through every hide (over this window too), so the button only says what a press does now. Pure
// (tests/note.test.mjs).

export const NOTE_STATES = ['idle', 'recording', 'sending', 'sent', 'queued', 'discarded', 'failed'];

export function normalizeNote(raw) {
  const body = raw && typeof raw === 'object' ? raw : {};
  const state = NOTE_STATES.includes(body.state) ? body.state : 'idle';
  return {
    state,
    held: body.held === true,
    line: typeof body.line === 'string' ? body.line : '',
    detail: typeof body.detail === 'string' ? body.detail : '',
    shortcut: typeof body.shortcut === 'string' ? body.shortcut : '',
    waiting: Number.isInteger(body.waiting) && body.waiting > 0 ? body.waiting : 0,
    startedAt: typeof body.startedAt === 'number' && Number.isFinite(body.startedAt) ? body.startedAt : null,
  };
}

/** "0:07" since the note started. */
export function elapsed(note, now = Date.now()) {
  if (!note.startedAt) return '';
  const seconds = Math.max(0, Math.floor((now - note.startedAt) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

/**
 * What Home's button shows and does: `{label, hint, recording, busy}`. Recording, a press sends it; sending, it waits;
 * otherwise it starts one (and says how many wait for the bridge).
 */
export function quickAction(note, now = Date.now()) {
  const key = note.shortcut ? ` (${note.shortcut})` : '';
  if (note.state === 'recording') {
    return { label: `Send note ${elapsed(note, now)}`.trim(), hint: `Send the voice note now${key}`, recording: true, busy: false };
  }
  if (note.state === 'sending') return { label: 'Sending…', hint: 'The note is on its way to the bridge', recording: false, busy: true };
  const waiting = note.waiting ? ` · ${note.waiting} waiting for the bridge` : '';
  return {
    label: 'Voice note',
    hint: `Say it and it’s sent: a journal line, a task, a reminder or a note${key ? `. Hold ${note.shortcut} anywhere` : ''}${waiting}`,
    recording: false,
    busy: false,
  };
}
