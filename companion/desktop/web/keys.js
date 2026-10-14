// The window's own ⌘ shortcuts (its menus show the same): ⌘1–⌘5 the views, ⌘K search (⌘F in Chats too), ⌘N a new
// task, ⌘, Settings, and ⌘Z outside a text field: the undo of a dismissal while its toast shows. ⌘ only: ⌃N, ⌃K and the other ⌃ keys belong to the text fields (Cocoa's next line, kill line …).
// Pure (tests/keys.test.mjs).

/**
 * `{type: 'view', index}` (0–4), `{type: 'search'}`, `{type: 'newTask'}`, `{type: 'settings'}`, `{type: 'undo'}` (not
 * while typing: a field keeps its own ⌘Z), or null.
 */
export function windowShortcut(event, current = null, { typing = false } = {}) {
  if (!event || !event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return null;
  const key = String(event.key || '').toLowerCase();
  if (key === 'z') return typing ? null : { type: 'undo' };
  if (/^[1-5]$/.test(key)) return { type: 'view', index: Number(key) - 1 };
  if (key === 'k' || (key === 'f' && current === 'chats')) return { type: 'search' };
  if (key === 'n') return { type: 'newTask' };
  if (key === ',') return { type: 'settings' };
  return null;
}
