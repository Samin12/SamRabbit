// Voice notes in the window's inbox (web/inbox.js, web/agents.js): the bridge's `note:<captureId>` items
// (samrabbit_capture inbox_items) with their suggestion, the button Tasks shows for them (the suggestion's verb, or
// "Try again" for a note that failed), what counts as needing Samin, and the `act` that goes to the bridge.
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { AgentInbox } from '../web/agents.js';
import { isVoiceNote, needsYou, normalizeInbox, normalizeItem, noteAction, optimisticItem, sourceLabel } from '../web/inbox.js';

const KEPT = 'note:3f2b8c1e-7d4a-4e9b-8f21-6a5c0d9e1b47';
const FAILED = 'note:9c4e2a7b-1f3d-4b8e-a6c5-2d7f0e8b3a91';

/** The bridge's own item. */
function note(id, { status = 'needs-input', unread = true, suggestion = null, can = ['act', 'dismiss', 'seen'] } = {}) {
  return {
    id, source: 'note', agent: null, title: 'Call the bank about the replacement card.', project: 'Voice note', cwd: null,
    status, statusLabel: suggestion ? suggestion.label : status === 'error' ? "Couldn't hear it" : 'Saved note',
    summary: 'Call the bank about the replacement card.', updatedAt: '2026-10-14T13:00:00Z', unread,
    pending: { approvals: [], inputs: [] }, can, live: false, progress: null, phase: null, suggestion,
    captureId: id.slice(5), capturedAt: '2026-10-14T09:00:00-04:00',
  };
}

const TASK = { action: 'task', label: 'Start it as a T3 task?' };

test('a note item keeps its suggestion; odd ones read as none', () => {
  const item = normalizeItem(note(KEPT, { suggestion: TASK }));
  assert.equal(isVoiceNote(item), true);
  assert.deepEqual(item.suggestion, { action: 'task', label: 'Start it as a T3 task?' });
  assert.equal(normalizeItem(note(KEPT, { suggestion: 'Start it?' })).suggestion, null);
  assert.equal(normalizeItem(note(KEPT, { suggestion: { label: 'no action' } })).suggestion, null);
  assert.equal(normalizeItem({ id: 't3:x', status: 'done' }).suggestion, null);
  assert.equal(sourceLabel('note'), 'SamRabbit', 'the bridge names the project "Voice note"');
});

test('the button: the suggestion as a verb, Try again for a failed note, nothing for a block or a plain note', () => {
  assert.deepEqual(noteAction(normalizeItem(note(KEPT, { suggestion: TASK }))), { label: 'Start as task', action: 'task' });
  assert.deepEqual(noteAction(normalizeItem(note(KEPT, { suggestion: { action: 'journal', label: 'Add it to your journal?' } }))),
    { label: 'Add to journal', action: 'journal' });
  assert.deepEqual(noteAction(normalizeItem(note(KEPT, { suggestion: { action: 'event', label: 'Put it on your calendar?' } }))),
    { label: 'Put on calendar', action: 'event' });
  assert.equal(noteAction(normalizeItem(note(KEPT, { suggestion: { action: 'block', label: 'Block the time?' } }))), null,
    'the bridge has no act for a block');
  assert.equal(noteAction(normalizeItem(note(KEPT, { status: 'idle' }))), null);
  assert.equal(noteAction(normalizeItem(note(KEPT, { suggestion: TASK, can: ['seen'] }))), null, 'a bridge without act');
  assert.deepEqual(noteAction(normalizeItem(note(FAILED, { status: 'error' }))), { label: 'Try again', action: null });
  assert.equal(noteAction(normalizeItem({ id: 't3:x', source: 't3', status: 'error', can: ['act'] })), null, 'notes only');
});

test('a failed note needs Samin until he has seen it; any other failure until it changes', () => {
  assert.equal(needsYou(normalizeItem(note(FAILED, { status: 'error', unread: true }))), true);
  assert.equal(needsYou(normalizeItem(note(FAILED, { status: 'error', unread: false }))), false, 'Mark seen clears it');
  assert.equal(needsYou(normalizeItem(note(KEPT, { suggestion: TASK }))), true);
  assert.equal(needsYou(normalizeItem(note(KEPT, { status: 'idle', unread: false }))), false);
  assert.equal(needsYou(normalizeItem({ id: 't3:x', source: 't3', status: 'error', unread: false })), true);
  const inbox = normalizeInbox({ items: [note(FAILED, { status: 'error', unread: false }), note(KEPT, { suggestion: TASK })] });
  assert.equal(inbox.counts.needsYou, 1, 'computed like the dock');
});

test('act: out of Needs you at once; a suggestion goes as {action}, a retry with none', async () => {
  const calls = [];
  const api = {
    async inbox() { return { items: [] }; },
    async act(id, action, body) { calls.push([id, action, body]); return { ok: true, capture: { state: 'done' } }; },
  };
  const inbox = new AgentInbox(api, { poll: false, now: () => 1_000 });
  inbox.receive({ revision: 4, items: [note(KEPT, { suggestion: TASK }), note(FAILED, { status: 'error' })] });
  const kept = inbox.item(KEPT);
  const pending = inbox.actOnNote(kept);
  assert.equal(inbox.item(KEPT).status, 'idle', 'optimistic: no longer needs him');
  assert.equal(inbox.item(KEPT).statusLabel, 'On it…');
  assert.equal(inbox.busy.get(KEPT), 'act');
  await pending;
  assert.deepEqual(calls.at(-1), [KEPT, 'act', { action: 'task' }]);
  await inbox.actOnNote(inbox.item(FAILED));
  assert.deepEqual(calls.at(-1), [FAILED, 'act', {}], 'the bridge picks the retry');
  assert.equal(inbox.item(FAILED).statusLabel, 'Trying again…');
  // Nothing to do: no call.
  const before = calls.length;
  assert.equal(await inbox.actOnNote({ ...kept, suggestion: null }), null);
  assert.equal(calls.length, before);
  assert.deepEqual(optimisticItem(normalizeItem(note(KEPT, { suggestion: TASK })), 'act', { action: 'journal' }).unread, false);
});
