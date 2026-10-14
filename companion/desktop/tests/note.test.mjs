// Home's voice note button (web/note.js): the note's states as the shell pushes them (Sources/VoiceNoteModels.swift
// VoiceNoteSnapshot.json), the time since it started, and what a press does now.
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { elapsed, NOTE_STATES, normalizeNote, quickAction } from '../web/note.js';

test('the voice note button says what a press does now', () => {
  assert.deepEqual(normalizeNote(null), { state: 'idle', held: false, line: '', detail: '', shortcut: '', waiting: 0, startedAt: null });
  const recording = normalizeNote({ state: 'recording', shortcut: '⌃⌥N', startedAt: 1_000_000 });
  assert.equal(elapsed(recording, 1_000_000 + 73_400), '1:13');
  assert.deepEqual(quickAction(recording, 1_007_400), { label: 'Send note 0:07', hint: 'Send the voice note now (⌃⌥N)', recording: true, busy: false });
  assert.equal(quickAction(normalizeNote({ state: 'sending' })).busy, true);
  const idle = quickAction(normalizeNote({ state: 'sent', shortcut: '⌃⌥N', waiting: 2 }));
  assert.equal(idle.label, 'Voice note');
  assert.match(idle.hint, /Hold ⌃⌥N anywhere · 2 waiting for the bridge$/);
  assert.equal(normalizeNote({ state: 'shouting', waiting: -3 }).state, 'idle');
});

test('every state the shell pushes is known; a press while it records sends it', () => {
  // VoiceNoteSnapshot.Phase as the shell names it.
  assert.deepEqual(NOTE_STATES, ['idle', 'recording', 'sending', 'sent', 'queued', 'discarded', 'failed']);
  const pushed = normalizeNote({ state: 'recording', held: true, line: 'Recording…', detail: '', shortcut: '⌃⌥N', waiting: 1,
    startedAt: 1_000_000, offer: '' });
  assert.equal(pushed.held, true);
  assert.equal(pushed.waiting, 1);
  assert.equal(quickAction(pushed, 1_000_000).label, 'Send note 0:00');
  assert.equal(elapsed(normalizeNote({ state: 'idle' })), '', 'no time without a start');
  for (const state of ['sent', 'queued', 'discarded', 'failed']) {
    assert.deepEqual([quickAction(normalizeNote({ state })).label, quickAction(normalizeNote({ state })).recording], ['Voice note', false], state);
  }
  assert.doesNotMatch(quickAction(normalizeNote({ state: 'idle' })).hint, /Hold/, 'no shortcut, no “Hold”');
});

