// The morning brief as the window reads it (CONTRACTS-WAVE8 §D2, GET /v1/desktop/briefing): the bridge builds one a
// day from Gmail, the calendar and the agent inbox, and Home shows it at the top until noon: the headline, Do first
// (each item's verbs are its buttons: Draft reply, Make task, Block time, Remind me, Open, Done, Dismiss), Today, Agents
// and FYI. Draft reply makes a Gmail DRAFT on the bridge (nothing is ever sent) and opens it in the item's own Google
// account. Pure (tests/briefing.test.mjs); morning.js draws it. The same rules as Sources/DockBriefing.swift (the
// dock's Morning section). Read forgivingly: a missing or odd field takes its default rather than dropping the brief.

import { toMs } from './format.js';

export const SECTIONS = ['doFirst', 'today', 'agents', 'fyi'];
export const SECTION_TITLES = { doFirst: 'Do first', today: 'Today', agents: 'Agents', fyi: 'FYI' };
const CAPS = { doFirst: 3, today: 5, agents: 3, fyi: 3 };
export const MORNING_ENDS_AT = 12;

export const VERBS = ['draft_reply', 'make_task', 'block_time', 'remind', 'done', 'dismiss', 'open'];
const LABELS = {
  draft_reply: 'Draft reply', make_task: 'Make task', block_time: 'Block time', remind: 'Remind me', done: 'Done',
  dismiss: 'Dismiss', open: 'Open',
};
const ICONS = {
  draft_reply: 'reply', make_task: 'plus', block_time: 'calendar', remind: 'bell', done: 'check', dismiss: 'close',
  open: 'external',
};
// The bridge's own names (samrabbit_briefing STATES); "snoozed" is the research draft's "reminded".
const STATES = {
  draft_reply: 'drafted', make_task: 'tasked', block_time: 'blocked', remind: 'reminded', done: 'done', dismiss: 'dismissed',
};
const STATE_LINES = {
  drafted: 'Draft saved in Gmail · not sent', tasked: 'T3 task started', blocked: 'Time blocked', reminded: 'Reminder set',
  snoozed: 'Reminder set', done: 'Done', dismissed: 'Dismissed',
};

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function oneLine(value) {
  return text(value).replace(/\s+/g, ' ');
}

/** "doFirst", "do_first", "Do first", "today", "events", "agents", "fyi"… → a section id, or null. */
export function sectionKind(value) {
  const key = text(value).toLowerCase().replace(/[^a-z]/g, '');
  if (['dofirst', 'first', 'do', 'priority', 'priorities'].includes(key)) return 'doFirst';
  if (['today', 'events', 'calendar', 'agenda'].includes(key)) return 'today';
  if (['agents', 'agent', 'tasks'].includes(key)) return 'agents';
  if (['fyi', 'info', 'worthknowing'].includes(key)) return 'fyi';
  return null;
}

/** A verb's own name: aliases mapped ("draft" → draft_reply, "snooze" → remind), unknown ones kept. */
export function verb(value) {
  const key = text(value).toLowerCase().replace(/[-\s]+/g, '_');
  if (['draft', 'reply', 'draftreply', 'draft_reply', 'create_draft'].includes(key)) return 'draft_reply';
  if (['task', 'make_t3_task', 't3_task', 'maketask', 'make_task', 'new_task'].includes(key)) return 'make_task';
  if (['block', 'block_time', 'blocktime'].includes(key)) return 'block_time';
  if (['remind', 'remind_me', 'remindme', 'snooze'].includes(key)) return 'remind';
  if (['done', 'complete', 'mark_done'].includes(key)) return 'done';
  if (['dismiss', 'hide'].includes(key)) return 'dismiss';
  if (['open', 'open_gmail', 'view'].includes(key)) return 'open';
  return key;
}

export function verbLabel(type) {
  return LABELS[type] || type.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase());
}

export function verbIcon(type) {
  return ICONS[type] || 'sparkles';
}

/** The item's state once the bridge said yes to `type` (nothing for Open). */
export function resultingState(type) {
  return STATES[type] || null;
}

export function stateLine(state) {
  return STATE_LINES[state] || '';
}

/** "4:40 PM" today, "Thu 9:00 AM" another day (en-US, this Mac's zone). */
export function remindWhen(ms, now = Date.now()) {
  const d = new Date(ms);
  const time = d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  return localDay(ms) === localDay(now) ? time : `${d.toLocaleDateString('en-US', { weekday: 'short' })} ${time}`;
}

/** What a handled item's line says: its state, and for a reminder when it is ("Reminder set for 4:40 PM"). */
export function itemStateLine(item, now = Date.now()) {
  if ((item.state === 'reminded' || item.state === 'snoozed') && item.remindAt) {
    return `Reminder set for ${remindWhen(item.remindAt, now)}`;
  }
  return stateLine(item.state);
}

function normalizeItem(raw, fallback) {
  if (!raw || typeof raw !== 'object') return null;
  const id = text(raw.id);
  if (!id) return null;
  const section = sectionKind(raw.section) || fallback;
  let kind = text(raw.kind || raw.type).toLowerCase();
  if (!kind) kind = { today: 'event', agents: 'agent', fyi: 'fyi' }[section] || 'email';
  const actions = [];
  for (const entry of Array.isArray(raw.actions) ? raw.actions : []) {
    const name = typeof entry === 'string' ? entry : entry && typeof entry === 'object' ? (entry.type || entry.action || entry.id) : '';
    if (!text(name)) continue;
    const type = verb(name);
    if (actions.some((a) => a.type === type)) continue;
    const label = entry && typeof entry === 'object' && text(entry.label) ? text(entry.label) : verbLabel(type);
    actions.push({ type, label, url: entry && typeof entry === 'object' ? text(entry.url) || null : null });
  }
  const account = text(raw.account);
  const accountIsEmail = account.includes('@');
  const state = text(raw.state).toLowerCase() || 'open';
  // The bridge keeps an action's result on the item: a Draft reply's Gmail draft opens again from it.
  const result = raw.result && typeof raw.result === 'object' ? raw.result : {};
  return {
    id,
    section,
    kind,
    account: accountIsEmail || !account ? null : account.toLowerCase(),
    accountEmail: text(raw.accountEmail) || (accountIsEmail ? account : null),
    title: oneLine(raw.title) || 'Untitled',
    why: oneLine(raw.why || raw.detail || raw.subtitle),
    suggestion: oneLine(raw.suggestion) || null,
    actions,
    state,
    url: text(raw.url || raw.openUrl || raw.link) || null,
    draftUrl: state === 'drafted' ? text(result.url || raw.draftUrl) || null : null,
    remindAt: state === 'reminded' || state === 'snoozed' ? toMs(result.until) : null,
    startsAt: toMs(raw.startsAt || raw.start),
    endsAt: toMs(raw.endsAt || raw.end),
    conflict: raw.conflict === true || kind === 'conflict',
    inboxItemId: text(raw.inboxItemId || raw.itemId) || null,
  };
}

/**
 * One answer of GET /v1/desktop/briefing (or its {briefing: …} wrapper). The bridge's: `{available, status: ready |
 * building | waiting | failed | off, date, revision, generatedAt, headline, spoken, needsYou, sections: [{id, title,
 * items}], accounts, counts}`. Normalized: `{available, status, date, revision, updatedAt, headline, spoken, reason,
 * counts, sections: {doFirst, today, agents, fyi}}` (each a list, capped 3/5/3/3). Null for nothing usable.
 */
export function normalizeBriefing(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  let body = raw;
  if (raw.briefing && typeof raw.briefing === 'object') {
    body = { available: raw.available, status: raw.status, ...raw.briefing };
  }
  const buckets = { doFirst: [], today: [], agents: [], fyi: [] };
  const add = (list, kind) => {
    for (const entry of Array.isArray(list) ? list : []) {
      const section = kind || sectionKind(entry && entry.section) || 'fyi';
      const item = normalizeItem(entry, section);
      if (item && !buckets[item.section].some((i) => i.id === item.id)) buckets[item.section].push(item);
    }
  };
  if (Array.isArray(body.sections)) {
    for (const section of body.sections) {
      if (!section || typeof section !== 'object') continue;
      add(section.items, sectionKind(section.kind || section.id || section.title));
    }
  } else if (body.sections && typeof body.sections === 'object') {
    for (const [key, list] of Object.entries(body.sections)) add(list, sectionKind(key));
  }
  for (const [key, value] of Object.entries(body)) {
    if (key !== 'sections' && key !== 'items' && Array.isArray(value) && sectionKind(key)) add(value, sectionKind(key));
  }
  add(body.items, null);
  const sections = {};
  let count = 0;
  for (const kind of SECTIONS) {
    sections[kind] = buckets[kind].slice(0, CAPS[kind]);
    count += sections[kind].length;
  }
  const status = text(body.status).toLowerCase() || (count ? 'ready' : 'off');
  return {
    available: typeof body.available === 'boolean' ? body.available : status !== 'off' && count > 0,
    status,
    date: text(body.date) || null,
    revision: Number.isFinite(body.revision) ? body.revision : 0,
    updatedAt: toMs(body.generatedAt || body.updatedAt || body.builtAt),
    headline: oneLine(body.headline),
    spoken: text(body.spoken),
    reason: text(body.reason) || null,
    skipped: body.skipped && typeof body.skipped === 'object' ? body.skipped : null,
    counts: body.counts && typeof body.counts === 'object' ? body.counts : null,
    sections,
    count,
  };
}

/**
 * "Read 105 emails · 12 worth a look": what the brief looked at, for trust (empty when the bridge didn't say). The
 * bridge's `counts: {emails, kept}`; the research draft's `skipped: {promotions, business, personal}` too.
 */
export function skippedLine(brief) {
  const count = (value) => (Number.isFinite(value) && value > 0 ? value : 0);
  const counts = brief && brief.counts;
  if (counts && count(counts.emails)) {
    const read = count(counts.emails);
    const kept = count(counts.kept);
    return `Read ${read} email${read === 1 ? '' : 's'}${kept && kept < read ? ` · ${kept} worth a look` : ''}`;
  }
  const skipped = brief && brief.skipped;
  if (!skipped) return '';
  const read = count(skipped.business) + count(skipped.personal);
  const parts = [];
  if (read) parts.push(`Read ${read} email${read === 1 ? '' : 's'}`);
  if (count(skipped.promotions)) parts.push(`skipped ${count(skipped.promotions)} promotions and newsletters`);
  const line = parts.join(' · ');
  return line ? line[0].toUpperCase() + line.slice(1) : '';
}

/** "YYYY-MM-DD" of `ms` in this Mac's own time zone. */
export function localDay(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** Home shows it: today's brief, with something in it, before noon (`force`: dev shots at any hour). */
export function isMorning(brief, now = Date.now(), { force = false } = {}) {
  if (!brief || !brief.available || !brief.count) return false;
  if (!force && new Date(now).getHours() >= MORNING_ENDS_AT) return false;
  if (force) return true;
  if (brief.date) return brief.date === localDay(now);
  return brief.updatedAt ? localDay(brief.updatedAt) === localDay(now) : true;
}

export function isOpen(item) {
  return !['done', 'dismissed', 'reminded', 'snoozed'].includes(item.state);
}

/** Drafted, a task made, time blocked, put off with a reminder: shown quieter, with what happened. */
export function isHandled(item) {
  return ['drafted', 'tasked', 'blocked', 'reminded', 'snoozed'].includes(item.state);
}

/** What Samin still has to deal with: Do first and Agents (events and FYI ask nothing). */
export function openCount(brief) {
  if (!brief) return 0;
  return [...brief.sections.doFirst, ...brief.sections.agents].filter((i) => isOpen(i) && !isHandled(i)).length;
}

/** The buttons: the item's own verbs (two at most, Done and Dismiss aside). */
export function primaryActions(item) {
  return item.actions.filter((a) => a.type !== 'done' && a.type !== 'dismiss').slice(0, 2);
}

/** Home's panel: done and dismissed items leave; events that are over leave. */
export function shownSections(brief, now = Date.now()) {
  if (!brief) return [];
  const rows = {
    doFirst: brief.sections.doFirst.filter((i) => i.state !== 'done' && i.state !== 'dismissed'),
    today: brief.sections.today.filter((i) => (i.endsAt || i.startsAt || now) >= now),
    agents: brief.sections.agents.filter((i) => i.state !== 'done' && i.state !== 'dismissed'),
    fyi: brief.sections.fyi.filter((i) => i.state !== 'done' && i.state !== 'dismissed'),
  };
  return SECTIONS.filter((kind) => rows[kind].length).map((kind) => ({ kind, title: SECTION_TITLES[kind], items: rows[kind] }));
}

/**
 * The same brief with one item's state changed (an action's result, shown at once; or its rollback); `patch` adds
 * what came with it (a reminder's `remindAt`).
 */
export function withItemState(brief, id, state, patch = null) {
  if (!brief) return brief;
  const sections = {};
  for (const kind of SECTIONS) sections[kind] = brief.sections[kind].map((i) => (i.id === id ? { ...i, state, ...(patch || {}) } : i));
  return { ...brief, sections };
}

export function findItem(brief, id) {
  if (!brief) return null;
  for (const kind of SECTIONS) {
    const item = brief.sections[kind].find((i) => i.id === id);
    if (item) return item;
  }
  return null;
}

/** What an action answered: `{ok, item: {…, state}, result: {draftId?, url?, itemId?, eventId?, until?}, revision}`. */
export function actResult(raw) {
  const body = raw && typeof raw === 'object' ? raw : {};
  const result = body.result && typeof body.result === 'object' ? body.result : {};
  const item = body.item && typeof body.item === 'object' ? body.item : {};
  return {
    state: text(body.state || item.state) || null,
    url: text(result.url || body.url) || null,
    itemId: text(result.itemId || body.itemId) || null,
    draftId: text(result.draftId) || null,
    until: toMs(result.until),
  };
}

/**
 * "Make task" starts a T3 agent (tools and all) from an email: its words are the ones the brief shows (the item's title
 * and why), sent as the action's `text`, never the model's own `taskText` (written from the email Samin never sees);
 * Home shows them before it starts. The dock's DockBriefTask.
 */
export function taskText(item) {
  const title = text(item && item.title);
  const why = text(item && item.why);
  if (!why) return title;
  if (!title) return why;
  return title + ('.?!…'.includes(title.at(-1)) ? ' ' : '. ') + why;
}

/** What the bridge puts after the words (samrabbit_briefing `_task`): for an email, a line naming it. */
export function taskAdded(item) {
  return item && item.kind === 'email' ? 'SamRabbit adds which email it came from (sender and subject).' : null;
}

/** "Remind me": in an hour, at 2 PM, tonight at 6, tomorrow at 9 (each only while it is still ahead). */
export function remindChoices(now = Date.now()) {
  const at = (hour, days = 0) => {
    const d = new Date(now);
    d.setDate(d.getDate() + days);
    d.setHours(hour, 0, 0, 0);
    return d.getTime();
  };
  const choices = [{ label: 'In 1 hour', at: now + 3_600_000 }];
  if (at(14) - now >= 30 * 60_000) choices.push({ label: '2 PM', at: at(14) });
  if (at(18) - now >= 30 * 60_000) choices.push({ label: 'Tonight 6 PM', at: at(18) });
  choices.push({ label: 'Tomorrow 9 AM', at: at(9, 1) });
  return choices;
}

/** "2026-10-14T14:00:00-04:00": a moment in this Mac's time, with its offset (what the bridge reads). */
export function isoLocal(ms) {
  const d = new Date(ms);
  const pad = (n) => String(Math.abs(n)).padStart(2, '0');
  const offset = -d.getTimezoneOffset();
  const sign = offset >= 0 ? '+' : '-';
  return `${localDay(ms)}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}${sign}${pad(Math.floor(Math.abs(offset) / 60))}:${pad(Math.abs(offset) % 60)}`;
}

/**
 * A Gmail link in `email`'s mailbox: Google opens /mail/u/0/ in whichever account comes first in the browser, so a
 * personal thread would open in the business account. `authuser` picks it (the bridge's own choice stays).
 */
export function withAccount(link, email) {
  if (!link || !email || !email.includes('@')) return link;
  let url;
  try {
    url = new URL(link);
  } catch {
    return link;
  }
  if (url.hostname.toLowerCase() !== 'mail.google.com' || url.searchParams.has('authuser')) return link;
  url.searchParams.set('authuser', email);
  return url.toString();
}

/** A meeting's "Join" (Open with a web link): Today's rows offer it. */
export function joinAction(item) {
  if (!item || !item.url || !isWebLink(item.url)) return null;
  return item.actions.find((a) => a.type === 'open') || null;
}

/** Only web links open (never `file:`, `javascript:` or an app's own scheme from a brief). */
export function isWebLink(link) {
  try {
    const url = new URL(link);
    return (url.protocol === 'https:' || url.protocol === 'http:') && Boolean(url.hostname);
  } catch {
    return false;
  }
}
