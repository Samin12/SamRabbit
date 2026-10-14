// Home's "Morning brief" panel (CONTRACTS-WAVE8 §D2), at the top until noon: the brief's headline; Do first, each item
// with its verbs as buttons (Hark-style: the verb is the button), Done and Dismiss; today's next events (a clash
// flagged); the agents waiting (they open in Tasks); FYI. Actions show their result at once and roll back with a short
// note when the bridge says no. Draft reply makes a Gmail draft on the bridge (never sent) and opens it in the browser,
// in the item's own Google account. The rules are briefing.js's (the same as the dock's Morning section).

import {
  actResult, findItem, isHandled, isMorning, isWebLink, isoLocal, itemStateLine, joinAction, openCount, primaryActions,
  remindChoices, remindWhen, resultingState, shownSections, skippedLine, taskAdded, taskText, verbIcon, withAccount,
  withItemState,
} from './briefing.js';
import { h } from './dom.js';
import { timeLabel } from './format.js';
import { icon } from './icons.js';
import { params } from './native.js';
import { closePopover, openExternal, popover, spinner, toast } from './ui.js';

const KIND_ICONS = { email: 'mail', conflict: 'alert', event: 'calendar', agent: 'sparkles', fyi: 'info' };
/** After Refresh, the brief is read again until it is built: at most this many long polls of this many seconds. */
const REFRESH_POLLS = 5;
const REFRESH_WAIT = 25;

export function createMorning(ctx, { onChange } = {}) {
  const { briefing } = ctx;
  /** Item id → the state an action gave it (until the next read says so), what came with it, the action on its way. */
  const overrides = new Map();
  const patches = new Map();
  const busy = new Map();
  /** Item id → the Gmail draft it opened. */
  const drafts = new Map();
  let refreshing = false;
  // Dev shots at any hour (shoot.sh: ?morning=1).
  const force = params.has('morning');

  function brief() {
    let value = briefing.value;
    for (const [id, state] of overrides) value = withItemState(value, id, state, patches.get(id));
    return value;
  }

  function changed() {
    onChange?.();
  }

  briefing.on(() => {
    // A fresh read is the truth: what the actions changed is in it.
    if (!briefing.loading) {
      overrides.clear();
      patches.clear();
    }
    changed();
  });

  function open(link, item) {
    const target = withAccount(link, item && item.accountEmail);
    if (isWebLink(target)) openExternal(target);
  }

  async function act(item, type, { at = null } = {}) {
    if (busy.has(item.id)) return;
    closePopover();
    if (type === 'open') {
      if (item.inboxItemId && !item.url) {
        ctx.show('tasks', { item: item.inboxItemId });
        return;
      }
      if (item.url) {
        open(item.url, item);
        return;
      }
    }
    const state = resultingState(type);
    const before = overrides.has(item.id) ? overrides.get(item.id) : null;
    const patchBefore = patches.get(item.id) || null;
    if (state) overrides.set(item.id, state);
    if (type === 'remind' && at) patches.set(item.id, { remindAt: at });
    busy.set(item.id, type);
    changed();
    try {
      // The task's words are the ones Samin read (taskText), not the model's hidden ones.
      const body = { action: type, ...(at ? { at: isoLocal(at) } : {}), ...(type === 'make_task' ? { text: taskText(item) } : {}) };
      const answer = actResult(await ctx.api.briefingAct(item.id, body));
      if (answer.state) overrides.set(item.id, answer.state);
      if (answer.until) patches.set(item.id, { remindAt: answer.until });
      if (type === 'draft_reply') {
        if (answer.url) {
          drafts.set(item.id, answer.url);
          open(answer.url, item);
        }
        toast('Saved as a draft in Gmail. Nothing was sent.', { tone: 'ok' });
      } else if (type === 'make_task') {
        toast('Started as a T3 task', {
          tone: 'ok', action: answer.itemId ? { label: 'Show', run: () => ctx.show('tasks', { item: answer.itemId }) } : null,
        });
      } else if (type === 'block_time') {
        toast('Blocked on your calendar', { tone: 'ok' });
      } else if (type === 'remind') {
        // The bridge puts a 15-minute "Reminder: …" on the calendar at that time.
        toast(answer.until ? `Reminder on your calendar for ${remindWhen(answer.until)}` : 'Reminder on your calendar', { tone: 'ok' });
      } else if (type === 'open' && answer.url) {
        open(answer.url, item);
      }
      busy.delete(item.id);
      changed();
      setTimeout(() => briefing.refresh(), 800);
    } catch (failure) {
      busy.delete(item.id);
      if (before) overrides.set(item.id, before);
      else overrides.delete(item.id);
      if (patchBefore) patches.set(item.id, patchBefore);
      else patches.delete(item.id);
      changed();
      toast(failure && failure.status === 0 ? 'The Mac bridge isn’t answering.'
        : `That didn’t work${failure && failure.detail ? `: ${failure.detail}` : '.'}`, { tone: 'error' });
    }
  }

  function remind(item, anchor) {
    const node = popover(anchor, [
      h('div', { class: 'popover-title' }, icon('bell', { size: 15 }), h('span', { text: 'Remind me' })),
      h('div', { class: 'popover-sub', text: 'A short reminder goes on your calendar then.' }),
      h('div', { class: 'block-chips' }, remindChoices().map((choice) => h('button', {
        class: 'chip-btn', type: 'button', onclick: () => act(item, 'remind', { at: choice.at }),
      }, choice.label))),
    ], { width: 300, align: 'start' });
    return node;
  }

  /** "Make task" asks first: the exact words the T3 task starts with, what the bridge adds, then Start task. */
  function confirmTask(item, anchor) {
    const added = taskAdded(item);
    return popover(anchor, [
      h('div', { class: 'popover-title' }, icon('plus', { size: 15 }), h('span', { text: 'New T3 task' })),
      h('div', { class: 'popover-sub', text: 'It starts with these words:' }),
      h('div', { class: 'task-words', text: taskText(item) }),
      added ? h('div', { class: 'popover-sub', text: added }) : null,
      h('div', { class: 'popover-buttons' },
        h('button', { class: 'chip-btn', type: 'button', onclick: () => closePopover() }, h('span', { text: 'Cancel' })),
        h('button', { class: 'chip-btn primary', type: 'button', onclick: () => act(item, 'make_task') },
          icon('plus', { size: 13 }), h('span', { text: 'Start task' }))),
    ], { width: 340, align: 'start' });
  }

  /**
   * Refresh: the bridge builds the brief again (tens of seconds: the mail, then Claude); "Reading…" stays until the new
   * one is there (a long poll past the revision it answered, a few times), or says why it didn't.
   */
  async function refresh() {
    if (refreshing) return;
    refreshing = true;
    changed();
    try {
      const started = await ctx.api.briefingRefresh();
      toast('Reading your mail again…');
      let after = started && Number.isFinite(started.revision) ? started.revision : briefing.value && briefing.value.revision;
      for (let i = 0; i < REFRESH_POLLS; i += 1) {
        const next = await ctx.api.briefing({ ...(Number.isFinite(after) ? { after } : {}), wait: REFRESH_WAIT });
        if (!next || next.status !== 'building') break;
        after = next.revision;
      }
      await briefing.refresh();
    } catch (failure) {
      // At most one build every 5 minutes on the bridge (429 refresh_too_soon).
      toast(failure && failure.status === 429 ? 'It was read a moment ago. Try again in a few minutes.'
        : 'The bridge couldn’t read the mail again right now.', { tone: failure && failure.status === 429 ? undefined : 'error' });
    } finally {
      refreshing = false;
      changed();
    }
  }

  // ------------------------------------------------------------------ drawing

  function verbButton(item, action, primary) {
    const working = busy.get(item.id) === action.type;
    return h('button', {
      class: `chip-btn brief-verb${primary ? ' primary' : ''}`, type: 'button', disabled: busy.has(item.id),
      onclick: (event) => (action.type === 'remind' ? remind(item, event.currentTarget)
        : action.type === 'make_task' ? confirmTask(item, event.currentTarget) : act(item, action.type)),
    }, working ? spinner() : icon(verbIcon(action.type), { size: 13 }),
    h('span', { text: working && action.type === 'draft_reply' ? 'Drafting…' : action.label }));
  }

  function iconButton(name, title, onclick, disabled = false) {
    return h('button', { class: 'brief-icon', type: 'button', title, 'aria-label': title, disabled, onclick }, icon(name, { size: 14 }));
  }

  function row(item) {
    const handled = isHandled(item);
    const tag = item.account ? h('span', { class: 'brief-tag', text: item.account === 'personal' ? 'Personal' : 'Work' }) : null;
    let foot;
    if (handled) {
      const draft = drafts.get(item.id) || item.draftUrl || (item.state === 'drafted' ? item.url : null);
      foot = h('div', { class: 'brief-actions' },
        h('span', { class: 'brief-state' }, icon(item.state === 'reminded' ? 'bell' : 'check', { size: 13 }),
          h('span', { text: itemStateLine(item) })),
        h('span', { class: 'brief-spacer' }),
        draft ? h('button', { class: 'chip-btn', type: 'button', onclick: () => open(draft, item) }, icon('external', { size: 13 }),
          h('span', { text: 'Open draft' })) : null,
        iconButton('check', 'Done', () => act(item, 'done')));
    } else {
      foot = h('div', { class: 'brief-actions' },
        primaryActions(item).map((action, index) => verbButton(item, action, index === 0)),
        h('span', { class: 'brief-spacer' }),
        iconButton('check', 'Done', () => act(item, 'done'), busy.has(item.id)),
        iconButton('close', 'Dismiss: not today', () => act(item, 'dismiss'), busy.has(item.id)));
    }
    return h('div', { class: `brief-row kind-${item.kind}${handled ? ' handled' : ''}${item.conflict ? ' conflict' : ''}` },
      h('span', { class: 'brief-glyph' }, icon(KIND_ICONS[item.kind] || 'info', { size: 15 })),
      h('div', { class: 'brief-main' },
        h('div', { class: 'brief-top' }, h('span', { class: 'brief-title', text: item.title }), tag),
        !handled && item.why ? h('div', { class: 'brief-why', text: item.why }) : null,
        foot));
  }

  function eventRow(event, now) {
    const started = event.startsAt && event.startsAt <= now;
    const join = joinAction(event);
    return h('div', { class: `brief-event${started ? ' now' : ''}${event.conflict ? ' conflict' : ''}${join ? ' joinable' : ''}` },
      h('span', { class: 'brief-event-time', text: event.startsAt ? timeLabel(event.startsAt) : 'All day' }),
      h('span', { class: 'brief-event-title', text: event.title }),
      event.conflict ? h('span', { class: 'brief-clash', text: 'Clash' }) : null,
      // A meeting's link (the bridge's "Join"), opened in the browser.
      join ? h('button', { class: 'chip-btn small brief-join', type: 'button', onclick: () => act(event, 'open') },
        icon('video', { size: 12 }), h('span', { text: join.label })) : null,
      event.why ? h('span', { class: 'brief-event-why', text: event.why }) : null);
  }

  function simpleRow(item) {
    return h('div', { class: `brief-line kind-${item.kind}` },
      h('span', { class: 'brief-glyph small' }, icon(KIND_ICONS[item.kind] || 'info', { size: 13 })),
      h('div', { class: 'brief-main' },
        h('div', { class: 'brief-top' }, h('span', { class: 'brief-title', text: item.title }),
          item.account ? h('span', { class: 'brief-tag', text: item.account === 'personal' ? 'Personal' : 'Work' }) : null),
        item.why ? h('div', { class: 'brief-why', text: item.why }) : null),
      item.actions.some((a) => a.type === 'open') || item.url || item.inboxItemId
        ? h('button', { class: 'chip-btn small', type: 'button', onclick: () => act(item, 'open') },
          h('span', { text: item.kind === 'agent' ? 'Open in Tasks' : 'Open' })) : null,
      iconButton('close', 'Dismiss', () => act(item, 'dismiss'), busy.has(item.id)));
  }

  /** The panel, or null when there is no brief to show (afternoon, not today's, not built). */
  function render(now = Date.now()) {
    const value = brief();
    if (!isMorning(value, now, { force })) return null;
    const sections = Object.fromEntries(shownSections(value, now).map((s) => [s.kind, s.items]));
    const first = sections.doFirst || [];
    const left = openCount(value);
    const side = [];
    if (sections.today) {
      side.push(h('div', { class: 'brief-group' }, h('div', { class: 'brief-label', text: 'Today' }),
        h('div', { class: 'brief-events' }, sections.today.map((e) => eventRow(e, now)))));
    }
    if (sections.agents) {
      side.push(h('div', { class: 'brief-group' }, h('div', { class: 'brief-label', text: 'Agents' }), sections.agents.map(simpleRow)));
    }
    if (sections.fyi) {
      side.push(h('div', { class: 'brief-group' }, h('div', { class: 'brief-label', text: 'FYI' }), sections.fyi.map(simpleRow)));
    }
    return h('section', { class: 'card morning' },
      h('header', { class: 'card-head morning-head' },
        h('span', { class: 'morning-sun' }, icon('sun', { size: 15 })),
        h('h2', { class: 'card-title', text: 'Morning brief' }),
        value.updatedAt ? h('span', { class: 'morning-time', text: timeLabel(value.updatedAt) }) : null,
        h('span', { class: `count${left ? ' on' : ''}`, text: String(left) }),
        h('button', {
          class: 'card-link', type: 'button', disabled: refreshing, title: 'Read the mail again (at most every 5 minutes)',
          onclick: () => refresh(),
        }, refreshing ? spinner() : icon('refresh', { size: 13 }), h('span', { text: refreshing ? 'Reading…' : 'Refresh' }))),
      value.headline ? h('p', { class: 'morning-headline', text: value.headline }) : null,
      h('div', { class: 'morning-grid' },
        h('div', { class: 'morning-col' },
          h('div', { class: 'brief-label', text: 'Do first' }),
          first.length ? h('div', { class: 'brief-rows' }, first.map(row))
            : h('div', { class: 'card-empty' }, icon('checkCircle', { size: 18 }), h('span', { text: 'Nothing to do first. Enjoy the morning.' })),
          skippedLine(value) ? h('div', { class: 'morning-foot' }, icon('mail', { size: 12 }), h('span', { text: skippedLine(value) })) : null),
        side.length ? h('div', { class: 'morning-col side' }, side) : null));
  }

  /** What the panel shows, to know when to draw it again. */
  function key(now = Date.now()) {
    const value = briefing.value;
    return JSON.stringify([value && value.revision, value && value.date, [...overrides], [...patches], [...busy], refreshing,
      isMorning(brief(), now, { force }), Math.floor(now / 60_000)]);
  }

  return { render, key, act, findItem: (id) => findItem(brief(), id) };
}
