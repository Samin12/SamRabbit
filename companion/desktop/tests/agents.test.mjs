// The window's live inbox (web/agents.js) against a fake bridge API: optimistic actions and their rollback, replies,
// question answers, new tasks, targets; and the inbox long poll (web/api.js InboxPoller) and Resource.
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { AgentInbox } from '../web/agents.js';
import { ApiError, InboxPoller, itemPath } from '../web/api.js';
import { Resource } from '../web/resource.js';

const fixture = JSON.parse(readFileSync(new URL('../dev/samples/inbox.json', import.meta.url), 'utf8'));

function fakeApi({ fail = null, newTask = { itemId: 't3:th_new' } } = {}) {
  const calls = [];
  return {
    calls,
    async inbox() {
      return fixture.inbox;
    },
    async item(id) {
      calls.push(['item', id]);
      return { item: fixture.inbox.items.find((i) => i.id === id), messages: fixture.details[id] || [] };
    },
    async act(id, action, body) {
      calls.push(['act', id, action, body]);
      if (fail) throw fail;
      return action === 'open' ? { opened: true, how: 'terminal' } : { ok: true };
    },
    async targets() {
      calls.push(['targets']);
      return fixture.targets;
    },
    async newTask(body) {
      calls.push(['new', body]);
      if (fail) throw fail;
      return newTask;
    },
  };
}

function loaded(api) {
  const inbox = new AgentInbox(api, { poll: false, now: () => 1_000 });
  inbox.receive(fixture.inbox);
  return inbox;
}

test('approve shows at once, goes to the bridge, and stays until a newer inbox', async () => {
  const api = fakeApi();
  const inbox = loaded(api);
  const item = inbox.item('t3:th_pairing_redirect');
  const events = [];
  inbox.on((what) => events.push(what));
  const pending = inbox.approve(item, 'req_run_tests', 'accept');
  assert.equal(inbox.item(item.id).status, 'working', 'optimistic');
  assert.equal(inbox.busy.get(item.id), 'approve');
  await pending;
  assert.deepEqual(api.calls.at(-1), ['act', item.id, 'approve', { requestId: 'req_run_tests', decision: 'accept' }]);
  assert.equal(inbox.busy.has(item.id), false);
  assert.equal(inbox.item(item.id).status, 'working');
  assert.ok(events.length >= 2);
});

test('a refused action rolls back and says why; a live session offers Open', async () => {
  const api = fakeApi({ fail: new ApiError(409, 'session_live', 'HTTP 409') });
  const inbox = loaded(api);
  const item = inbox.item('t3:th_pairing_redirect');
  inbox.replyDrafts.set(item.id, 'Run it with --verbose');
  await inbox.reply(item);
  assert.equal(inbox.item(item.id).status, 'needs-approval', 'rolled back');
  assert.equal(inbox.notes.get(item.id).offersOpen, true);
  assert.equal(inbox.replyDrafts.get(item.id), 'Run it with --verbose', 'the draft comes back');
});

test('a reply shows in the conversation at once and clears the draft', async () => {
  const api = fakeApi();
  const inbox = loaded(api);
  const item = inbox.item('t3:th_pairing_redirect');
  inbox.watch(item.id);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const before = inbox.details.get(item.id).messages.length;
  inbox.replyDrafts.set(item.id, '  Yes, run them  ');
  const sent = inbox.reply(item);
  assert.equal(inbox.details.get(item.id).messages.length, before + 1);
  assert.equal(inbox.details.get(item.id).messages.at(-1).text, 'Yes, run them');
  assert.equal(inbox.replyDrafts.get(item.id), '');
  await sent;
  assert.deepEqual(api.calls.at(-1), ['act', item.id, 'reply', { text: 'Yes, run them' }]);
});

test('answers: picked options and typed text; a missing answer says so and sends nothing', async () => {
  const api = fakeApi();
  const inbox = loaded(api);
  const item = inbox.item('t3:th_waitlist_db');
  const request = item.pending.inputs[0];
  const question = request.questions[0];
  await inbox.answer(item, request);
  assert.equal(inbox.notes.get(item.id).text, 'Answer every question first.');
  assert.equal(api.calls.length, 0);
  inbox.toggleOption(item, question, 'Supabase');
  await inbox.answer(item, request);
  assert.deepEqual(api.calls.at(-1), ['act', item.id, 'answer', { requestId: 'req_db_choice', answers: { db: 'Supabase' } }]);
});

test('open says how it opened; seen and stop go to their routes', async () => {
  const api = fakeApi();
  const inbox = loaded(api);
  const claude = inbox.item('claude:5d0c6f2e-1a47-4f7e-9a51-3c2b1e0d9f88');
  const reply = await inbox.open(claude);
  assert.equal(reply.how, 'terminal');
  assert.equal(inbox.notes.get(claude.id).text, 'Opened in Terminal.');
  await inbox.markSeen(inbox.item('t3:th_release_notes'));
  await inbox.stopItem(inbox.item('t3:th_snapshot_cache'));
  assert.deepEqual(api.calls.slice(-2).map((c) => c[2]), ['seen', 'stop']);
});

test('a new task goes with the chosen project, agent and model, and shows under Working at once', async () => {
  const api = fakeApi();
  const inbox = loaded(api);
  await inbox.loadTargets();
  inbox.pick({ agent: 'codex', model: null });
  const pending = inbox.newTask('  Add a dark mode toggle  ', { projectId: 'proj_website' });
  assert.ok(inbox.items.some((i) => i.id.startsWith('pending:') && i.title === 'Add a dark mode toggle'));
  const id = await pending;
  assert.equal(id, 't3:th_new');
  const [, body] = api.calls.find((c) => c[0] === 'new');
  assert.equal(body.text, 'Add a dark mode toggle');
  assert.equal(body.projectId, 'proj_website');
  assert.equal(body.agent, 'codex');
  assert.ok(fixture.targets.agents.find((a) => a.id === 'codex').models.some((m) => m.id === body.model));
  assert.ok(inbox.item('t3:th_new'), 'the row keeps the new id until the inbox lists it');
  assert.equal(inbox.choiceLabel(), 'Codex · GPT-5.5 Codex');
});

test('a new task the bridge refuses keeps nothing on screen and says why', async () => {
  const api = fakeApi({ fail: new ApiError(409, 't3_not_connected', 'HTTP 409') });
  const inbox = loaded(api);
  assert.equal(await inbox.newTask('Ship it'), null);
  assert.equal(inbox.items.some((i) => i.id.startsWith('pending:')), false);
  assert.match(inbox.composeNote.text, /T3 Code isn’t connected/);
});

test('the inbox goes offline on errors and back online with the next answer', () => {
  const inbox = new AgentInbox(fakeApi(), { poll: false });
  inbox.failed(new ApiError(0, 'unreachable', 'down'));
  assert.equal(inbox.connection, 'offline');
  assert.equal(inbox.offlineStatus, 0);
  inbox.receive(fixture.inbox);
  assert.equal(inbox.connection, 'online');
  assert.equal(inbox.counts().needsYou, 6);
});

test('the long poll asks with the last revision, waits, and backs off on errors', async () => {
  const asked = [];
  const slept = [];
  let call = 0;
  const poller = new InboxPoller({
    fetchInbox: async (options) => {
      asked.push(options);
      call += 1;
      if (call === 2) throw new ApiError(503, 'busy', 'HTTP 503');
      if (call > 3) poller.stop();
      return { ...fixture.inbox, revision: 7 };
    },
    sleep: async (ms) => {
      slept.push(ms);
    },
    onInbox: () => {},
    onError: () => {},
  });
  poller.start();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(asked[0], { after: undefined, wait: 0, signal: asked[0].signal });
  assert.equal(asked[2].after, undefined, 'after an error it starts over');
  assert.equal(asked[3].after, 7);
  assert.equal(asked[3].wait, 25);
  assert.equal(slept[0], 1000, 'the first retry after a second');
  assert.equal(InboxPoller.backoff(0, 404), 30000, 'a bridge without the inbox is asked twice a minute at most');
});

test('item paths escape everything but the colon', () => {
  assert.equal(itemPath('t3:th_1'), '/v1/desktop/inbox/items/t3:th_1');
  assert.equal(itemPath('claude:a/b', 'reply'), '/v1/desktop/inbox/items/claude:a%2Fb/reply');
});

test('a Resource shares one read at a time and keeps the last value when a read fails', async () => {
  let reads = 0;
  let fail = false;
  const resource = new Resource(async () => {
    reads += 1;
    if (fail) throw new Error('down');
    return { n: reads };
  });
  await Promise.all([resource.refresh(), resource.refresh()]);
  assert.equal(reads, 1);
  assert.deepEqual(resource.value, { n: 1 });
  await resource.fresh(60_000);
  assert.equal(reads, 1, 'still fresh');
  fail = true;
  await resource.refresh();
  assert.deepEqual(resource.value, { n: 1 });
  assert.ok(resource.error);
});
