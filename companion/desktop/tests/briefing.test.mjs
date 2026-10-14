// The morning brief as the window reads it (web/briefing.js) and Home's voice note button (web/note.js): the fixture
// (dev/samples/briefing.json), the other shapes a bridge may send, before noon only, the verbs and their results,
// Gmail links in the right account, remind choices; the note's states as the shell pushes them.
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import {
  actResult, findItem, isHandled, isMorning, isWebLink, isoLocal, localDay, normalizeBriefing, openCount, primaryActions,
  remindChoices, resultingState, sectionKind, shownSections, skippedLine, stateLine, verb, verbLabel, VERBS, withAccount,
  withItemState,
} from '../web/briefing.js';
import { elapsed, normalizeNote, quickAction } from '../web/note.js';

const sample = JSON.parse(readFileSync(new URL('../dev/samples/briefing.json', import.meta.url)));
// Local times on the sample's day (the tests run in whatever zone the Mac is in; the rules use local days).
const at = (hour, minute = 0, day = 0) => new Date(2026, 9, 14 + day, hour, minute).getTime();

function todays() {
  const brief = normalizeBriefing(sample);
  return { ...brief, date: localDay(at(8)) };
}

test('reads the fixture: sections in order, items, verbs, accounts', () => {
  const brief = normalizeBriefing(sample);
  assert.equal(brief.available, true);
  assert.equal(brief.status, 'ready');
  assert.equal(brief.revision, 3);
  assert.match(brief.headline, /^3 things need you/);
  assert.deepEqual(Object.keys(brief.sections), ['doFirst', 'today', 'agents', 'fyi']);
  const [dana, stripe, clash] = brief.sections.doFirst;
  assert.deepEqual(dana.actions.map((a) => a.type), ['draft_reply', 'remind']);
  assert.equal(dana.account, 'business');
  assert.equal(dana.accountEmail, 'sam@example.com');
  assert.equal(stripe.actions[0].type, 'open');
  assert.equal(clash.conflict, true);
  assert.equal(brief.sections.agents[0].inboxItemId, 't3:th_pairing_redirect');
  assert.equal(brief.sections.today.length, 4);
  assert.equal(brief.sections.today[0].startsAt, Date.parse('2026-10-14T09:30:00-04:00'));
  assert.equal(openCount(brief), 4, '3 to do first and 1 agent');
  assert.equal(skippedLine(brief), 'Read 105 emails · skipped 182 promotions and newsletters');
});

test('reads other shapes: keyed sections, the R1 wrapper, one flat list; nothing usable is null', () => {
  const keyed = normalizeBriefing({
    available: true, date: '2026-10-14', headline: 'Two',
    doFirst: [{ id: 'a', title: 'Reply to Ana', actions: ['draft', 'remind_me'] }],
    today: [{ id: 'e', title: 'Standup', startsAt: '2026-10-14T09:30:00-04:00' }],
  });
  assert.deepEqual(keyed.sections.doFirst[0].actions.map((a) => [a.type, a.label]), [['draft_reply', 'Draft reply'], ['remind', 'Remind me']]);
  assert.equal(keyed.sections.today[0].kind, 'event');
  const wrapped = normalizeBriefing({ configured: true, available: true, status: 'ready',
    briefing: { revision: 2, sections: [{ id: 'do_first', items: [{ id: 'x', title: 'T' }] }] } });
  assert.equal(wrapped.status, 'ready');
  assert.deepEqual(wrapped.sections.doFirst.map((i) => i.id), ['x']);
  const flat = normalizeBriefing({ items: [{ id: '1', section: 'fyi', title: 'A' }, { id: '2', section: 'Do first', title: 'B' }] });
  assert.deepEqual([flat.sections.doFirst.length, flat.sections.fyi.length], [1, 1]);
  assert.equal(flat.available, true);
  const off = normalizeBriefing({ available: false, status: 'off', reason: 'gmail_not_connected' });
  assert.equal(off.available, false);
  assert.equal(off.reason, 'gmail_not_connected');
  assert.equal(normalizeBriefing([]), null);
  assert.equal(normalizeBriefing(null), null);
});

test('forgives odd fields: no id dropped, repeats once, caps, aliases, an address is the mailbox', () => {
  const brief = normalizeBriefing({ sections: [{ kind: 'doFirst', items: [
    { id: 'a', title: '  Reply\n to   Ana ', account: 'sam@example.com',
      actions: [{ type: 'draft_reply' }, { type: 'draft_reply' }, { label: 'no type' }, { type: 'Make T3 Task', label: 'Task it' }, 'done', 'dismiss'] },
    { title: 'no id' }, { id: 'b', title: 'B' }, { id: 'c', title: 'C' }, { id: 'd', title: 'D' }, { id: 'a', title: 'again' },
  ] }] });
  const items = brief.sections.doFirst;
  assert.deepEqual(items.map((i) => i.id), ['a', 'b', 'c']);
  assert.equal(items[0].title, 'Reply to Ana');
  assert.deepEqual(items[0].actions.map((a) => a.type), ['draft_reply', 'make_task', 'done', 'dismiss']);
  assert.deepEqual(primaryActions(items[0]).map((a) => a.label), ['Draft reply', 'Task it']);
  assert.equal(items[0].account, null);
  assert.equal(items[0].accountEmail, 'sam@example.com');
  assert.equal(sectionKind('Do first'), 'doFirst');
  assert.equal(sectionKind('nonsense'), null);
});

test('Home shows it before noon, and only today’s', () => {
  const brief = todays();
  assert.equal(isMorning(brief, at(7, 5)), true);
  assert.equal(isMorning(brief, at(11, 59)), true);
  assert.equal(isMorning(brief, at(12, 0)), false, 'not from noon');
  assert.equal(isMorning(brief, at(8, 0, 1)), false, 'not yesterday’s');
  assert.equal(isMorning(brief, at(15, 0), { force: true }), true, 'dev shots at any hour');
  assert.equal(isMorning({ ...brief, available: false }, at(8)), false);
  assert.equal(isMorning(null, at(8)), false);
});

test('what shows: done and dismissed leave, drafted stays with what happened, past events leave', () => {
  let brief = todays();
  const [dana, stripe] = brief.sections.doFirst;
  brief = withItemState(withItemState(brief, dana.id, resultingState('draft_reply')), stripe.id, resultingState('done'));
  const shown = Object.fromEntries(shownSections(brief, Date.parse('2026-10-14T10:05:00-04:00')).map((s) => [s.kind, s.items]));
  assert.deepEqual(shown.doFirst.map((i) => i.id), [dana.id, brief.sections.doFirst[2].id]);
  assert.equal(isHandled(findItem(brief, dana.id)), true);
  assert.equal(stateLine('drafted'), 'Draft saved in Gmail · not sent');
  assert.equal(shown.today[0].title, 'Design review: Agent Dock and the Mac window', 'standup is over');
  assert.equal(openCount(brief), 2);
  assert.equal(todays().sections.doFirst[0].state, 'open', 'the original is untouched');
});

test('verbs, their labels and results', () => {
  assert.deepEqual(VERBS.map(verbLabel), ['Draft reply', 'Make task', 'Block time', 'Remind me', 'Done', 'Dismiss', 'Open']);
  assert.equal(verb('Remind-Me'), 'remind');
  assert.equal(verb('snooze'), 'remind');
  assert.equal(verb('agent_action'), 'agent_action');
  assert.deepEqual(['draft_reply', 'make_task', 'block_time', 'remind', 'done', 'dismiss', 'open'].map(resultingState),
    ['drafted', 'tasked', 'blocked', 'snoozed', 'done', 'dismissed', null]);
  assert.deepEqual(actResult({ ok: true, state: 'drafted', result: { draftId: 'r-1', url: 'https://mail.google.com/mail/u/0/#drafts/r-1' } }),
    { state: 'drafted', url: 'https://mail.google.com/mail/u/0/#drafts/r-1', itemId: null, draftId: 'r-1' });
  assert.deepEqual(actResult('nonsense'), { state: null, url: null, itemId: null, draftId: null });
});

test('Gmail links open in the item’s own account; only web links open', () => {
  const link = 'https://mail.google.com/mail/u/0/#inbox/18f2a9c3b7e4d001';
  assert.equal(withAccount(link, 'sam.personal@example.com'),
    'https://mail.google.com/mail/u/0/?authuser=sam.personal%40example.com#inbox/18f2a9c3b7e4d001');
  const set = 'https://mail.google.com/mail/u/0/?authuser=a%40b.c#inbox/1';
  assert.equal(withAccount(set, 'x@y.z'), set, 'the bridge’s own choice stays');
  assert.equal(withAccount('https://calendar.google.com/x', 'x@y.z'), 'https://calendar.google.com/x');
  assert.equal(withAccount(link, null), link);
  assert.equal(isWebLink(link), true);
  for (const bad of ['file:///etc/passwd', 'javascript:alert(1)', 't3code://thread/1', 'nonsense']) assert.equal(isWebLink(bad), false, bad);
});

test('remind choices are still ahead; times go up with their offset', () => {
  assert.deepEqual(remindChoices(at(8, 10)).map((c) => c.label), ['In 1 hour', '2 PM', 'Tonight 6 PM', 'Tomorrow 9 AM']);
  assert.equal(remindChoices(at(8, 10))[3].at, at(9, 0, 1));
  assert.deepEqual(remindChoices(at(13, 45)).map((c) => c.label), ['In 1 hour', 'Tonight 6 PM', 'Tomorrow 9 AM'], '2 PM is too close');
  const iso = isoLocal(at(14));
  assert.match(iso, /^2026-10-14T14:00:00[+-]\d\d:\d\d$/);
  assert.equal(Date.parse(iso), at(14));
});

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
