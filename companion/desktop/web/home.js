// Home: what needs Samin and what is running (the agent inbox), the next three events, the R1 / iPhone / Watch, the
// latest conversation, and the quick actions (New task, Talk, Voice note, Block time, Journal note). Until noon the
// morning brief sits at the top (morning.js, CONTRACTS-WAVE8 §D2).

import { openBlockTime, openJournalNote } from './actions.js';
import { relativeStart, timeRange, upcoming } from './agenda.js';
import { h } from './dom.js';
import { icon } from './icons.js';
import { needsYou, recommendedOption, supports } from './inbox.js';
import { approvalCard, itemRow, shortAgo } from './items.js';
import { createMorning } from './morning.js';
import { nativeState, onNative, postNative } from './native.js';
import { normalizeNote, quickAction as noteAction } from './note.js';
import { createOrb } from './orb.js';
import { deviceRows, greeting, headline, summaryDevices } from './status.js';
import { openExternal, redrawWhenFree, reportDragExclusions, toast } from './ui.js';

export function createHome(ctx, el) {
  const { agents, summary, agenda, chats } = ctx;
  let visible = false;
  let devices = null;
  let devicesAt = 0;
  const heroOrb = createOrb({ size: 132, energy: 0.16, speed: 0.9, className: 'home-orb' });
  const morning = createMorning(ctx, { onChange: () => render() });
  let noteButton = null;

  const head = h('header', { class: 'view-head titlebar' });
  const body = h('div', { class: 'view-scroll' });
  const content = h('div', { class: 'home' });
  body.append(content);
  el.append(head, body);

  function quickAction(label, glyph, onclick, hint = '') {
    return h('button', { class: 'quick', type: 'button', onclick, title: hint || label },
      h('span', { class: 'quick-icon' }, icon(glyph, { size: 16 })), h('span', { text: label }));
  }

  function card(title, { count = null, action = null, tone = '', className = '' } = {}, ...children) {
    return h('section', { class: `card ${className} ${tone}`.trim() },
      h('header', { class: 'card-head' },
        h('h2', { class: 'card-title', text: title }),
        count != null ? h('span', { class: `count${count ? ' on' : ''}`, text: String(count) }) : null,
        action ? h('button', { class: 'card-link', type: 'button', onclick: action.run }, h('span', { text: action.label }), icon('chevronRight', { size: 13 })) : null),
      ...children);
  }

  function needsCard(now) {
    const items = agents.items.filter(needsYou);
    const rows = items.slice(0, 5).map((item) => {
      const approval = supports(item, 'approve') ? item.pending.approvals[0] : null;
      const option = approval ? recommendedOption(approval) : null;
      const row = itemRow(item, {
        now, busy: agents.busy.get(item.id) || '', onclick: () => ctx.show('tasks', { item: item.id }),
      });
      if (!approval || !option) return row;
      // The command is on screen before anything can be approved from Home: the card shows it.
      return h('div', { class: 'home-approval' }, row,
        approvalCard(item, approval, {
          busy: agents.busy.has(item.id), hint: false,
          onDecide: (decision) => agents.approve(item, approval.requestId, decision).then(() => render()),
        }));
    });
    const offline = agents.connection === 'offline';
    return card('Needs you', {
      count: offline ? null : items.length,
      action: { label: 'All tasks', run: () => ctx.show('tasks') },
      className: 'needs',
    }, rows.length ? h('div', { class: 'card-rows' }, rows)
      : h('div', { class: 'card-empty' }, icon(offline ? 'alert' : 'checkCircle', { size: 18 }),
        h('span', { text: offline ? 'The agent inbox isn’t answering.' : agents.connection === 'connecting' ? 'Loading…' : 'Nothing needs you right now.' })),
    items.length > 5 ? h('button', { class: 'card-more', type: 'button', onclick: () => ctx.show('tasks') }, `${items.length - 5} more in Tasks`) : null);
  }

  function workingCard(now) {
    const items = agents.items.filter((i) => i.status === 'working' && i.source !== 'samrabbit' && !needsYou(i));
    return card('Working', { count: items.length, action: { label: 'Tasks', run: () => ctx.show('tasks') } },
      items.length ? h('div', { class: 'card-rows' }, items.slice(0, 5).map((item) => itemRow(item, {
        now, compact: true, onclick: () => ctx.show('tasks', { item: item.id }),
      }))) : h('div', { class: 'card-empty' }, icon('sparkles', { size: 18 }), h('span', { text: 'No agent is working right now.' })),
      h('button', { class: 'card-cta', type: 'button', onclick: () => ctx.show('tasks', { compose: true }) },
        icon('plus', { size: 14 }), h('span', { text: 'New task' }), h('kbd', { class: 'keycap', text: 'N' })));
  }

  function upNextCard(now) {
    const value = agenda.value;
    let inner;
    if (!value && agenda.error) {
      inner = h('div', { class: 'card-empty' }, icon('calendar', { size: 18 }), h('span', { text: 'Google Calendar can’t be read right now.' }));
    } else if (!value) {
      inner = h('div', { class: 'card-empty' }, h('span', { class: 'spinner' }), h('span', { text: 'Loading your calendar…' }));
    } else {
      const next = upcoming(value.events, now, 3);
      inner = next.length ? h('div', { class: 'events' }, next.map((event) => h('div', { class: `event-row${event.start <= now ? ' now' : ''}` },
        h('div', { class: 'event-when' },
          h('div', { class: 'event-time', text: event.allDay ? 'All day' : timeRange(event) }),
          h('div', { class: 'event-rel', text: relativeStart(event, now) })),
        h('div', { class: 'event-bar' }),
        h('div', { class: 'event-main' },
          h('div', { class: 'event-title', text: event.title }),
          event.location && !event.meetingUrl ? h('div', { class: 'event-loc', text: event.location }) : null),
        event.meetingUrl ? h('button', { class: 'chip-btn join', type: 'button', onclick: () => openExternal(event.meetingUrl) },
          icon('video', { size: 13 }), h('span', { text: 'Join' })) : null)))
        : h('div', { class: 'card-empty' }, icon('sun', { size: 18 }), h('span', { text: 'Nothing else on your calendar today.' }));
    }
    return card('Up next', { action: { label: 'Calendar', run: () => ctx.show('calendar') } }, inner);
  }

  function devicesCard(now) {
    const rows = deviceRows(summary.value, summaryDevices(summary.value) || devices || [], now);
    const glyphs = { r1: 'r1', iphone: 'phone', watch: 'watch', mac: 'laptop' };
    const paired = rows.some((r) => r.kind === 'iphone' || r.kind === 'watch');
    return card('Devices', { action: { label: 'Settings', run: () => ctx.show('settings') } },
      summary.error && !summary.value ? h('div', { class: 'card-note', text: 'The bridge’s summary isn’t answering yet.' }) : null,
      h('div', { class: 'device-rows' }, rows.map((row) => h('div', { class: `device-row tone-${row.tone}` },
        h('span', { class: 'device-tile' }, icon(glyphs[row.kind] || 'circle', { size: 16 })),
        h('div', { class: 'device-main' }, h('div', { class: 'device-name', text: row.name }), h('div', { class: 'device-line', text: row.line })),
        row.battery != null ? h('span', { class: 'battery', title: `Battery ${row.battery}%` },
          h('span', { class: 'battery-shell' }, h('span', { class: 'battery-fill', style: `width:${row.battery}%` })),
          h('span', { text: `${row.battery}%` })) : h('span', { class: `presence tone-${row.tone}` })))),
      paired ? null : h('button', { class: 'card-cta', type: 'button', onclick: () => ctx.show('settings') },
        icon('phone', { size: 14 }), h('span', { text: 'Pair your iPhone' })));
  }

  function latestCard(now) {
    const latest = chats.store.list()[0];
    if (!latest) return null;
    return card('Latest conversation', { action: { label: 'Chats', run: () => ctx.show('chats') }, className: 'latest' },
      h('button', {
        class: 'latest-row', type: 'button',
        onclick: () => {
          ctx.show('chats');
          chats.openConversation(latest.conversationId);
        },
      },
      h('img', { class: 'latest-orb', src: 'orb.svg', alt: '' }),
      h('div', { class: 'latest-main' },
        h('div', { class: 'latest-top' },
          latest.live ? h('span', { class: 'live-dot' }) : null,
          h('span', { class: 'latest-title', text: latest.title || 'New conversation' }),
          h('time', { class: 'item-time', text: latest.live ? 'Live' : shortAgo(latest.lastAt, now) })),
        latest.preview ? h('div', { class: 'latest-preview', text: latest.preview }) : null)));
  }

  // Each part is redrawn only when what it shows changed (the inbox and the conversations change often; a redraw
  // under the pointer would swallow a click), and once a minute for its times.
  const slots = new Map();
  function slot(name) {
    if (!slots.has(name)) slots.set(name, { el: h('div', { class: 'slot' }), key: null });
    return slots.get(name).el;
  }
  function fill(name, key, build) {
    const entry = slots.get(name);
    if (entry.key === key) return;
    entry.key = key;
    entry.el.replaceChildren(...[build()].filter(Boolean));
  }
  content.append(slot('hero'), slot('morning'), h('div', { class: 'home-grid' },
    h('div', { class: 'home-col' }, slot('needs'), slot('working')),
    h('div', { class: 'home-col' }, slot('next'), slot('devices'), slot('latest'))));

  function heroCard(now, counts, next) {
    return h('section', { class: 'hero-card' },
      heroOrb,
      h('div', { class: 'hero-main' },
        h('h2', { class: 'hero-greeting', text: `${greeting(now)}, Samin` }),
        h('p', { class: 'hero-line', text: headline(counts, next, now) }),
        h('div', { class: 'quick-row' },
          quickAction('New task', 'plus', () => ctx.show('tasks', { compose: true }), 'New task (N)'),
          quickAction('Talk', 'mic', () => ctx.talk.start(), 'Talk to SamRabbit (⌃⌥Space)'),
          voiceNoteButton(),
          quickAction('Block time', 'calendar', (event) => openBlockTime(event.currentTarget, ctx.api, { onDone: () => agenda.refresh() })),
          quickAction('Journal note', 'note', () => openJournalNote(ctx.api)))));
  }

  /** Voice note: the shell records it (⌃⌥N, the dock's note button); a press here starts one, or sends the one going. */
  function voiceNoteButton() {
    noteButton = quickAction('Voice note', 'notePlus', () => {
      if (!postNative({ type: 'note', action: 'toggle' })) toast('Voice notes record in the SamRabbit app (the microphone is native).');
    });
    noteButton.classList.add('note-quick');
    patchNoteButton();
    return noteButton;
  }

  /** The button says what a press does now (patched in place: a push mid-click must not swallow it). */
  function patchNoteButton() {
    if (!noteButton) return;
    const note = normalizeNote(nativeState().note);
    const action = noteAction(note);
    const label = noteButton.querySelector('span:last-child');
    if (label && label.textContent !== action.label) label.textContent = action.label;
    if (noteButton.title !== action.hint) noteButton.title = action.hint;
    noteButton.classList.toggle('recording', action.recording);
    noteButton.disabled = action.busy;
  }

  function render() {
    // Never between a press and its release (an approval's buttons are in these cards; ui.js).
    if (visible) redrawWhenFree('home', draw);
  }

  function draw() {
    if (!visible) return;
    const now = Date.now();
    const minute = Math.floor(now / 60_000);
    const counts = agents.counts();
    const next = agenda.value ? upcoming(agenda.value.events, now, 1)[0] : null;
    const date = new Date(now).toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
    head.replaceChildren(h('h1', { class: 'view-title', text: 'Home' }), h('span', { class: 'view-meta', text: date }));
    heroOrb.orb.set({ energy: counts.working ? 0.24 : 0.14, speed: counts.working ? 1.3 : 0.85 });
    const needs = agents.items.filter(needsYou);
    const working = agents.items.filter((i) => i.status === 'working' && i.source !== 'samrabbit');
    const busy = [...agents.busy].join();
    fill('hero', JSON.stringify([counts, next && next.id, next && next.start, minute]), () => heroCard(now, counts, next));
    fill('morning', morning.key(now), () => morning.render(now));
    fill('needs', JSON.stringify([needs, busy, agents.connection, minute]), () => needsCard(now));
    fill('working', JSON.stringify([working, minute]), () => workingCard(now));
    fill('next', JSON.stringify([agenda.loadedAt, Boolean(agenda.error), minute]), () => upNextCard(now));
    fill('devices', JSON.stringify([summary.loadedAt, Boolean(summary.error), devices, minute]), () => devicesCard(now));
    const latest = chats.store.list()[0];
    fill('latest', JSON.stringify([latest || null, minute]), () => latestCard(now));
    reportDragExclusions();
  }

  async function loadDevices() {
    // Only while the window is on screen (the summary's own read brings them back when it is).
    if (!ctx.presence.watched || summaryDevices(summary.value) || Date.now() - devicesAt < 30_000) return;
    devicesAt = Date.now();
    try {
      const answer = await ctx.api.devices();
      devices = answer && Array.isArray(answer.devices) ? answer.devices : [];
      render();
    } catch {
      // the R1 and the Mac still show
    }
  }

  agents.on((what) => {
    if (what.inbox || what.item) render();
  });
  summary.on(() => {
    render();
    loadDevices();
  });
  agenda.on(() => render());
  setInterval(() => render(), 30_000);
  onNative((_state, changed) => {
    if (changed.includes('note')) patchNoteButton();
  });
  // The recording's time on the button.
  setInterval(() => {
    if (visible && nativeState().note && nativeState().note.state === 'recording') patchNoteButton();
  }, 1000);

  return {
    el,
    shown() {
      visible = true;
      summary.fresh(20_000);
      agenda.fresh(120_000);
      ctx.briefing.fresh(120_000);
      loadDevices();
      render();
    },
    hidden() {
      visible = false;
    },
    chatsChanged() {
      render();
    },
    handleKey() {
      return false;
    },
  };
}
