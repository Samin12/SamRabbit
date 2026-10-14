// What the window reads from the bridge and when (web/resource.js): a Resource with a Presence reads only while the
// window is on screen, remembers what was asked meanwhile, and reads once when the window is back.
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { Presence, Resource } from '../web/resource.js';

const sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

/** A document whose visibility a test switches (WebKit's visibilitychange). */
function fakeDocument(visibilityState = 'visible') {
  const listeners = new Set();
  return {
    visibilityState,
    addEventListener(type, listener) {
      if (type === 'visibilitychange') listeners.add(listener);
    },
    set(state) {
      this.visibilityState = state;
      for (const listener of listeners) listener();
    },
  };
}

function counted() {
  const fetcher = async () => {
    fetcher.calls += 1;
    return { n: fetcher.calls };
  };
  fetcher.calls = 0;
  return fetcher;
}

test('presence: the page visible and the shell not saying otherwise; listeners hear changes only', () => {
  const doc = fakeDocument('visible');
  let shell = true;
  const presence = new Presence({ doc, shell: () => shell });
  const heard = [];
  presence.on((watched) => heard.push(watched));
  assert.equal(presence.watched, true);
  doc.set('hidden');
  doc.set('hidden');
  doc.set('visible');
  shell = false;
  presence.update();
  presence.update();
  assert.deepEqual(heard, [false, true, false]);
  assert.equal(new Presence({ doc: null }).watched, true, 'no document (tests): watched');
});

test('a resource without a presence reads whenever asked (Settings opened, a refresh)', async () => {
  const fetcher = counted();
  const resource = new Resource(fetcher);
  await resource.refresh();
  await resource.fresh(60_000);
  assert.equal(fetcher.calls, 1, 'fresh() reuses a young value');
  await resource.refresh();
  assert.equal(fetcher.calls, 2);
});

test('hidden at launch (--login): nothing is read until the window shows, then once', async () => {
  const doc = fakeDocument('hidden');
  const presence = new Presence({ doc });
  const fetcher = counted();
  const resource = new Resource(fetcher, { every: 15, presence });
  await resource.refresh();
  resource.start();
  await resource.fresh(1000);
  await sleep(60);
  assert.equal(fetcher.calls, 0, 'no read and no timer while hidden');
  assert.equal(resource.stale, true);
  doc.set('visible');
  await sleep(0);
  assert.equal(fetcher.calls, 1, 'one read when it shows');
  await sleep(50);
  assert.ok(fetcher.calls >= 2, 'the timer runs while it is seen');
  resource.stop();
});

test('hidden after a while: the timer stops, a refresh waits, the window back reads once', async () => {
  const doc = fakeDocument('visible');
  const presence = new Presence({ doc });
  const fetcher = counted();
  const resource = new Resource(fetcher, { every: 60_000, presence });
  await resource.refresh();
  resource.start();
  assert.equal(fetcher.calls, 1);
  doc.set('hidden');
  await resource.refresh();
  await resource.refresh();
  assert.equal(fetcher.calls, 1, 'asked twice while hidden: nothing read');
  doc.set('visible');
  await sleep(0);
  await resource.loading;
  assert.equal(fetcher.calls, 2, 'one read when back');
  doc.set('hidden');
  doc.set('visible');
  await sleep(0);
  assert.equal(fetcher.calls, 2, 'back again soon, nothing asked meanwhile, value young: no read');
  resource.stop();
});

test('a periodic resource whose value got old while hidden reads when the window is back', async () => {
  const doc = fakeDocument('visible');
  const presence = new Presence({ doc });
  const fetcher = counted();
  const resource = new Resource(fetcher, { every: 30, presence });
  await resource.refresh();
  resource.start();
  doc.set('hidden');
  const calls = fetcher.calls;
  await sleep(80);
  assert.equal(fetcher.calls, calls, 'no timer reads while hidden');
  doc.set('visible');
  await sleep(0);
  assert.equal(fetcher.calls, calls + 1, 'older than `every`: read at once');
  resource.stop();
  await sleep(50);
  assert.equal(fetcher.calls, calls + 1, 'stopped: no more reads');
});
