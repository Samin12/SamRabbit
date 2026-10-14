// The window's agent inbox rules (web/inbox.js): decoding, order, "needs you", sections and filters, answers,
// optimistic actions and the keys, against the Agent Dock's fixtures (dev/samples/inbox.json).
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import {
  InboxStore, actionInfo, agentLabel, answersOnTap, buildAnswers, buildSections, failureNote, filterCounts, keyAction,
  keyName, keyRow, needsYou, normalizeDetail, normalizeInbox, normalizeItem, optimisticItem, recommendedOption,
  resolveChoice, rowIds, shownCounts, sortItems,
} from '../web/inbox.js';

const fixture = JSON.parse(readFileSync(new URL('../dev/samples/inbox.json', import.meta.url), 'utf8'));
const inbox = () => normalizeInbox(fixture.inbox);
const byId = (id) => inbox().items.find((item) => item.id === id);

test('items decode forgivingly: odd fields take their defaults, an unknown status is idle, no id is no item', () => {
  assert.equal(normalizeItem({ title: 'no id' }), null);
  const item = normalizeItem({ id: 'codex:abc', status: 'pondering', title: '  Two\n lines  ', can: ['open', 3], progress: 'half' });
  assert.equal(item.status, 'idle');
  assert.equal(item.source, 'codex');
  assert.equal(item.title, 'Two lines');
  assert.deepEqual(item.can, ['open']);
  assert.equal(item.progress, null);
  // An approval without its choices can still be answered.
  const bare = normalizeItem({ id: 't3:x', pending: { approvals: [{ requestId: 'r1' }] } });
  assert.deepEqual(bare.pending.approvals[0].options.map((o) => o.decision), ['accept', 'decline']);
});

test('the contract order: approvals, questions, errors, unread finishes, working, then the rest', () => {
  const statuses = inbox().items.map((item) => (item.status === 'done' && item.unread ? 'done-unread' : item.status));
  const rank = { 'needs-approval': 0, 'needs-input': 1, error: 2, 'done-unread': 3, working: 4 };
  const ranks = statuses.map((status) => rank[status] ?? 5);
  assert.deepEqual(ranks, [...ranks].sort((a, b) => a - b));
  const shuffled = sortItems([...inbox().items].reverse());
  assert.deepEqual(shuffled.map((i) => i.id), inbox().items.map((i) => i.id));
});

test('"needs you" is approvals, questions, failures and finished-unseen', () => {
  assert.equal(needsYou(byId('t3:th_pairing_redirect')), true);
  assert.equal(needsYou(byId('t3:th_waitlist_db')), true);
  assert.equal(needsYou(byId('t3:th_watch_previews')), true);
  assert.equal(needsYou(byId('t3:th_release_notes')), true);
  assert.equal(needsYou(byId('t3:th_readme_shots')), false, 'done and seen');
  assert.equal(needsYou(byId('t3:th_snapshot_cache')), false, 'working');
});

test('Tasks sections: Needs you, Working (agents only), Recent; the source filter leaves chats out', () => {
  const all = buildSections(inbox().items);
  assert.deepEqual(all.map((s) => s.kind), ['needsYou', 'working', 'recent']);
  assert.equal(all[0].items.length, 6);
  assert.ok(all[1].items.every((i) => i.status === 'working' && i.source !== 'samrabbit'));
  assert.ok(all[2].items.some((i) => i.source === 'samrabbit'), 'chats under Recent');
  const claude = buildSections(inbox().items, 'claude');
  assert.ok(claude.every((section) => section.items.every((i) => i.source === 'claude')));
  assert.deepEqual(filterCounts(inbox().items), { all: 6, t3: 4, claude: 1, codex: 1 });
  // J/K walk the rows top to bottom.
  assert.deepEqual(rowIds(all), all.flatMap((s) => s.items.map((i) => i.id)));
});

test('the recommended option is accept, else the first that is not a refusal', () => {
  const approval = byId('t3:th_pairing_redirect').pending.approvals[0];
  assert.equal(recommendedOption(approval).label, 'Run it');
  const noAccept = { options: [{ decision: 'decline', label: 'No' }, { decision: 'acceptForSession', label: 'Always' }] };
  assert.equal(recommendedOption(noAccept).decision, 'acceptForSession');
  assert.equal(agentLabel(byId('t3:th_waitlist_db')), 'Codex');
  assert.equal(agentLabel(byId('claude:5d0c6f2e-1a47-4f7e-9a51-3c2b1e0d9f88')), 'Claude');
});

test('answers: one string per question, a list for multi-select, typed answers win; incomplete is null', () => {
  const request = byId('t3:th_waitlist_db').pending.inputs[0];
  assert.equal(answersOnTap(request), false, 'typing is allowed, so it needs Send');
  assert.equal(buildAnswers(request, {}, {}), null);
  assert.deepEqual(buildAnswers(request, { db: ['Supabase'] }, {}), { db: 'Supabase' });
  assert.deepEqual(buildAnswers(request, { db: ['Supabase'] }, { db: 'DynamoDB' }), { db: 'DynamoDB' });
  const multi = { requestId: 'r', questions: [{ id: 'q', options: ['a', 'b'], allowCustom: false, multiSelect: true }] };
  assert.deepEqual(buildAnswers(multi, { q: ['b', 'a'] }), { q: ['a', 'b'] });
  const tap = { requestId: 'r', questions: [{ id: 'q', options: ['yes', 'no'], allowCustom: false, multiSelect: false }] };
  assert.equal(answersOnTap(tap), true);
});

test('optimistic results: approve and answer continue the work, reply sends, seen clears unread', () => {
  const item = byId('t3:th_pairing_redirect');
  const approved = optimisticItem(item, 'approve', { requestId: 'req_run_tests', decision: 'accept' });
  assert.equal(approved.status, 'working');
  assert.equal(approved.statusLabel, 'Approved · continuing');
  assert.equal(approved.pending.approvals.length, 0);
  assert.equal(item.pending.approvals.length, 1, 'the original is untouched');
  assert.equal(optimisticItem(item, 'approve', { requestId: 'req_run_tests', decision: 'decline' }).statusLabel, 'Declined · continuing');
  assert.equal(optimisticItem(item, 'seen').unread, false);
  assert.equal(optimisticItem(item, 'open'), null);
});

test('the store shows an optimistic item until a newer inbox, rolls back on failure, keeps new tasks on their way', () => {
  const store = new InboxStore();
  store.apply(fixture.inbox, 1000);
  const item = store.item('t3:th_pairing_redirect');
  store.overlay(optimisticItem(item, 'seen'), 1000);
  assert.equal(store.item(item.id).unread, false);
  store.rollback(item.id);
  assert.equal(store.item(item.id).unread, true);
  store.overlay(optimisticItem(item, 'seen'), 1000);
  store.settle(item.id);
  store.apply(fixture.inbox, 2000);
  assert.equal(store.item(item.id).unread, false, 'same revision: still waiting for the bridge');
  store.apply({ ...fixture.inbox, revision: 2 }, 3000);
  assert.equal(store.item(item.id).unread, true, 'a newer inbox wins');

  const placeholder = store.addPlaceholder({ text: 'Write the changelog', project: 'SamRabbit', agent: 'claude' }, 4000);
  assert.equal(store.item(placeholder).status, 'working');
  store.resolvePlaceholder(placeholder, 't3:th_new');
  assert.equal(store.item('t3:th_new').title, 'Write the changelog');
  assert.equal(store.tick(4000 + 46_000), true, 'gone after 45 s');
  assert.equal(store.item('t3:th_new'), null);
});

test('counts come from the rows on screen, plus what lies past the 60-item cap', () => {
  const items = inbox().items;
  assert.deepEqual(shownCounts(inbox(), items), { needsYou: 6, working: 4 });
  // The bridge counts a chat streaming a reply as working; the list doesn't, but only the excess is added.
  const capped = { ...inbox(), counts: { needsYou: 9, working: 7, total: 80 } };
  assert.deepEqual(shownCounts(capped, items), { needsYou: 9, working: 6 });
});

test('what a failed action says, and what a done one says', () => {
  assert.equal(failureNote({ status: 409, code: 'session_live' }).offersOpen, true);
  assert.match(failureNote({ status: 0 }).text, /isn’t answering/);
  assert.match(failureNote({ status: 404 }).text, /gone/);
  assert.equal(actionInfo('open', { how: 'terminal' }), 'Opened in Terminal.');
  assert.equal(actionInfo('approve', {}), null);
});

test('targets: what was picked when it still exists, else the default; the model belongs to the agent', () => {
  const targets = fixture.targets;
  assert.deepEqual(resolveChoice(targets, {}), {
    projectId: targets.default.projectId, agent: targets.default.agent, model: targets.default.model,
  });
  const codex = resolveChoice(targets, { agent: 'codex', model: 'claude-opus-5-5' });
  assert.equal(codex.agent, 'codex');
  assert.ok(targets.agents.find((a) => a.id === 'codex').models.some((m) => m.id === codex.model));
  assert.equal(resolveChoice(targets, { projectId: 'gone' }).projectId, targets.default.projectId);
  assert.deepEqual(resolveChoice(null, {}), { projectId: null, agent: null, model: null });
});

test('keys: J/K move, ↩ opens, E approves the selected approval, R replies, N composes, Esc steps back', () => {
  const rows = inbox().items.map(keyRow);
  const first = rows[0].id;
  assert.deepEqual(keyAction('down', rows, null), { type: 'select', id: first });
  assert.deepEqual(keyAction('down', rows, first), { type: 'select', id: rows[1].id });
  assert.deepEqual(keyAction('up', rows, first), { type: 'select', id: first });
  assert.deepEqual(keyAction('approve', rows, first), { type: 'approve', id: first, requestId: 'req_run_tests', decision: 'accept' });
  assert.deepEqual(keyAction('approve', rows, null), { type: 'none' }, 'nothing approves what is not on screen');
  assert.deepEqual(keyAction('approve', rows, first, { composing: true }), { type: 'none' });
  assert.deepEqual(keyAction('enter', rows, first), { type: 'open', id: first });
  assert.deepEqual(keyAction('reply', rows, first), { type: 'reply', id: first });
  const claude = rows.find((r) => r.id.startsWith('claude:'));
  assert.equal(claude.approval, null, 'a terminal session is answered in the terminal');
  assert.deepEqual(keyAction('escape', rows, first, { composing: true }), { type: 'closeCompose' });
  assert.deepEqual(keyAction('escape', rows, first), { type: 'deselect' });
  assert.equal(keyName({ key: 'j' }), 'down');
  assert.equal(keyName({ key: 'E' }), 'approve');
  assert.equal(keyName({ key: 'n', metaKey: true }), null, '⌘N is the menu’s');
});

test('item details keep the last 12 messages with text', () => {
  const messages = Array.from({ length: 15 }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', text: `m${i}`, at: 1_790_000_000 + i }));
  messages.push({ role: 'assistant', text: '   ' });
  const detail = normalizeDetail({ item: fixture.inbox.items[0], messages });
  assert.equal(detail.messages.length, 12);
  assert.equal(detail.messages.at(-1).text, 'm14');
  assert.equal(detail.item.id, fixture.inbox.items[0].id);
});
