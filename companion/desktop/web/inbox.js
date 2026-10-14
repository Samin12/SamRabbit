// The agent inbox as the window shows it (GET /v1/desktop/inbox, CONTRACTS-WAVE6 §A): T3 Code threads, Claude Code
// and Codex sessions, and the recent SamRabbit chats. The same rules as the Agent Dock (Sources/DockModels.swift,
// DockStore.swift, DockKeyboard.swift), so both say the same thing: forgiving decoding, the contract's order, what
// "needs you" means, the recommended approval option, answers to questions, optimistic actions with rollback,
// dismissing (hidden at once, the bridge's list decides once it agreed; undo shows it again at once), and the keys.
// Pure (no DOM, no network): tests/inbox.test.mjs runs it in Node.

import { clip, toMs } from './format.js';

export const STATUSES = ['needs-approval', 'needs-input', 'error', 'done', 'working', 'idle'];
export const SOURCES = ['t3', 'claude', 'codex', 'samrabbit'];
export const ITEM_CAP = 60;

const REFUSALS = new Set(['decline', 'deny', 'reject', 'cancel', 'abort']);

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function oneLine(value) {
  return text(value).replace(/\s+/g, ' ');
}

// ---------------------------------------------------------------------------- decoding

function normalizeApproval(raw) {
  if (!raw || typeof raw !== 'object' || !text(raw.requestId)) return null;
  const options = (Array.isArray(raw.options) ? raw.options : [])
    .filter((o) => o && typeof o === 'object' && text(o.decision))
    .map((o) => ({ decision: text(o.decision), label: text(o.label) || text(o.decision) }));
  return {
    requestId: text(raw.requestId),
    kind: text(raw.kind) || 'approval',
    detail: typeof raw.detail === 'string' ? raw.detail : '',
    // A request without its choices still has to be answerable.
    options: options.length ? options : [{ decision: 'accept', label: 'Approve' }, { decision: 'decline', label: 'Deny' }],
  };
}

function normalizeQuestion(raw) {
  if (!raw || typeof raw !== 'object' || !text(raw.id)) return null;
  const options = (Array.isArray(raw.options) ? raw.options : []).filter((o) => typeof o === 'string' && o.trim());
  return {
    id: text(raw.id),
    header: text(raw.header),
    question: text(raw.question),
    options,
    allowCustom: typeof raw.allowCustom === 'boolean' ? raw.allowCustom : !options.length,
    multiSelect: raw.multiSelect === true,
  };
}

function normalizeInput(raw) {
  if (!raw || typeof raw !== 'object' || !text(raw.requestId)) return null;
  return {
    requestId: text(raw.requestId),
    questions: (Array.isArray(raw.questions) ? raw.questions : []).map(normalizeQuestion).filter(Boolean),
  };
}

/** One InboxItem; a missing or odd field takes its default, an unknown status reads as idle. Null without an id. */
export function normalizeItem(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const id = text(raw.id);
  if (!id) return null;
  const pending = raw.pending && typeof raw.pending === 'object' ? raw.pending : {};
  const status = STATUSES.includes(text(raw.status)) ? text(raw.status) : 'idle';
  const progress = typeof raw.progress === 'number' && Number.isFinite(raw.progress) ? raw.progress : null;
  return {
    id,
    source: text(raw.source) || id.split(':')[0],
    agent: text(raw.agent) || null,
    title: oneLine(raw.title) || 'Untitled',
    project: text(raw.project) || null,
    cwd: text(raw.cwd) || null,
    status,
    statusLabel: oneLine(raw.statusLabel),
    summary: text(raw.summary),
    updatedAt: toMs(raw.updatedAt),
    unread: raw.unread === true,
    pending: {
      approvals: (Array.isArray(pending.approvals) ? pending.approvals : []).map(normalizeApproval).filter(Boolean),
      inputs: (Array.isArray(pending.inputs) ? pending.inputs : []).map(normalizeInput).filter(Boolean),
    },
    can: (Array.isArray(raw.can) ? raw.can : []).filter((c) => typeof c === 'string'),
    live: raw.live === true,
    progress,
    phase: text(raw.phase) || null,
    dismissed: raw.dismissed === true,
  };
}

/** One answer of GET /v1/desktop/inbox: {revision, updatedAt, counts, sources, items} (items sorted, capped). */
export function normalizeInbox(raw) {
  const body = raw && typeof raw === 'object' ? raw : {};
  // A dismissed item is the bridge's to bring back: never a row, even from a bridge that sends it anyway.
  const items = sortItems((Array.isArray(body.items) ? body.items : []).map(normalizeItem)
    .filter((item) => item && !item.dismissed).slice(0, ITEM_CAP));
  const computed = {
    needsYou: items.filter(needsYou).length,
    working: items.filter((i) => i.status === 'working' && !isChat(i)).length,
    total: items.length,
  };
  const counts = body.counts && typeof body.counts === 'object' ? {
    needsYou: Number(body.counts.needsYou) || 0, working: Number(body.counts.working) || 0, total: Number(body.counts.total) || 0,
    dismissed: Number(body.counts.dismissed) || 0,
  } : { ...computed, dismissed: 0 };
  return {
    revision: Number.isFinite(body.revision) ? body.revision : 0,
    updatedAt: toMs(body.updatedAt),
    counts,
    sources: body.sources && typeof body.sources === 'object' ? body.sources : {},
    items,
  };
}

/** `GET …/items/<id>`: {item, messages (the last 12 with text)}. */
export function normalizeDetail(raw) {
  const body = raw && typeof raw === 'object' ? raw : {};
  const messages = (Array.isArray(body.messages) ? body.messages : [])
    .filter((m) => m && typeof m === 'object' && typeof m.text === 'string' && m.text.trim())
    .map((m) => ({ role: m.role === 'user' ? 'user' : 'assistant', text: m.text, at: toMs(m.at) }))
    .slice(-12);
  return { item: normalizeItem(body.item), messages };
}

// ---------------------------------------------------------------------------- rules

export function isChat(item) {
  return item.source === 'samrabbit';
}

/** "Needs you": waiting on an approval or an answer, failed, or finished and not yet seen. */
export function needsYou(item) {
  switch (item.status) {
    case 'needs-approval':
    case 'needs-input':
    case 'error':
      return true;
    case 'done':
      return item.unread;
    default:
      return false;
  }
}

export function rank(item) {
  switch (item.status) {
    case 'needs-approval': return 0;
    case 'needs-input': return 1;
    case 'error': return 2;
    case 'done': return item.unread ? 3 : 5;
    case 'working': return 4;
    default: return 5;
  }
}

/** needs-approval, needs-input, error, done (unread), working, the rest; each newest first, the id breaks ties. */
export function sortItems(items) {
  return [...items].sort((a, b) => (rank(a) - rank(b)) || ((b.updatedAt || 0) - (a.updatedAt || 0))
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

export function supports(item, capability) {
  return Array.isArray(item.can) && item.can.includes(capability);
}

/** Every item of a bridge that knows dismissing (W8): hidden until it changes. */
export function canDismiss(item) {
  return Boolean(item) && supports(item, 'dismiss') && !String(item.id).startsWith('pending:');
}

/** Who runs it: "Claude", "Codex", or null (chats). */
export function agentLabel(item) {
  const family = (item.agent || (item.source === 'claude' || item.source === 'codex' ? item.source : '')).toLowerCase();
  if (family === 'claude') return 'Claude';
  if (family === 'codex') return 'Codex';
  return null;
}

export function sourceLabel(source) {
  return { t3: 'T3 Code', claude: 'Claude Code', codex: 'Codex', samrabbit: 'SamRabbit' }[source] || 'Agent';
}

/** "SamRabbit · Claude": the parts that exist. */
export function metaLine(...parts) {
  return parts.map((p) => text(p)).filter(Boolean).join(' · ');
}

/** The option E and the accent button stand for: "accept", else the first that isn't a refusal, else the first. */
export function recommendedOption(approval) {
  if (!approval || !approval.options.length) return null;
  return approval.options.find((o) => o.decision === 'accept')
    || approval.options.find((o) => !REFUSALS.has(o.decision.toLowerCase()))
    || approval.options[0];
}

export function isRefusal(decision) {
  return REFUSALS.has(String(decision || '').toLowerCase());
}

export function approvalKindLabel(kind) {
  switch (String(kind || '').toLowerCase()) {
    case 'command': case 'exec': case 'shell': case 'command_execution': return 'Wants to run a command';
    case 'file_change': case 'edit': case 'patch': case 'apply_patch': case 'file': return 'Wants to change files';
    case 'network': return 'Wants network access';
    case 'tool': case 'mcp': return 'Wants to use a tool';
    default: return 'Wants your approval';
  }
}

export function openLabel(item) {
  switch (item.source) {
    case 't3': return 'Open in T3';
    case 'samrabbit': return 'Open in Chats';
    case 'claude': return item.live ? 'Open Terminal' : 'Open';
    case 'codex': return supports(item, 'seen') ? 'Open in Codex' : 'Open';
    default: return 'Open';
  }
}

/** Who a reply goes to: "Reply to Claude…". */
export function replyPlaceholder(item) {
  const who = agentLabel(item);
  return who ? `Reply to ${who}…` : 'Reply…';
}

// ---------------------------------------------------------------------------- sections and filters

export const FILTERS = [
  { value: 'all', label: 'All' },
  { value: 't3', label: 'T3' },
  { value: 'claude', label: 'Claude' },
  { value: 'codex', label: 'Codex' },
];

export function matchesFilter(item, filter) {
  return !filter || filter === 'all' || item.source === filter;
}

/** How many need you per filter (for the segmented control's counts). */
export function filterCounts(items) {
  const counts = { all: 0, t3: 0, claude: 0, codex: 0 };
  for (const item of items) {
    if (!needsYou(item)) continue;
    counts.all += 1;
    if (item.source in counts) counts[item.source] += 1;
  }
  return counts;
}

/**
 * The Tasks list: Needs you, Working (agents at work), Recent (everything else, newest first; SamRabbit chats only
 * when no source filter is on). Empty sections are left out.
 */
export function buildSections(items, filter = 'all') {
  const shown = sortItems(items.filter((item) => matchesFilter(item, filter)));
  const byTime = (a, b) => (b.updatedAt || 0) - (a.updatedAt || 0) || (a.id < b.id ? -1 : 1);
  const needs = shown.filter(needsYou);
  const working = shown.filter((i) => !needsYou(i) && i.status === 'working' && !isChat(i));
  const recent = shown.filter((i) => !needsYou(i) && !(i.status === 'working' && !isChat(i))).sort(byTime);
  return [
    { kind: 'needsYou', title: 'Needs you', items: needs },
    { kind: 'working', title: 'Working', items: working },
    { kind: 'recent', title: 'Recent', items: recent },
  ].filter((section) => section.items.length);
}

/** The rows top to bottom (what J/K walk through). */
export function rowIds(sections) {
  return sections.flatMap((section) => section.items.map((item) => item.id));
}

/**
 * "2 need you" / "4 working", counted from the rows on screen (with optimistic results and new tasks on their way),
 * like the sections; the bridge's counts only add what lies past its 60-item cap. A chat streaming a reply is not an
 * agent at work.
 */
export function shownCounts(inbox, items) {
  const needs = items.filter(needsYou).length;
  const working = items.filter((i) => i.status === 'working' && !isChat(i)).length;
  if (!inbox || !(inbox.counts.total > inbox.items.length)) return { needsYou: needs, working };
  const moreNeeds = Math.max(0, inbox.counts.needsYou - inbox.items.filter(needsYou).length);
  const moreWorking = Math.max(0, inbox.counts.working - inbox.items.filter((i) => i.status === 'working').length);
  return { needsYou: needs + moreNeeds, working: working + moreWorking };
}

// ---------------------------------------------------------------------------- answers to questions

/** The value for one question: a list for multi-select, else one string; the typed answer wins (single-select). */
export function answerValue(question, selected = [], custom = '') {
  const typed = String(custom || '').trim();
  const chosen = question.options.filter((o) => selected.includes(o));
  if (question.multiSelect) {
    const all = chosen.concat(typed && question.allowCustom ? [typed] : []);
    return all.length ? all : null;
  }
  if (question.allowCustom && typed) return typed;
  return chosen.length ? chosen[0] : null;
}

/** `{questionId: str|[str]}` when every question has an answer, else null. */
export function buildAnswers(request, selected = {}, custom = {}) {
  const answers = {};
  for (const question of request.questions) {
    const value = answerValue(question, selected[question.id] || [], custom[question.id] || '');
    if (value == null) return null;
    answers[question.id] = value;
  }
  return Object.keys(answers).length ? answers : null;
}

/** One click answers it: a single question, single choice, nothing to type. */
export function answersOnTap(request) {
  const [question] = request.questions;
  return request.questions.length === 1 && !question.multiSelect && !question.allowCustom && question.options.length > 0;
}

// ---------------------------------------------------------------------------- what the row says after an action

/** A failed action as a short line under the item (the dock's wording). */
export function failureNote(error) {
  const status = error && typeof error.status === 'number' ? error.status : 0;
  const code = (error && error.code) || '';
  const message = error && error.detail ? clip(error.detail, 120) : '';
  if (status === 409 && code === 'session_live') {
    return { text: 'It’s open in Terminal — Open to answer there', isError: true, offersOpen: true };
  }
  if ((status === 409 || status === 503) && code === 't3_not_connected') {
    return { text: 'T3 Code isn’t connected to the bridge.', isError: true };
  }
  if (status === 409) return { text: message || 'That was already answered.', isError: true };
  if (status === 0) return { text: 'The Mac bridge isn’t answering.', isError: true };
  if (status === 401 || status === 403) return { text: 'The bridge didn’t accept SamRabbit.', isError: true };
  if (status === 404) return { text: 'This one is gone from the inbox.', isError: true };
  return { text: `That didn’t work: ${message || `HTTP ${status}`}`, isError: true };
}

/** Why a dismissal (or its undo) didn't happen, for the toast. */
export function dismissProblem(error, { undo = false } = {}) {
  const status = error && typeof error.status === 'number' ? error.status : 0;
  const code = (error && error.code) || '';
  const lead = undo ? 'Couldn’t bring it back' : 'Couldn’t dismiss it';
  if (status === 0) return `${lead}: the Mac bridge isn’t answering.`;
  if (status === 404 && code === 'item_not_found') return `${lead}: it’s gone from the inbox.`;
  if (status === 404 || status === 405) return `${lead}: update the bridge (companion/mac-bridge/install.sh).`;
  if (status === 401 || status === 403) return `${lead}: the bridge didn’t accept SamRabbit.`;
  return `${lead}: ${error && error.detail ? clip(error.detail, 90) : `HTTP ${status}`}`;
}

/** What happened, when it's worth saying ("Opened in Terminal."). */
export function actionInfo(kind, reply) {
  const how = reply && reply.how;
  if (kind === 'reply' && how === 'terminal') return 'Sent through Terminal: it opened with your reply.';
  if (kind === 'reply' && how === 'app') return 'Sent in the app.';
  if (kind === 'open' && how === 'terminal') return 'Opened in Terminal.';
  if (kind === 'open' && how === 't3') return 'Opened in T3 Code.';
  if (kind === 'open' && how === 'app') return 'Opened in the app.';
  return null;
}

/** The optimistic item for an action (null: nothing changes until the bridge answers). */
export function optimisticItem(item, kind, body = {}) {
  const next = { ...item, pending: { approvals: [...item.pending.approvals], inputs: [...item.pending.inputs] } };
  switch (kind) {
    case 'approve': {
      next.pending.approvals = next.pending.approvals.filter((a) => a.requestId !== body.requestId);
      if (!next.pending.approvals.length && !next.pending.inputs.length) {
        next.status = 'working';
        next.statusLabel = isRefusal(body.decision) ? 'Declined · continuing' : 'Approved · continuing';
      }
      next.unread = false;
      return next;
    }
    case 'answer': {
      next.pending.inputs = next.pending.inputs.filter((r) => r.requestId !== body.requestId);
      if (!next.pending.approvals.length && !next.pending.inputs.length) {
        next.status = 'working';
        next.statusLabel = 'Answered · continuing';
      }
      next.unread = false;
      return next;
    }
    case 'reply':
      return { ...next, status: 'working', statusLabel: 'Sending your reply…', unread: false };
    case 'stop':
      return { ...next, statusLabel: 'Stopping…' };
    case 'seen':
      return { ...next, unread: false };
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------- the store

const OVERLAY_MS = 20_000;
const PLACEHOLDER_MS = 45_000;
/** A dismissal (or an undo) nothing settled is let go after this long: the inbox's own list again. */
export const DISMISS_STALE_MS = 30_000;
/** How long "Dismissed · Undo" stays (and ⌘Z can undo). */
export const UNDO_MS = 5_000;

/**
 * The inbox with what the window did meanwhile: optimistic results (shown at once, kept until the inbox catches up,
 * dropped on failure or after 20 s), new tasks that the bridge hasn't listed yet (45 s), rows dismissed here (gone at
 * once; once the bridge said yes, its list from the revision it gave decides, so an item that changed is back by
 * itself) and dismissals undone here (shown from the copy until the inbox carries them again). `items` is what the
 * list draws.
 */
export class InboxStore {
  constructor() {
    this.inbox = normalizeInbox({});
    this.items = [];
    this.overlays = new Map(); // id -> {item, started, settledAt}
    this.placeholders = []; // {item, until}
    this.hidden = new Map(); // id -> {item, at, settles}: dismissed here
    this.restored = new Map(); // id -> {item, at, settles}: undone here
    this.received = false;
  }

  /** Applies an inbox answer; returns {changed, countsChanged}. */
  apply(raw, now = Date.now()) {
    const inbox = normalizeInbox(raw);
    const before = this.counts();
    const changed = !this.received || JSON.stringify(inbox.items) !== JSON.stringify(this.inbox.items)
      || JSON.stringify(inbox.counts) !== JSON.stringify(this.inbox.counts);
    this.received = true;
    this.inbox = inbox;
    for (const [id, overlay] of this.overlays) {
      if (overlay.settledAt != null && inbox.revision > overlay.settledAt) this.overlays.delete(id);
    }
    const present = new Set(inbox.items.map((i) => i.id));
    this.placeholders = this.placeholders.filter((p) => !present.has(p.item.id));
    for (const [id, entry] of this.hidden) {
      if (entry.settles != null && inbox.revision >= entry.settles) this.hidden.delete(id);
    }
    for (const [id, entry] of this.restored) {
      if (present.has(id) || (entry.settles != null && inbox.revision >= entry.settles)) this.restored.delete(id);
    }
    this.tick(now, false);
    this.rebuild();
    const after = this.counts();
    return { changed, countsChanged: before.needsYou !== after.needsYou || before.working !== after.working };
  }

  rebuild() {
    const base = this.inbox.items.map((item) => (this.overlays.get(item.id) || {}).item || item);
    const ids = new Set(base.map((i) => i.id));
    const extra = this.placeholders.map((p) => p.item).filter((i) => !ids.has(i.id));
    const back = [...this.restored.values()].map((entry) => entry.item).filter((i) => !ids.has(i.id));
    this.items = sortItems(base.concat(extra, back).filter((i) => !this.hidden.has(i.id)));
    return this.items;
  }

  /** Forgets old overlays and placeholders; returns whether anything went. */
  tick(now = Date.now(), rebuild = true) {
    let gone = false;
    for (const [id, overlay] of this.overlays) {
      if (now - overlay.started >= OVERLAY_MS) {
        this.overlays.delete(id);
        gone = true;
      }
    }
    const before = this.placeholders.length;
    this.placeholders = this.placeholders.filter((p) => p.until > now);
    gone = gone || this.placeholders.length !== before;
    for (const map of [this.hidden, this.restored]) {
      for (const [id, entry] of map) {
        if (now - entry.at >= DISMISS_STALE_MS) {
          map.delete(id);
          gone = true;
        }
      }
    }
    if (gone && rebuild) this.rebuild();
    return gone;
  }

  // ------------------------------------------------------------------ dismissing

  isDismissed(id) {
    return this.hidden.has(id);
  }

  /** The row goes at once (and with it from the counts). */
  dismiss(item, now = Date.now()) {
    this.restored.delete(item.id);
    this.hidden.set(item.id, { item, at: now, settles: null });
    this.rebuild();
  }

  /** The bridge said yes: its list leaves the item out from `revision` on (at once when the inbox is already there). */
  confirmDismiss(id, revision) {
    const entry = this.hidden.get(id);
    if (!entry) return;
    const settles = Number.isFinite(revision) ? revision : this.inbox.revision + 1;
    if (this.inbox.revision >= settles) {
      this.hidden.delete(id);
      this.rebuild();
    } else {
      entry.settles = settles;
    }
  }

  /** The dismissal failed: the row is back. Returns whether it was still hidden here. */
  failDismiss(id) {
    const had = this.hidden.delete(id);
    if (had) this.rebuild();
    return had;
  }

  /** Undo: the row is back at once, from the copy kept here (the one hidden, else `item`). */
  undo(item, now = Date.now()) {
    const entry = this.hidden.get(item.id);
    this.hidden.delete(item.id);
    this.restored.set(item.id, { item: entry ? entry.item : item, at: now, settles: null });
    this.rebuild();
  }

  /** The dismissal an undo waited for failed: nothing to undo, the inbox's own row stays. */
  undoNotNeeded(id) {
    if (this.restored.delete(id)) this.rebuild();
  }

  /** The bridge took the undo back: its list carries the item again from `revision` on. */
  confirmUndo(id, revision) {
    const entry = this.restored.get(id);
    if (!entry) return;
    const settles = Number.isFinite(revision) ? revision : this.inbox.revision + 1;
    if (this.inbox.revision >= settles) {
      this.restored.delete(id);
      this.rebuild();
    } else {
      entry.settles = settles;
    }
  }

  /** The undo failed: the bridge still keeps it dismissed, so it goes again. */
  failUndo(id, now = Date.now()) {
    const entry = this.restored.get(id);
    if (!entry) return;
    this.restored.delete(id);
    this.hidden.set(id, { item: entry.item, at: now, settles: null });
    this.rebuild();
  }

  item(id) {
    return id ? this.items.find((i) => i.id === id) || null : null;
  }

  counts() {
    return shownCounts(this.inbox, this.items);
  }

  sections(filter = 'all') {
    return buildSections(this.items, filter);
  }

  /** Shows `item` in place of the inbox's until the bridge has answered and a newer inbox arrived. */
  overlay(item, now = Date.now()) {
    this.overlays.set(item.id, { item, started: now, settledAt: null });
    this.rebuild();
  }

  /** The bridge said yes: the overlay stays until an inbox newer than this one. */
  settle(id) {
    const overlay = this.overlays.get(id);
    if (overlay) overlay.settledAt = this.inbox.revision;
  }

  rollback(id) {
    if (this.overlays.delete(id)) this.rebuild();
  }

  /** A new task on its way: a row under Working until the bridge lists it. Returns the placeholder's id. */
  addPlaceholder({ text: prompt, project, agent }, now = Date.now()) {
    const id = `pending:${now.toString(36)}${Math.random().toString(36).slice(2, 7)}`;
    const item = normalizeItem({
      id, source: 't3', agent, title: clip(prompt, 90), project, status: 'working', statusLabel: 'Starting…',
      updatedAt: now, can: [],
    });
    this.placeholders.push({ item, until: now + PLACEHOLDER_MS });
    this.rebuild();
    return id;
  }

  /** The bridge named the new task: the placeholder takes its id (and goes once the inbox lists it). */
  resolvePlaceholder(placeholderId, itemId) {
    const entry = this.placeholders.find((p) => p.item.id === placeholderId);
    if (!entry) return;
    if (itemId) entry.item = { ...entry.item, id: itemId };
    const present = new Set(this.inbox.items.map((i) => i.id));
    this.placeholders = this.placeholders.filter((p) => !present.has(p.item.id));
    this.rebuild();
  }

  dropPlaceholder(placeholderId) {
    this.placeholders = this.placeholders.filter((p) => p.item.id !== placeholderId);
    this.rebuild();
  }
}

// ---------------------------------------------------------------------------- targets for a new task

/**
 * A complete, valid choice for `POST /v1/desktop/inbox/new`: what was picked when it still exists, else the bridge's
 * default, else the first. The model always belongs to the chosen agent.
 */
export function resolveChoice(targets, picked = {}) {
  const projects = (targets && Array.isArray(targets.projects)) ? targets.projects : [];
  const agents = (targets && Array.isArray(targets.agents)) ? targets.agents : [];
  const defaults = (targets && targets.default) || {};
  const projectIds = new Set(projects.map((p) => p.id));
  const projectId = [picked.projectId, defaults.projectId].find((id) => id && projectIds.has(id))
    || (projects[0] && projects[0].id) || null;
  const agent = [picked.agent, defaults.agent].map((id) => agents.find((a) => a.id === id)).find(Boolean) || agents[0] || null;
  const models = agent && Array.isArray(agent.models) ? agent.models : [];
  const model = [picked.model, defaults.model].find((id) => id && models.some((m) => m.id === id))
    || (models[0] && models[0].id) || null;
  return { projectId, agent: agent ? agent.id : null, model };
}

// ---------------------------------------------------------------------------- keys

/**
 * The Tasks keys (no field has the keys): J/K or ↓/↑ move, ↩ opens the selected item where it lives, E approves the
 * selected item's request with the recommended option (its card is on screen: the selection shows it), R replies,
 * X dismisses the selected item, N starts a new task, Esc closes the composer, then the selection.
 * `rows` = [{id, canOpen, canReply, canDismiss, approval}].
 */
export function keyAction(key, rows, selected, { composing = false } = {}) {
  const index = rows.findIndex((row) => row.id === selected);
  switch (key) {
    case 'down':
    case 'up': {
      if (!rows.length) return { type: 'none' };
      if (index < 0) return { type: 'select', id: rows[0].id };
      const next = key === 'down' ? Math.min(rows.length - 1, index + 1) : Math.max(0, index - 1);
      return { type: 'select', id: rows[next].id };
    }
    case 'enter':
      if (index < 0) return rows.length ? { type: 'select', id: rows[0].id } : { type: 'none' };
      return rows[index].canOpen ? { type: 'open', id: rows[index].id } : { type: 'none' };
    case 'approve': {
      if (index < 0 || composing || !rows[index].approval) return { type: 'none' };
      const { requestId, decision } = rows[index].approval;
      return { type: 'approve', id: rows[index].id, requestId, decision };
    }
    case 'reply':
      return index >= 0 && rows[index].canReply ? { type: 'reply', id: rows[index].id } : { type: 'none' };
    case 'dismiss':
      return index >= 0 && !composing && rows[index].canDismiss ? { type: 'dismiss', id: rows[index].id } : { type: 'none' };
    case 'compose':
      return { type: 'compose' };
    case 'escape':
      if (composing) return { type: 'closeCompose' };
      return selected ? { type: 'deselect' } : { type: 'none' };
    default:
      return { type: 'none' };
  }
}

/** What the keys know about a row. */
export function keyRow(item) {
  const row = {
    id: item.id, canOpen: supports(item, 'open'), canReply: supports(item, 'reply'), canDismiss: canDismiss(item), approval: null,
  };
  const approval = item.pending.approvals[0];
  const option = supports(item, 'approve') && approval ? recommendedOption(approval) : null;
  if (option) row.approval = { requestId: approval.requestId, decision: option.decision };
  return row;
}

/** A key event to a Tasks key name (null: not ours). */
export function keyName(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return null;
  switch (event.key) {
    case 'ArrowDown': return 'down';
    case 'ArrowUp': return 'up';
    case 'Enter': return 'enter';
    case 'Escape': return 'escape';
    default: break;
  }
  switch (String(event.key || '').toLowerCase()) {
    case 'j': return 'down';
    case 'k': return 'up';
    case 'e': return 'approve';
    case 'r': return 'reply';
    case 'x': return 'dismiss';
    case 'n': return 'compose';
    default: return null;
  }
}

/** The row to select once `id` leaves the list: the next one, else the one before, else none (X X X clears a run). */
export function selectionAfterDismiss(ids, id) {
  const index = ids.indexOf(id);
  if (index < 0) return null;
  if (index + 1 < ids.length) return ids[index + 1];
  return index > 0 ? ids[index - 1] : null;
}
