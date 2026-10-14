// The window's ⌘ shortcuts (web/keys.js): ⌘ only, so ⌃N / ⌃K keep their text-field meaning (next line, kill line).
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { windowShortcut } from '../web/keys.js';

const key = (k, mods = {}) => ({ key: k, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods });

test('⌘1–⌘5, ⌘K, ⌘F in Chats, ⌘N and ⌘,', () => {
  assert.deepEqual(windowShortcut(key('1', { metaKey: true })), { type: 'view', index: 0 });
  assert.deepEqual(windowShortcut(key('5', { metaKey: true })), { type: 'view', index: 4 });
  assert.equal(windowShortcut(key('6', { metaKey: true })), null);
  assert.deepEqual(windowShortcut(key('k', { metaKey: true })), { type: 'search' });
  assert.deepEqual(windowShortcut(key('f', { metaKey: true }), 'chats'), { type: 'search' });
  assert.equal(windowShortcut(key('f', { metaKey: true }), 'tasks'), null, '⌘F elsewhere is the page’s find');
  assert.deepEqual(windowShortcut(key('n', { metaKey: true })), { type: 'newTask' });
  assert.deepEqual(windowShortcut(key(',', { metaKey: true })), { type: 'settings' });
});

test('⌃ keys are the text fields’: ⌃N next line, ⌃K kill line, ⌃1 nothing', () => {
  for (const k of ['n', 'k', 'f', '1', ',']) {
    assert.equal(windowShortcut(key(k, { ctrlKey: true }), 'chats'), null, `⌃${k}`);
    assert.equal(windowShortcut(key(k, { ctrlKey: true, metaKey: true }), 'chats'), null, `⌃⌘${k}`);
  }
});

test('⌥ or ⇧ with ⌘ and plain keys are not the window’s', () => {
  assert.equal(windowShortcut(key('n', { metaKey: true, altKey: true })), null);
  assert.equal(windowShortcut(key('N', { metaKey: true, shiftKey: true })), null);
  assert.equal(windowShortcut(key('2', { metaKey: true, shiftKey: true })), null);
  assert.equal(windowShortcut(key('n')), null);
  assert.equal(windowShortcut(null), null);
});
