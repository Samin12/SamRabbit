// Shared bits of the window: toasts, sheets and popovers, the clipboard, links, and small controls (switches,
// segmented controls, buttons). Every piece of text goes through textContent (dom.js).

import { h } from './dom.js';
import { icon } from './icons.js';
import { nativeHandler, postNative } from './native.js';

const overlays = document.getElementById('overlay-root');
const toasts = document.getElementById('toast-root');

/**
 * The window drags by its 52 pt header strip (a native view over the web view, MainWindow.swift): the page reports
 * where its header controls are, so clicks there reach them. Call after anything in a `.titlebar` moved.
 */
export function reportDragExclusions() {
  if (!nativeHandler) return;
  const rects = [];
  for (const el of document.querySelectorAll('.titlebar button, .titlebar a, .titlebar input, .titlebar select, .titlebar [data-nodrag]')) {
    const box = el.getBoundingClientRect();
    if (box.width && box.height) rects.push([Math.round(box.left), Math.round(box.top), Math.round(box.width), Math.round(box.height)]);
  }
  const key = JSON.stringify(rects);
  if (key !== reportDragExclusions.last) {
    reportDragExclusions.last = key;
    postNative({ type: 'noDrag', rects });
  }
}

/** A short line at the bottom right, with an optional action button. Returns {close} (the toast goes at once). */
export function toast(text, { action = null, timeout = 3200, tone = '', icon: glyph = null } = {}) {
  const node = h('div', { class: `toast${tone ? ` tone-${tone}` : ''}`, role: 'status' },
    glyph ? icon(glyph, { size: 14 }) : null,
    h('span', { class: 'toast-text', text }),
    action ? h('button', {
      class: 'toast-action', type: 'button',
      onclick: () => {
        action.run();
        node.remove();
      },
    }, action.label) : null);
  toasts.append(node);
  while (toasts.childElementCount > 3) toasts.firstElementChild.remove();
  setTimeout(() => {
    node.classList.add('closing');
    setTimeout(() => node.remove(), 200);
  }, timeout);
  return { close: () => node.remove() };
}

export function openExternal(url) {
  let parsed;
  try {
    parsed = new URL(url, location.href);
  } catch {
    return;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return;
  if (!postNative({ type: 'open', url: parsed.href })) window.open(parsed.href, '_blank', 'noopener,noreferrer');
}

export async function copyText(text) {
  if (postNative({ type: 'copy', text })) return true;
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const area = h('textarea', { style: 'position:fixed;opacity:0;top:0;left:0' });
    area.value = text;
    document.body.append(area);
    area.select();
    let ok = false;
    try {
      ok = document.execCommand('copy');
    } catch {
      ok = false;
    }
    area.remove();
    return ok;
  }
}

// ---------------------------------------------------------------------------- redraws and the mouse

// A click is a press and a release on the same element. The inbox, the agenda and the voice change while a finger is
// down, and a redraw that replaces the element in between swallows the click. So the views' redraws wait while the
// mouse button is held in the page and run once it is up: after the click, which comes right after the release. A
// press held for long (a drag that left the page) stops holding them back after a few seconds.
const HOLD_MAX_MS = 4000;
let pressedAt = 0;
const held = new Map();

document.addEventListener('pointerdown', (event) => {
  if (event.button === 0) pressedAt = Date.now();
}, true);

function released() {
  if (!pressedAt) return;
  pressedAt = 0;
  if (!held.size) return;
  setTimeout(() => {
    const redraws = [...held.values()];
    held.clear();
    for (const redraw of redraws) redraw();
  }, 0);
}
window.addEventListener('pointerup', released, true);
window.addEventListener('pointercancel', released, true);
window.addEventListener('blur', released);

/** Runs `redraw` now, or (the latest one per `name`) once the mouse button is up. */
export function redrawWhenFree(name, redraw) {
  if (pressedAt && Date.now() - pressedAt < HOLD_MAX_MS) {
    held.set(name, redraw);
    return;
  }
  held.delete(name);
  redraw();
}

// ---------------------------------------------------------------------------- overlays (sheets, lightboxes)

export function overlayOpen() {
  return [...overlays.children].some((el) => !el.classList.contains('closing'));
}

export function closeOverlay() {
  const open = [...overlays.children].filter((el) => !el.classList.contains('closing'));
  const top = open[open.length - 1];
  if (!top) return false;
  top.classList.add('closing');
  if (typeof top.onclose === 'function') top.onclose();
  setTimeout(() => top.remove(), 160);
  return true;
}

export function showOverlay(node) {
  overlays.append(node);
  return node;
}

/**
 * A small centered glass sheet (journal note, unpair): a title, a body, and buttons. Clicking outside or Esc closes
 * it. Returns {overlay, close}.
 */
export function sheet({ title, text = '', body = null, buttons = [], className = '' }) {
  const close = () => {
    if (overlay.isConnected && !overlay.classList.contains('closing')) {
      overlay.classList.add('closing');
      setTimeout(() => overlay.remove(), 160);
    }
  };
  const panel = h('div', { class: `dialog ${className}`.trim(), role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
    h('h2', { class: 'dialog-title', text: title }),
    text ? h('p', { class: 'dialog-text', text }) : null,
    body,
    buttons.length ? h('div', { class: 'dialog-buttons' }, buttons) : null);
  const overlay = h('div', { class: 'overlay dim' }, panel);
  overlay.addEventListener('mousedown', (event) => {
    if (event.target === overlay) close();
  });
  overlays.append(overlay);
  return { overlay, panel, close };
}

// ---------------------------------------------------------------------------- popovers

let openPopover = null;

export function closePopover() {
  if (!openPopover) return false;
  const { node, anchor } = openPopover;
  openPopover = null;
  anchor.classList.remove('active');
  node.classList.add('closing');
  setTimeout(() => node.remove(), 140);
  return true;
}

/** A glass popover under (or above, when there's no room) `anchor`, aligned to its right edge by default. */
export function popover(anchor, content, { align = 'end', width = 300 } = {}) {
  closePopover();
  const node = h('div', { class: 'popover', role: 'dialog', style: `width:${width}px` }, content);
  document.body.append(node);
  const box = anchor.getBoundingClientRect();
  const height = node.offsetHeight;
  const below = box.bottom + 8 + height < window.innerHeight - 8;
  const top = below ? box.bottom + 8 : Math.max(8, box.top - 8 - height);
  let left = align === 'end' ? box.right - width : box.left;
  left = Math.max(8, Math.min(window.innerWidth - width - 8, left));
  node.style.top = `${Math.round(top)}px`;
  node.style.left = `${Math.round(left)}px`;
  node.classList.add(below ? 'from-top' : 'from-bottom');
  anchor.classList.add('active');
  openPopover = { node, anchor };
  return node;
}

document.addEventListener('mousedown', (event) => {
  if (!openPopover) return;
  if (openPopover.node.contains(event.target) || openPopover.anchor.contains(event.target)) return;
  closePopover();
}, true);
window.addEventListener('resize', () => closePopover());

// ---------------------------------------------------------------------------- controls

/** An on/off switch like System Settings'. */
export function toggle({ checked, disabled = false, label, onchange }) {
  const input = h('input', { type: 'checkbox', role: 'switch', 'aria-label': label, disabled });
  input.checked = Boolean(checked);
  input.addEventListener('change', () => onchange?.(input.checked));
  return h('label', { class: `switch${disabled ? ' disabled' : ''}` }, input, h('span', { class: 'switch-track' }, h('span', { class: 'switch-knob' })));
}

/** A segmented control; `options` = [{value, label, count?}]. */
export function segmented(options, value, onchange, { label = '' } = {}) {
  return h('div', { class: 'segmented', role: 'tablist', 'aria-label': label },
    options.map((option) => h('button', {
      class: `segment${option.value === value ? ' selected' : ''}`,
      type: 'button',
      role: 'tab',
      'aria-selected': option.value === value ? 'true' : 'false',
      onclick: () => onchange(option.value),
    }, option.icon ? icon(option.icon, { size: 13 }) : null, h('span', { text: option.label }),
    option.count ? h('span', { class: 'segment-count', text: String(option.count) }) : null)));
}

/** A key cap for a shortcut ("⌃⌥Space"). */
export function keycap(text) {
  return h('kbd', { class: 'keycap', text });
}

/** A small "…" spinner used inside buttons while a request runs. */
export function spinner() {
  return h('span', { class: 'spinner' });
}

/** Grows a textarea with its text, up to `max` px. */
export function autosize(area, max = 220) {
  const fit = () => {
    area.style.height = 'auto';
    area.style.height = `${Math.min(max, area.scrollHeight)}px`;
  };
  area.addEventListener('input', fit);
  requestAnimationFrame(fit);
  return fit;
}
