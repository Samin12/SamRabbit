// Drawing inbox items (agents and chats) the way the Agent Dock does: the source tile (T3 with its model family in a
// corner, Claude's asterisk, Codex's brackets, the orb for SamRabbit chats), the status dot or progress ring, a row
// (with its ✕ under the pointer), the approval card and the question card, and dismissing with "Dismissed · Undo".
// Home and Tasks share these.

import { h } from './dom.js';
import { clip } from './format.js';
import { icon } from './icons.js';
import {
  agentLabel, answersOnTap, approvalKindLabel, canDismiss, metaLine, needsYou, recommendedOption, supports,
} from './inbox.js';

/** "now", "4m", "2h", "3d", then "Oct 2" (the dock's short times). */
export function shortAgo(ms, now = Date.now()) {
  if (!ms) return '';
  const seconds = (now - ms) / 1000;
  if (seconds < 45) return 'now';
  if (seconds < 3600) return `${Math.max(1, Math.round(seconds / 60))}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  if (seconds < 7 * 86400) return `${Math.floor(seconds / 86400)}d`;
  return new Date(ms).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

export function sourceGlyph(item, size = 30) {
  const tile = h('span', { class: `glyph glyph-${item.source}`, style: `--g:${size}px`, 'aria-hidden': 'true' });
  switch (item.source) {
    case 't3':
      tile.append(h('span', { class: 'glyph-t3', text: 'T3' }));
      if (agentLabel(item)) {
        tile.append(h('span', { class: 'glyph-badge' },
          icon(agentLabel(item) === 'Codex' ? 'code' : 'asterisk', { size: Math.round(size * 0.3) })));
      }
      break;
    case 'claude':
      tile.append(icon('asterisk', { size: Math.round(size * 0.5) }));
      break;
    case 'codex':
      tile.append(icon('code', { size: Math.round(size * 0.48) }));
      break;
    case 'samrabbit':
      tile.append(h('img', { class: 'glyph-orb', src: 'orb.svg', alt: '' }));
      break;
    default:
      tile.append(icon('sparkles', { size: Math.round(size * 0.48) }));
  }
  return tile;
}

/** A small ring for work in progress (indeterminate without a number). */
export function progressRing(progress, size = 12) {
  const r = 5;
  const c = 2 * Math.PI * r;
  const known = typeof progress === 'number';
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 14 14');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('class', `ring${known ? '' : ' spinning'}`);
  svg.innerHTML = `<circle cx="7" cy="7" r="${r}" class="ring-track"/>`
    + `<circle cx="7" cy="7" r="${r}" class="ring-fill" stroke-dasharray="${c.toFixed(2)}" `
    + `stroke-dashoffset="${(c * (1 - (known ? Math.max(0.04, Math.min(1, progress)) : 0.28))).toFixed(2)}"/>`;
  return svg;
}

/** The dot before a title: accent for an approval or a question, red for a failure, white for an unseen finish. */
export function statusMark(item) {
  if (item.status === 'working') return progressRing(item.progress);
  const tone = item.status === 'needs-approval' || item.status === 'needs-input' ? 'accent'
    : item.status === 'error' ? 'error' : item.status === 'done' && item.unread ? 'unread' : null;
  return tone ? h('span', { class: `mark mark-${tone}` }) : null;
}

/** "SamRabbit · Claude" and the status label (accent while it needs you). */
export function itemMeta(item) {
  const who = metaLine(item.project, item.source === 'samrabbit' ? null : agentLabel(item));
  const label = item.statusLabel || (item.status === 'working' ? 'Working' : '');
  return h('div', { class: 'item-meta' },
    who ? h('span', { class: 'item-who', text: who }) : null,
    who && label ? h('span', { class: 'sep', text: '·' }) : null,
    label ? h('span', { class: `item-status status-${item.status}${needsYou(item) ? ' needs' : ''}`, text: label }) : null,
    item.live && item.source !== 'samrabbit' ? h('span', { class: 'live-chip', text: 'Live' }) : null);
}

/**
 * One list row: tile, title, meta, two lines of summary, time. With `onDismiss` (and an item that can be dismissed)
 * a small ✕ takes the time's place while the pointer is on the row.
 */
export function itemRow(item, { selected = false, now = Date.now(), busy = '', onclick, compact = false, onDismiss = null } = {}) {
  const summary = item.summary || (item.status === 'working' && item.phase ? item.phase : '');
  const dismissible = Boolean(onDismiss) && canDismiss(item) && !busy;
  return h('button', {
    class: `item-row${selected ? ' selected' : ''}${compact ? ' compact' : ''}${dismissible ? ' dismissible' : ''} source-${item.source}`,
    type: 'button',
    dataset: { id: item.id },
    'aria-current': selected ? 'true' : null,
    onclick: (event) => {
      // The ✕ is inside the row (a button can't hold a button): a press on it dismisses instead of selecting.
      if (dismissible && event.target && event.target.closest && event.target.closest('.row-dismiss')) {
        event.preventDefault();
        event.stopPropagation();
        onDismiss(item);
        return;
      }
      onclick?.(event);
    },
  },
  sourceGlyph(item, compact ? 28 : 30),
  h('div', { class: 'item-main' },
    h('div', { class: 'item-top' },
      statusMark(item),
      h('span', { class: 'item-title', text: item.title }),
      h('time', { class: 'item-time', text: busy ? '' : shortAgo(item.updatedAt, now) }),
      dismissible ? h('span', { class: 'row-dismiss', role: 'button', title: 'Dismiss (X): hidden until something changes', 'aria-label': 'Dismiss' },
        icon('close', { size: 11 })) : null,
      busy ? h('span', { class: 'spinner' }) : null),
    itemMeta(item),
    !compact && summary ? h('div', { class: 'item-summary', text: summary }) : null,
    item.status === 'working' && typeof item.progress === 'number'
      ? h('div', { class: 'item-progress' }, h('span', { style: `width:${Math.round(Math.max(0.03, Math.min(1, item.progress)) * 100)}%` }))
      : null));
}

/**
 * An approval request: what it wants (the command, the files) and one button per option, the recommended one in the
 * accent. `onDecide(decision)`.
 */
export function approvalCard(item, approval, { onDecide, busy = false, hint = true } = {}) {
  const recommended = recommendedOption(approval);
  const kind = String(approval.kind || '').toLowerCase();
  const glyph = ['command', 'exec', 'shell', 'command_execution'].includes(kind) ? 'terminal'
    : ['file_change', 'edit', 'patch', 'apply_patch', 'file'].includes(kind) ? 'doc' : 'shield';
  const allowed = supports(item, 'approve');
  return h('div', { class: 'approval' },
    h('div', { class: 'approval-head' }, icon(glyph, { size: 15 }), h('span', { text: approvalKindLabel(approval.kind) })),
    approval.detail ? h('pre', { class: 'approval-detail', text: approval.detail }) : null,
    allowed ? h('div', { class: 'approval-options' }, approval.options.map((option) => h('button', {
      class: `chip-btn${option === recommended ? ' primary' : ''}`,
      type: 'button',
      disabled: busy,
      onclick: () => onDecide?.(option.decision),
    }, option === recommended ? icon('check', { size: 13 }) : null, h('span', { text: option.label }))))
      : h('div', { class: 'approval-elsewhere', text: item.source === 'claude' ? 'Answer it in the terminal.' : 'Answer it in the app.' }),
    allowed && hint && recommended ? h('div', { class: 'approval-hint', text: `E approves with “${recommended.label}”` }) : null);
}

/**
 * A question card: each question with its options (chips) and a field when typing is allowed. A single one-choice
 * question answers on a click; otherwise "Send answer". `inbox` is the AgentInbox (selections, typed answers).
 */
export function questionCard(item, request, inbox, { busy = false } = {}) {
  const tap = answersOnTap(request);
  const picked = inbox.selections.get(item.id) || {};
  const typed = inbox.customAnswers.get(item.id) || {};
  return h('div', { class: 'approval question' },
    h('div', { class: 'approval-head' }, icon('question', { size: 15 }), h('span', { text: 'Asking you a question' })),
    request.questions.map((question) => h('div', { class: 'q' },
      question.header ? h('div', { class: 'q-header', text: question.header }) : null,
      question.question ? h('div', { class: 'q-text', text: question.question }) : null,
      question.options.length ? h('div', { class: 'approval-options' }, question.options.map((option) => h('button', {
        class: `chip-btn${(picked[question.id] || []).includes(option) ? ' picked' : ''}`,
        type: 'button',
        disabled: busy,
        onclick: () => (tap ? inbox.answerWith(item, request, option) : inbox.toggleOption(item, question, option)),
      }, h('span', { text: option })))) : null,
      question.allowCustom ? (() => {
        const field = h('input', {
          class: 'field', type: 'text', placeholder: question.options.length ? 'Or type an answer…' : 'Type your answer…',
          spellcheck: 'true',
        });
        field.value = typed[question.id] || '';
        field.addEventListener('input', () => inbox.setCustom(item, question, field.value));
        field.addEventListener('keydown', (event) => {
          if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            inbox.answer(item, request);
          }
        });
        return field;
      })() : null)),
    tap ? null : h('div', { class: 'approval-options end' },
      h('button', { class: 'chip-btn primary', type: 'button', disabled: busy, onclick: () => inbox.answer(item, request) },
        icon('send', { size: 13 }), h('span', { text: 'Send answer' }))));
}

/** The short line under an item after an action: what happened, or why it didn't (with Open for a live session). */
export function noteLine(note, { onOpen } = {}) {
  if (!note) return null;
  return h('div', { class: `item-note${note.isError ? ' error' : ''}` },
    icon(note.isError ? 'alert' : 'check', { size: 13 }),
    h('span', { text: note.text }),
    note.offersOpen && onOpen ? h('button', { class: 'link', type: 'button', onclick: onOpen }, 'Open') : null);
}

/**
 * Dismisses an item from Home or Tasks: it goes at once, "Dismissed · <title>" with Undo shows for five seconds (⌘Z
 * too), and a refusal puts it back with a toast saying why. `onUndone(item)` runs when Undo brought it back,
 * `onFailed(item)` when the bridge refused.
 */
export function dismissWithUndo(agents, item, { toast, onUndone = null, onFailed = null } = {}) {
  let shown = null;
  const undo = () => {
    shown?.close();
    agents.undoDismiss(item).then((result) => {
      if (result.problem) toast(result.problem, { tone: 'error', icon: 'alert', timeout: 6000 });
      else onUndone?.(item);
    });
  };
  shown = toast(`Dismissed · ${clip(item.title, 64)}`, { action: { label: 'Undo', run: undo }, icon: 'eye', timeout: 5000 });
  lastUndo = { id: item.id, run: undo };
  agents.dismiss(item).then((result) => {
    if (result.problem) {
      shown?.close();
      if (lastUndo && lastUndo.id === item.id) lastUndo = null;
      toast(result.problem, { tone: 'error', icon: 'alert', timeout: 6000 });
      onFailed?.(item);
    }
  });
  return undo;
}

let lastUndo = null;

/** ⌘Z outside a field: the undo of the last dismissal while its toast shows. Whether there was one. */
export function undoLastDismiss(agents) {
  const item = agents.undoable();
  if (!item || !lastUndo || lastUndo.id !== item.id) return false;
  const { run } = lastUndo;
  lastUndo = null;
  run();
  return true;
}
