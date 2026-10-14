// What Home and Settings say about the R1, paired devices and the ChatGPT login (web/status.js), and the window's
// live voice transcript built from MacVoice's snapshots (web/voice.js).
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  assistantLine, chatgptStatus, deviceLine, deviceRows, dockSwitch, greeting, groupDevices, headline, nextLine, r1Status,
} from '../web/status.js';
import { MAX_TURNS, VoiceTranscript, continuation, idleCaption, isActive, normalizeVoice, voiceLabel } from '../web/voice.js';

const MIN = 60_000;
const NOW = Date.UTC(2026, 9, 14, 18, 0);
const iso = (ms) => new Date(ms).toISOString();

test('the greeting and the headline', () => {
  assert.equal(greeting(new Date(2026, 9, 14, 9).getTime()), 'Good morning');
  assert.equal(greeting(new Date(2026, 9, 14, 15).getTime()), 'Good afternoon');
  assert.equal(greeting(new Date(2026, 9, 14, 2).getTime()), 'Good evening');
  assert.equal(headline({ needsYou: 0, working: 0 }, null, NOW), 'Nothing needs you');
  assert.equal(headline({ needsYou: 1, working: 2 }, null, NOW), '1 needs you · 2 working');
  const next = { title: 'Standup', start: NOW + 30 * MIN, allDay: false };
  assert.match(headline({ needsYou: 3, working: 0 }, next, NOW), /^3 need you · Next: Standup at /);
  assert.equal(headline({ needsYou: 0, working: 0 }, { title: 'Holiday', allDay: true, start: NOW - MIN }, NOW), 'Nothing needs you · Today: Holiday');
});

test('the headline says the day of an event that isn’t today (the agenda is a week long)', () => {
  const at = (day, hour, minute = 0) => new Date(2026, 9, day, hour, minute).getTime();  // October 2026, local time
  const event = (title, start, hours = 1, allDay = false) => ({ title, start, end: start + hours * 3_600_000, allDay });
  const wednesday9pm = at(14, 21);
  const standup = nextLine(event('Standup', at(15, 9, 30)), wednesday9pm);
  assert.match(standup, /^Next: Standup tomorrow at 9:30\sAM$/);
  const thursday6pm = at(15, 18);
  assert.match(nextLine(event('Offsite', at(19, 9)), thursday6pm), /^Next: Offsite Monday at 9:00\sAM$/);
  assert.match(nextLine(event('Review', at(15, 19)), thursday6pm), /^Next: Review at 7:00\sPM$/, 'today: no day');
  assert.equal(nextLine(event('Focus', at(15, 17, 30)), thursday6pm), 'Next: Focus now');
  assert.equal(nextLine(event('Holiday', at(15, 0), 24, true), thursday6pm), 'Today: Holiday');
  assert.equal(nextLine(event('Trip', at(14, 0), 48, true), thursday6pm), 'Today: Trip', 'began yesterday, covers today');
  assert.equal(nextLine(event('Offsite', at(16, 0), 24, true), thursday6pm), 'Tomorrow: Offsite');
  assert.equal(nextLine(event('Offsite', at(19, 0), 24, true), thursday6pm), 'Monday: Offsite');
  assert.match(headline({ needsYou: 0, working: 0 }, event('Standup', at(15, 9, 30)), wednesday9pm),
    /^Nothing needs you · Next: Standup tomorrow at 9:30\sAM$/);
});

test('the dock switch says what the dock really does (on, hidden for now, off) and how to bring it back', () => {
  const shortcuts = [{ id: 'talk', keys: '⌃⌥Space' }, { id: 'compose', keys: '⌃⌥K', problem: null }];
  assert.deepEqual(dockSwitch({ enabled: true, turnedOn: true }, shortcuts),
    { on: true, line: 'On: it steps aside while you are in this window.' });
  assert.deepEqual(dockSwitch({ enabled: false, turnedOn: true }, shortcuts),
    { on: false, line: 'Hidden for now. Turn it on or press ⌃⌥K to bring it back.' });
  assert.deepEqual(dockSwitch({ enabled: false, turnedOn: false }, shortcuts),
    { on: false, line: 'Off until you turn it on here or press ⌃⌥K.' });
  // The dock's show / hide key when it has one; a key another app took isn't offered.
  const withShowHide = shortcuts.concat({ id: 'showHide', keys: '⌃⌥D', problem: null });
  assert.equal(dockSwitch({ enabled: false, turnedOn: false }, withShowHide).line, 'Off until you turn it on here or press ⌃⌥D.');
  const taken = [{ id: 'compose', keys: '⌃⌥K', problem: 'Not available — taken by another app' }];
  assert.equal(dockSwitch({ enabled: false, turnedOn: false }, taken).line, 'Off until you turn it on here.');
  assert.deepEqual(dockSwitch(null, shortcuts, false), { on: true, line: 'Works in the SamRabbit app.' });
});

test('the R1: live, active, seen a while ago, never; the battery only when the bridge knows it', () => {
  assert.deepEqual(r1Status({ r1: { live: true, liveTitle: 'Coding hours' } }, NOW).line, 'Live · Coding hours');
  assert.equal(r1Status({ r1: { online: true, lastSeenAt: iso(NOW - 30_000) } }, NOW).line, 'Active now');
  const away = r1Status({ r1: { online: false, lastSeenAt: iso(NOW - 2 * 3600_000) } }, NOW);
  assert.equal(away.tone, 'idle');
  assert.equal(away.line, 'Last seen 2 hr ago');
  assert.equal(r1Status({}, NOW).line, 'Not seen yet');
  assert.equal(r1Status({ r1: { battery: 82.4 } }, NOW).battery, 82);
  assert.equal(r1Status({ r1: {} }, NOW).battery, null);
});

test('paired devices: each phone followed by its watch, strays last', () => {
  const devices = [
    { deviceId: 'w1', name: 'Watch', platform: 'watchos', parentId: 'p1', lastSeenAt: iso(NOW - 5 * MIN) },
    { deviceId: 'p1', name: 'iPhone', platform: 'ios', createdAt: iso(NOW - 3 * 86_400_000), lastSeenAt: iso(NOW - MIN) },
    { deviceId: 'w2', name: 'Old watch', platform: 'watchos', parentId: 'gone' },
    { name: 'no id', platform: 'ios' },
  ];
  const grouped = groupDevices(devices);
  assert.deepEqual(grouped.map((d) => [d.deviceId, d.child]), [['p1', false], ['w1', true], ['w2', false]]);
  assert.equal(grouped[1].parentName, 'iPhone');
  assert.equal(deviceLine(grouped[1], NOW), 'Through iPhone · Seen 5 min ago');
  assert.match(deviceLine(grouped[0], NOW), /^Paired .* · Active now$/);
  const rows = deviceRows({ r1: {}, mac: { name: 'Mac Studio' } }, devices, NOW);
  assert.deepEqual(rows.map((r) => r.kind), ['r1', 'iphone', 'watch', 'watch', 'mac']);
});

test('ChatGPT: connected (through the Codex login), waiting, signed out', () => {
  const codex = chatgptStatus({ connected: true, plan: 'pro', email: 'sam@example.com', source: 'codex' });
  assert.equal(codex.detail, 'ChatGPT Pro · sam@example.com');
  assert.equal(codex.note, 'Using your Codex login on this Mac');
  assert.equal(chatgptStatus({ connected: true, plan: 'plus' }).note, '');
  assert.equal(chatgptStatus({ connected: false, login: { state: 'waiting' } }).title, 'Waiting for you to sign in');
  assert.equal(chatgptStatus({ connected: false, reason: 'reconnect_required' }).tone, 'warn');
  assert.equal(chatgptStatus(null).title, 'Checking…');
  assert.equal(assistantLine({ assistant: { available: true, brain: 'realtime' } }), 'Realtime voice (ChatGPT)');
  assert.equal(assistantLine({ assistant: { available: true, brain: 'claude' } }), 'Claude voice');
  assert.equal(assistantLine({}), null);
});

test('voice snapshots: forgiving, the bar\'s label, the line before anything is said', () => {
  const idle = normalizeVoice(null);
  assert.equal(idle.state, 'idle');
  assert.equal(isActive(idle), false);
  const odd = normalizeVoice({ state: 'yelling', level: 7, micMuted: 'yes', wakeEnabled: undefined });
  assert.equal(odd.state, 'idle');
  assert.equal(odd.level, 1);
  assert.equal(odd.micMuted, false);
  assert.equal(odd.wakeEnabled, true);
  assert.deepEqual(voiceLabel(normalizeVoice({ state: 'listening', micMuted: true })), { label: 'Muted', tone: 'muted' });
  assert.deepEqual(voiceLabel(normalizeVoice({ state: 'speaking' })), { label: 'Speaking', tone: 'active' });
  assert.equal(idleCaption(normalizeVoice({ state: 'listening' })), 'Go ahead, I’m listening.');
});

test('the transcript: your lines from heard, the reply streams, a new caption is a new turn', () => {
  const t = new VoiceTranscript();
  const push = (voice) => t.apply({ conversationId: 'mac-1', ...voice }, 1000);
  assert.equal(push({ state: 'starting' }), true);
  push({ state: 'listening' });
  push({ state: 'thinking', heard: 'What’s on my calendar?' });
  push({ state: 'speaking', heard: 'What’s on my calendar?', caption: 'You have the 1:1' });
  push({ state: 'speaking', heard: 'What’s on my calendar?', caption: 'You have the 1:1 with Priya at 2.' });
  assert.deepEqual(t.turns.map((x) => [x.role, x.text, x.final]), [
    ['user', 'What’s on my calendar?', true],
    ['assistant', 'You have the 1:1 with Priya at 2.', false],
  ]);
  push({ state: 'listening', heard: 'What’s on my calendar?', caption: 'You have the 1:1 with Priya at 2.' });
  push({ state: 'thinking', heard: 'Block time before it.', caption: 'You have the 1:1 with Priya at 2.' });
  push({ state: 'speaking', heard: 'Block time before it.', caption: 'Done.' });
  assert.equal(t.turns.length, 4);
  assert.equal(t.turns[1].final, true, 'a new line of yours closes the reply');
  assert.equal(t.conversationId, 'mac-1');
  // An announcement: the caption empties, then another reply starts.
  push({ state: 'listening', heard: 'Block time before it.', caption: '' });
  push({ state: 'speaking', heard: 'Block time before it.', caption: 'Heads up: the build finished.' });
  assert.equal(t.turns.length, 5);
  // The end: it lingers for a while, then the panel goes.
  t.apply({ state: 'idle', heard: 'Block time before it.', caption: 'Heads up: the build finished.' }, 2000);
  assert.equal(t.active, false);
  assert.equal(t.visible(2000 + 5000, 12_000), true);
  assert.equal(t.visible(2000 + 13_000, 12_000), false);
  // The next conversation starts clean.
  t.apply({ state: 'starting' }, 30_000);
  assert.equal(t.turns.length, 0);
});

test('the same words twice are two lines of yours (each exchange has its id); new words in one exchange correct it', () => {
  const t = new VoiceTranscript();
  const push = (voice) => t.apply({ conversationId: 'mac-2', ...voice });
  push({ state: 'listening', heard: '', caption: '' });
  push({ state: 'thinking', heard: 'Yes.', heardId: 'turn-1', caption: '' });
  push({ state: 'speaking', heard: 'Yes.', heardId: 'turn-1', caption: 'Blocked 30 minutes. Should I also move the gym?' });
  push({ state: 'listening', heard: 'Yes.', heardId: 'turn-1', caption: '' });
  push({ state: 'thinking', heard: 'Yes.', heardId: 'turn-2', caption: '' });
  push({ state: 'speaking', heard: 'Yes.', heardId: 'turn-2', caption: 'Moved the gym to 7.' });
  assert.deepEqual(t.turns.map((x) => [x.role, x.text]), [
    ['user', 'Yes.'], ['assistant', 'Blocked 30 minutes. Should I also move the gym?'],
    ['user', 'Yes.'], ['assistant', 'Moved the gym to 7.'],
  ]);
  push({ state: 'speaking', heard: 'Yes, please.', heardId: 'turn-2', caption: 'Moved the gym to 7.' });
  assert.equal(t.turns.length, 4, 'a corrected transcript of the same exchange is no new line');
  assert.equal(t.turns[2].text, 'Yes, please.');
  assert.equal(new Set(t.turns.map((x) => x.id)).size, 4, 'every turn has its own id');
  // A shell without ids: new words make a new line, the same words don't.
  const old = new VoiceTranscript();
  old.apply({ state: 'thinking', heard: 'Yes.' });
  old.apply({ state: 'thinking', heard: 'Yes.' });
  old.apply({ state: 'thinking', heard: 'No.' });
  assert.deepEqual(old.turns.map((x) => x.text), ['Yes.', 'No.']);
});

test('a conversation that fails to start shows its problem; the transcript keeps at most 40 turns', () => {
  const t = new VoiceTranscript();
  t.apply({ state: 'error', error: 'The microphone is off in this build' }, 1000);
  assert.equal(t.error, 'The microphone is off in this build');
  assert.equal(t.visible(1500), true);
  const long = new VoiceTranscript();
  long.apply({ state: 'listening' });
  for (let i = 0; i < 30; i += 1) {
    long.apply({ state: 'thinking', heard: `question ${i}`, caption: '' });
    long.apply({ state: 'speaking', heard: `question ${i}`, caption: `answer ${i}` });
  }
  assert.equal(long.turns.length, MAX_TURNS);
  assert.equal(long.turns.at(-1).text, 'answer 29');
});

test('a streamed caption continues when it grows from the text before (a rewritten last word allowed)', () => {
  assert.equal(continuation('', 'Hello'), true);
  assert.equal(continuation('Next up is the', 'Next up is the design review'), true);
  assert.equal(continuation('Next up is the desing review at', 'Next up is the design review at three'), true);
  assert.equal(continuation('Next up is the design review.', 'Heads up: the build finished.'), false);
});
