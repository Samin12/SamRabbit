// Chats: every SamRabbit conversation (R1, Watch, iPhone, Mac voice) live, as it happens (CONTRACTS-WAVE3 hop 3).
// The conversation list and the timeline of the selected one; the shell (app.js) shows it as the Chats view.

import { ApiError, SyncStream, api, pageHasMore } from './api.js';
import { tickTimers } from './cards.js';
import { h } from './dom.js';
import { clip, dayLabel, plural, relativeTime, shortWhen, stamp, toMs } from './format.js';
import { icon } from './icons.js';
import { postNative } from './native.js';
import { createOrb } from './orb.js';
import { ConversationStore } from './store.js';
import { TimelineView } from './timeline.js';
import { closeOverlay, copyText, openExternal, overlayOpen, reportDragExclusions, showOverlay, toast } from './ui.js';

const PAGE = 100;
const T3_URL = 'http://127.0.0.1:3773/';
const FOLLOW_IDLE_MS = 90 * 1000;
const RETRY_MS = [2000, 4000, 8000, 15000];

// ---------------------------------------------------------------------------- state

const $ = (id) => document.getElementById(id);
const els = {
  view: $('view-chats'), list: $('conversation-list'), search: $('search'), searchIcon: $('search-icon'),
  status: $('sync-status'), head: $('main-head'), scroller: $('scroller'), timeline: $('timeline'), state: $('state'),
  jump: $('jump'), foot: $('main-foot'),
};
els.searchIcon.append(icon('search', { size: 14 }));

const store = new ConversationStore();
const state = {
  selectedId: null,
  query: '',
  searchIds: null,
  listStatus: 'loading',
  listError: null,
  listAttempt: 0,
  streamState: 'connecting',
  lastInteraction: 0,
  hasMore: false,
  loadingMore: false,
  pageBefore: null, // lastAt (ms) where the next page of older conversations starts
  frameHeights: new Map(),
  openTools: new Set(),
  initialSelectionDone: false,
};

const ctx = {
  openTools: state.openTools,
  frameHeight: (id) => state.frameHeights.get(id) || 380,
  registerFrame: () => {},
  openImage,
  openArtifact,
  copyHtml,
  openT3,
};
const view = new TimelineView(els.timeline, ctx);

// ---------------------------------------------------------------------------- render scheduling

const dirty = new Set();
let frame = 0;
let fallback = 0;

// requestAnimationFrame pauses while the window is closed, occluded or the display sleeps; a timer
// fallback keeps the DOM current so everything is already there when the window comes back.
function schedule(...parts) {
  for (const part of parts) dirty.add(part);
  if (!frame) frame = requestAnimationFrame(flush);
  if (!fallback) fallback = setTimeout(flush, 250);
}

function flush() {
  if (frame) cancelAnimationFrame(frame);
  clearTimeout(fallback);
  frame = 0;
  fallback = 0;
  if (!dirty.size) return;
  const parts = new Set(dirty);
  dirty.clear();
  if (parts.has('list')) renderList();
  if (parts.has('status')) renderStatus();
  if ((parts.has('list') || parts.has('status')) && chats.onChange) chats.onChange();
  if (parts.has('head')) renderHead();
  if (parts.has('main')) renderMain();
  else if (parts.has('timeline')) renderTimeline();
  if (parts.has('foot')) renderFoot();
}

// ---------------------------------------------------------------------------- sidebar

function visibleConversations() {
  const all = store.list();
  if (!state.query) return all;
  const query = state.query.toLowerCase();
  const server = new Set(state.searchIds || []);
  return all.filter((c) => server.has(c.conversationId) || `${c.title} ${c.preview}`.toLowerCase().includes(query));
}

function conversationButton(c, now) {
  const selected = c.conversationId === state.selectedId;
  return h('button', {
    class: `conv${selected ? ' selected' : ''}${c.live ? ' live' : ''}`,
    type: 'button',
    dataset: { id: c.conversationId },
    'aria-current': selected ? 'true' : null,
    onclick: () => select(c.conversationId, { user: true }),
  },
  h('div', { class: 'conv-top' },
    c.live ? h('span', { class: 'live-dot', title: 'Live on your R1' }) : null,
    h('span', { class: 'conv-title', text: c.title || 'New conversation' }),
    h('time', { class: `conv-time${c.live ? ' live' : ''}`, text: c.live ? 'Live' : shortWhen(c.lastAt, now) })),
  c.preview ? h('div', { class: 'conv-preview', text: c.preview }) : null);
}

function skeletonList() {
  return h('div', { class: 'conv-skeleton' }, [0, 1, 2, 3, 4].map(() => h('div', { class: 'sk-row' }, h('span'), h('span'))));
}

function renderList() {
  const scrollTop = els.list.scrollTop;
  const now = Date.now();
  const children = [];
  if (state.listStatus === 'loading' && !store.byId.size) {
    children.push(skeletonList());
  } else if (state.listStatus === 'ok' && !store.byId.size) {
    children.push(h('div', { class: 'list-empty quiet', text: 'No conversations yet' }));
  } else {
    const conversations = visibleConversations();
    if (state.query && !conversations.length) {
      children.push(h('div', { class: 'list-empty' }, icon('search', { size: 18 }), h('div', { text: `Nothing matches “${clip(state.query, 40)}”` })));
    }
    let group = null;
    let groupEl = null;
    for (const c of conversations) {
      const label = c.live ? 'Live now' : dayLabel(c.lastAt, now);
      if (label !== group) {
        group = label;
        groupEl = h('section', { class: 'conv-group' }, h('h2', { class: `conv-group-title${c.live ? ' live' : ''}`, text: label }));
        children.push(groupEl);
      }
      groupEl.append(conversationButton(c, now));
    }
    if (!state.query && state.hasMore) {
      children.push(h('button', { class: 'load-more', type: 'button', onclick: loadMore, disabled: state.loadingMore },
        state.loadingMore ? 'Loading…' : 'Show older conversations'));
    }
  }
  els.list.replaceChildren(...children);
  els.list.scrollTop = scrollTop;
}

function lastSeenAt() {
  let latest = 0;
  for (const c of store.byId.values()) latest = Math.max(latest, c.lastAt || 0);
  return latest;
}

function renderStatus() {
  const now = Date.now();
  const live = store.list().some((c) => c.live);
  const seen = lastSeenAt();
  let tone;
  let line;
  if (state.listStatus === 'error') {
    const error = state.listError;
    tone = error && error.syncMissing ? 'warn' : 'error';
    line = error && error.status === 0 ? 'Bridge not reachable' : error && error.syncMissing ? 'Sync not on yet' : 'Sync unavailable';
  } else if (state.streamState !== 'live') {
    tone = 'warn';
    line = state.streamState === 'connecting' ? 'Connecting…' : 'Reconnecting…';
  } else if (live) {
    tone = 'live';
    line = 'Live conversation';
  } else {
    tone = 'ok';
    line = 'Synced with your R1';
  }
  els.status.replaceChildren(
    h('span', { class: `status-dot tone-${tone}` }),
    h('div', { class: 'status-text' },
      h('div', { class: 'status-line', text: line }),
      h('div', { class: 'status-sub', text: seen ? `R1 last seen ${relativeTime(seen, now)}` : 'Waiting for your R1' })));
}

// ---------------------------------------------------------------------------- main header / footer

function selectedSummary() {
  return state.selectedId ? store.get(state.selectedId) : null;
}

function renderHead() {
  const c = selectedSummary();
  if (!c) {
    els.head.replaceChildren();
    reportDragExclusions();
    return;
  }
  const timeline = store.timelines.get(c.conversationId);
  const metaBits = [stamp(c.startedAt)];
  if (c.messageCount) metaBits.push(plural(c.messageCount, 'message'));
  els.head.replaceChildren(
    h('div', { class: 'head-titles' },
      h('h1', { class: 'head-title', text: c.title || 'New conversation' }),
      c.live ? h('span', { class: 'live-badge' }, h('span', { class: 'live-dot' }), 'Live') : null,
      h('span', { class: 'head-meta', text: metaBits.join(' · ') })),
    h('div', { class: 'head-actions' },
      h('button', {
        class: 'icon-btn', type: 'button', title: 'Copy transcript',
        disabled: !(timeline && timeline.loaded),
        onclick: async () => {
          const ok = await copyText(timeline.transcript(c.title));
          toast(ok ? 'Transcript copied' : 'Could not copy');
        },
      }, icon('copy', { size: 15 }))));
  reportDragExclusions();
}

let footOrb = null;

function renderFoot() {
  const c = selectedSummary();
  if (!c || state.listStatus === 'error') {
    els.foot.replaceChildren();
    els.foot.hidden = true;
    return;
  }
  els.foot.hidden = false;
  const timeline = store.timelines.get(c.conversationId);
  const streaming = timeline ? view.hasStreaming(timeline, c.live) : false;
  if (c.live) {
    if (!footOrb) footOrb = createOrb({ size: 46, energy: 0.2, speed: 1.2, glow: 0.9, className: 'foot-orb' });
    footOrb.orb.set({ energy: streaming ? 0.55 : 0.2, speed: streaming ? 2.0 : 1.1 });
    els.foot.replaceChildren(h('div', { class: 'foot live' }, footOrb,
      h('div', null, h('div', { class: 'foot-title', text: streaming ? 'Your R1 is answering…' : 'Live on your R1' }),
        h('div', { class: 'foot-sub', text: 'Everything you say shows up here as it happens.' }))));
  } else {
    els.foot.replaceChildren(h('div', { class: 'foot' }, h('span', { class: 'foot-icon' }, icon('mic', { size: 14 })),
      h('div', { class: 'foot-sub', text: 'To continue, just talk to your R1. New messages appear here live.' })));
  }
}

// ---------------------------------------------------------------------------- main states

let heroOrb = null;

function heroState({ title, text, tone = '', actions = [], chips = [], code = '' }) {
  if (!heroOrb) heroOrb = createOrb({ size: 220, energy: 0.12, speed: 0.8, className: 'hero-orb' });
  heroOrb.orb.set({ glow: tone === 'error' ? 0.35 : 1, energy: tone === 'error' ? 0 : 0.12, speed: tone === 'error' ? 0.25 : 0.8 });
  return h('div', { class: `hero ${tone}` }, heroOrb,
    h('h2', { class: 'hero-title', text: title }),
    h('p', { class: 'hero-text', text }),
    code ? h('code', { class: 'hero-code', text: code }) : null,
    chips.length ? h('div', { class: 'hero-chips' }, chips.map(([glyph, label]) => h('span', { class: 'chip' }, icon(glyph, { size: 13 }), label))) : null,
    actions.length ? h('div', { class: 'hero-actions' }, actions) : null);
}

function errorCopy(error) {
  if (!error || error.status === 0) {
    return ['Waiting for the SamRabbit bridge…', 'The bridge on this Mac isn’t answering yet. SamRabbit keeps trying in the background.', ''];
  }
  if (error.syncMissing) {
    return ['Conversation sync isn’t on yet', 'This bridge doesn’t serve conversations yet. SamRabbit keeps checking; updating the bridge turns it on:', 'companion/mac-bridge/install.sh'];
  }
  if (error.status === 401 || error.status === 403) {
    return ['SamRabbit can’t sign in to the bridge', 'The desktop token was not accepted. Reinstall the desktop app, then reopen SamRabbit:', 'companion/desktop/install.sh'];
  }
  return ['Sync is having trouble', `The bridge answered with an error (HTTP ${error.status}). SamRabbit keeps retrying.`, ''];
}

function showState(node) {
  if (!node) {
    els.state.hidden = true;
    els.state.replaceChildren();
    els.timeline.hidden = false;
    return;
  }
  els.timeline.hidden = true;
  els.state.hidden = false;
  els.state.replaceChildren(node);
}

function renderMain() {
  if (state.listStatus === 'error' && !store.byId.size) {
    const [title, text, code] = errorCopy(state.listError);
    showState(heroState({
      title, text, code, tone: 'error',
      actions: [h('button', { class: 'btn', type: 'button', onclick: () => loadList({ manual: true }) }, icon('refresh', { size: 14 }), 'Retry now')],
    }));
    renderFoot();
    return;
  }
  if (state.listStatus === 'loading' && !store.byId.size) {
    showState(h('div', { class: 'loading-state' }, h('div', { class: 'spinner big' })));
    return;
  }
  if (!store.byId.size) {
    showState(heroState({
      title: 'Your R1 conversations live here',
      text: 'Talk to your Rabbit R1 and every conversation shows up here as it happens: what you said, the answers, cards, screenshots, photos and the UIs it builds on your Mac. Nothing gets lost.',
      chips: [['mic', 'Live transcripts'], ['monitor', 'Screenshots & photos'], ['sparkles', 'Generated UIs'], ['code', 'T3 updates']],
    }));
    renderFoot();
    return;
  }
  const c = selectedSummary();
  if (!c) {
    showState(h('div', { class: 'pick-state' }, icon('chevronRight', { size: 18 }), h('span', { text: 'Pick a conversation' })));
    renderFoot();
    return;
  }
  const timeline = store.timeline(c.conversationId);
  if (!timeline.loaded) {
    if (timeline.error) {
      showState(h('div', { class: 'inline-error' }, icon('alert', { size: 16 }),
        h('span', { text: 'This conversation could not be loaded.' }),
        h('button', { class: 'btn small', type: 'button', onclick: () => openTimeline(c.conversationId) }, 'Try again')));
    } else {
      showState(h('div', { class: 'timeline-skeleton' },
        h('div', { class: 'sk-bubble right' }), h('div', { class: 'sk-bubble' }), h('div', { class: 'sk-bubble wide' }),
        h('div', { class: 'sk-bubble right short' })));
    }
    renderFoot();
    return;
  }
  renderTimeline();
  renderFoot();
}

function nearBottom() {
  const s = els.scroller;
  return s.scrollHeight - s.scrollTop - s.clientHeight < 160;
}

function stickToBottom(smooth = false) {
  const s = els.scroller;
  if (smooth) s.scrollTo({ top: s.scrollHeight, behavior: 'smooth' });
  else s.scrollTop = s.scrollHeight;
  els.jump.hidden = true;
}

let pendingScrollToBottom = false;

function renderTimeline() {
  const c = selectedSummary();
  if (!c) return;
  const timeline = store.timelines.get(c.conversationId);
  if (!timeline || !timeline.loaded) return;
  if (!timeline.sorted().length) {
    showState(h('div', { class: 'pick-state' }, icon('mic', { size: 18 }),
      h('span', { text: c.live ? 'Listening on your R1…' : 'Nothing was said in this conversation.' })));
    return;
  }
  if (!els.state.hidden) showState(null);
  const wasNear = nearBottom();
  const before = els.timeline.childElementCount;
  view.render(timeline, { live: c.live });
  if (pendingScrollToBottom || wasNear) {
    pendingScrollToBottom = false;
    stickToBottom();
  } else if (els.timeline.childElementCount > before) {
    els.jump.hidden = false;
  }
}

// ---------------------------------------------------------------------------- selection and loading

function setHash(id) {
  const hash = id ? `#c=${encodeURIComponent(id)}` : '';
  if (location.hash !== hash) history.replaceState(null, '', `${location.pathname}${location.search}${hash}`);
}

function hashId() {
  const match = /^#c=(.+)$/.exec(location.hash);
  return match ? decodeURIComponent(match[1]) : null;
}

/**
 * Applies every event after the timeline's cursor, page by page, until the bridge says there is no
 * more (each page must advance the cursor, so this always ends). Returns whether anything changed.
 */
async function fetchEvents(timeline, id) {
  let changed = false;
  for (;;) {
    const after = timeline.cursor;
    const body = await api.events(id, after ?? undefined);
    for (const event of (body && Array.isArray(body.events) ? body.events : [])) changed = timeline.apply(event) || changed;
    if (body && body.cursor != null) timeline.cursor = body.cursor;
    if (!pageHasMore(body, after)) return changed;
  }
}

async function openTimeline(id) {
  const timeline = store.timeline(id);
  if (timeline.loading) return timeline.loading;
  timeline.error = null;
  schedule('main');
  timeline.loading = (async () => {
    try {
      await fetchEvents(timeline, id);
      timeline.loaded = true;
    } catch (error) {
      timeline.error = error;
    } finally {
      timeline.loading = null;
    }
    if (state.selectedId === id) {
      pendingScrollToBottom = true;
      schedule('main', 'head', 'foot');
    }
  })();
  return timeline.loading;
}

function select(id, { user = false } = {}) {
  if (user) state.lastInteraction = Date.now();
  if (!id || !store.get(id)) return;
  if (state.selectedId === id) {
    if (user) stickToBottom(true);
    return;
  }
  state.selectedId = id;
  try {
    localStorage.setItem('samrabbit.selected', id);
  } catch {
    // private mode
  }
  setHash(id);
  view.reset();
  els.jump.hidden = true;
  pendingScrollToBottom = true;
  const timeline = store.timeline(id);
  if (!timeline.loaded) openTimeline(id);
  else if (!timeline.loading) refreshTimeline(id);
  schedule('list', 'head', 'main', 'foot');
}

/** Fetches anything after the timeline's cursor (after a stream gap). */
async function refreshTimeline(id) {
  const timeline = store.timelines.get(id);
  if (!timeline || !timeline.loaded || timeline.loading || timeline.refreshing) return;
  timeline.refreshing = true;
  try {
    const changed = await fetchEvents(timeline, id);
    if (changed && state.selectedId === id) schedule('timeline', 'foot');
  } catch {
    // the next stream event or list refresh tries again
  } finally {
    timeline.refreshing = false;
  }
}

function chooseInitial() {
  if (state.initialSelectionDone || !store.byId.size) return;
  state.initialSelectionDone = true;
  let remembered = null;
  try {
    remembered = localStorage.getItem('samrabbit.selected');
  } catch {
    remembered = null;
  }
  const live = store.list().find((c) => c.live);
  const candidates = [hashId(), live && live.conversationId, remembered, store.list()[0].conversationId];
  const id = candidates.find((candidate) => candidate && store.get(candidate));
  if (id) select(id);
}

let listTimer = 0;

async function loadList({ manual = false, quiet = false } = {}) {
  clearTimeout(listTimer);
  if (manual) {
    state.listStatus = store.byId.size ? state.listStatus : 'loading';
    schedule('main', 'status');
  }
  try {
    const body = await api.conversations({ limit: PAGE });
    const list = body && Array.isArray(body.conversations) ? body.conversations : [];
    store.mergeList(list);
    if (state.pageBefore == null) {
      // The first page sets where "older" starts; later refreshes of the newest page never move it.
      state.pageBefore = nextBefore(body, list);
      state.hasMore = list.length >= PAGE;
    }
    const wasError = state.listStatus === 'error';
    state.listStatus = 'ok';
    state.listError = null;
    state.listAttempt = 0;
    postNative({ type: 'status', api: 'ok', conversations: store.byId.size, live: store.list().filter((c) => c.live).length });
    chooseInitial();
    if (wasError && state.selectedId) openTimeline(state.selectedId);
    schedule('list', 'status', 'head', 'main', 'foot');
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    if (!quiet || !store.byId.size) {
      state.listStatus = 'error';
      state.listError = error;
    }
    postNative({ type: 'status', api: error.syncMissing ? 'sync-missing' : 'error', status: error.status, code: error.code || '' });
    const delay = RETRY_MS[Math.min(state.listAttempt, RETRY_MS.length - 1)];
    state.listAttempt += 1;
    listTimer = setTimeout(() => loadList({ quiet: true }), delay);
    schedule('list', 'status', 'main', 'foot');
  }
}

/** Where the page after `body` starts: the bridge's nextBefore, else the last row's lastAt (ms). */
function nextBefore(body, list) {
  const last = list[list.length - 1];
  const value = toMs(body && body.nextBefore) ?? (last ? toMs(last.lastAt) ?? toMs(last.startedAt) : null);
  return value == null ? null : Math.floor(value); // the bridge takes whole epoch ms
}

async function loadMore() {
  // Pages follow their own boundary, not the oldest conversation on screen: a search can bring in a
  // much older one, and paging from it would skip everything in between.
  if (state.loadingMore || state.pageBefore == null) return;
  state.loadingMore = true;
  schedule('list');
  try {
    const body = await api.conversations({ limit: PAGE, before: state.pageBefore });
    const page = body && Array.isArray(body.conversations) ? body.conversations : [];
    store.mergeList(page);
    const next = nextBefore(body, page);
    state.hasMore = page.length >= PAGE && next != null && next < state.pageBefore;
    if (next != null) state.pageBefore = Math.min(state.pageBefore, next);
  } catch {
    toast('Could not load older conversations');
  } finally {
    state.loadingMore = false;
    schedule('list');
  }
}

let refreshListTimer = 0;
function scheduleListRefresh(delay = 1500) {
  clearTimeout(refreshListTimer);
  refreshListTimer = setTimeout(() => loadList({ quiet: true }), delay);
}

// ---------------------------------------------------------------------------- live stream

function onStreamEvent(event) {
  const result = store.applyEvent(event);
  if (!result) return;
  const id = result.conversationId;
  if (result.isNew || event.type === 'conversation.started' || event.type === 'conversation.ended') scheduleListRefresh();
  if (result.summaryChanged) schedule('list', 'status');
  if (id === state.selectedId) {
    if (result.summaryChanged) schedule('head', 'foot');
    if (result.timelineChanged) schedule('timeline', 'foot');
  }
  if (result.isNew || event.type === 'conversation.started') follow(id);
  if (!state.initialSelectionDone) {
    state.listStatus = state.listStatus === 'loading' ? 'ok' : state.listStatus;
    chooseInitial();
    schedule('main');
  }
}

function follow(id) {
  if (id === state.selectedId) return;
  const current = selectedSummary();
  const idle = Date.now() - state.lastInteraction > FOLLOW_IDLE_MS;
  if (!current || (!current.live && idle)) {
    select(id);
    return;
  }
  toast('New conversation on your R1', {
    action: {
      label: 'View',
      run: () => {
        chats.show?.();
        select(id, { user: true });
      },
    },
    timeout: 8000,
  });
}

const stream = new SyncStream({
  onEvent: onStreamEvent,
  onState: (value) => {
    state.streamState = value;
    schedule('status');
  },
  onResume: () => {
    scheduleListRefresh(200);
    if (state.selectedId) refreshTimeline(state.selectedId);
  },
});

// ---------------------------------------------------------------------------- overlays

function openImage(item) {
  const src = api.blobUrl(item.blobId);
  const image = h('img', { class: 'lightbox-img', src, alt: item.caption || 'Image' });
  const label = item.source === 'camera' ? 'R1 camera' : item.source === 'mac_screenshot' ? 'Mac screenshot' : 'Image';
  const overlay = h('div', { class: 'overlay lightbox', role: 'dialog', 'aria-modal': 'true', 'aria-label': label },
    h('div', { class: 'lightbox-stage' }, image),
    h('div', { class: 'lightbox-bar' },
      h('span', { text: label }),
      item.width && item.height ? h('span', { class: 'dims', text: `${item.width}×${item.height}` }) : null,
      h('span', { class: 'dims', text: stamp(item.at) })),
    h('button', { class: 'overlay-close', type: 'button', title: 'Close (Esc)', onclick: closeOverlay }, icon('close', { size: 18 })));
  overlay.addEventListener('click', (event) => {
    if (event.target === image) {
      overlay.classList.toggle('actual');
      return;
    }
    if (!event.target.closest('.overlay-close')) closeOverlay();
  });
  showOverlay(overlay);
}

function openArtifact(item) {
  const iframe = h('iframe', {
    class: 'full-iframe', sandbox: 'allow-scripts', src: api.documentUrl(item.artifactId),
    referrerpolicy: 'no-referrer', title: item.title || 'Generated UI',
  });
  iframe.dataset.artifactId = item.artifactId;
  const known = state.frameHeights.get(item.artifactId);
  if (known) iframe.style.height = `${known}px`;
  const overlay = h('div', { class: 'overlay sheet', role: 'dialog', 'aria-modal': 'true' },
    h('div', { class: 'sheet-panel' },
      h('header', { class: 'sheet-head' },
        h('div', { class: 'ui-icon' }, icon('sparkles', { size: 16 })),
        h('div', { class: 'ui-titles' },
          h('div', { class: 'ui-eyebrow', text: 'Generated UI' }),
          h('h3', { class: 'ui-title', text: item.title || 'Untitled UI' }),
          item.summary ? h('div', { class: 'ui-summary', text: item.summary }) : null),
        h('div', { class: 'ui-actions' },
          h('button', { class: 'btn-ghost', type: 'button', onclick: (event) => copyHtml(item, event.currentTarget) }, icon('copy', { size: 14 }), h('span', { text: 'Copy HTML' })),
          h('button', { class: 'icon-btn', type: 'button', title: 'Close (Esc)', onclick: closeOverlay }, icon('close', { size: 16 })))),
      h('div', { class: 'sheet-body' }, iframe)));
  overlay.addEventListener('click', (event) => {
    if (event.target === overlay) closeOverlay();
  });
  showOverlay(overlay);
}

// ---------------------------------------------------------------------------- actions

function openT3(item) {
  const env = item && item.environmentId;
  const thread = item && item.threadId;
  openExternal(env && thread ? `${T3_URL}${encodeURIComponent(env)}/${encodeURIComponent(thread)}` : T3_URL);
}

async function copyHtml(item, button) {
  try {
    const html = await api.documentText(item.artifactId);
    const ok = await copyText(html);
    if (button) {
      const label = button.querySelector('span');
      if (label) {
        const before = label.textContent;
        label.textContent = ok ? 'Copied' : 'Failed';
        setTimeout(() => {
          label.textContent = before;
        }, 1400);
      }
    }
    toast(ok ? 'HTML copied to the clipboard' : 'Could not copy');
  } catch {
    toast('Could not fetch the UI document');
  }
}

// ---------------------------------------------------------------------------- diagnostics for the native log

const diag = { images: 0, imagesFailed: 0, frames: new Set(), timer: 0 };
function reportDiag() {
  clearTimeout(diag.timer);
  diag.timer = setTimeout(() => postNative({
    type: 'diag', images: diag.images, imagesFailed: diag.imagesFailed, frames: diag.frames.size,
  }), 800);
}
document.addEventListener('load', (event) => {
  if (event.target && event.target.tagName === 'IMG' && event.target.closest('.shot, .lightbox')) {
    diag.images += 1;
    reportDiag();
  }
}, true);
document.addEventListener('error', (event) => {
  if (event.target && event.target.tagName === 'IMG') {
    diag.imagesFailed += 1;
    reportDiag();
  }
}, true);

// ---------------------------------------------------------------------------- generated UI messages

let lastLinkOpen = 0;
const lastAsked = { href: '', at: 0 };

/** A generated UI wants a link opened without a click we can vouch for: the user decides. */
function askToOpen(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return;
  const now = Date.now();
  if (lastAsked.href === parsed.href && now - lastAsked.at < 6000) return; // a widget retrying in a loop
  lastAsked.href = parsed.href;
  lastAsked.at = now;
  toast(`This UI wants to open ${parsed.host}`, { action: { label: 'Open', run: () => openExternal(parsed.href) }, timeout: 6000 });
}

window.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || typeof data !== 'object' || typeof data.type !== 'string') return;
  let frameEl = null;
  for (const candidate of document.querySelectorAll('iframe[data-artifact-id]')) {
    if (candidate.contentWindow === event.source) {
      frameEl = candidate;
      break;
    }
  }
  if (!frameEl) return;
  if (data.type === 'widget-resize' || data.type === '__ogui_resize') {
    const height = Math.max(60, Math.min(4000, Math.ceil(Number(data.height) || 0)));
    const id = frameEl.dataset.artifactId;
    if (Math.abs((state.frameHeights.get(id) || 0) - height) < 2 && frameEl.style.height === `${height}px`) return;
    const wasNear = frameEl.classList.contains('ui-iframe') && nearBottom();
    state.frameHeights.set(id, height);
    frameEl.style.height = `${height}px`;
    if (!diag.frames.has(id)) {
      diag.frames.add(id);
      reportDiag();
    }
    if (wasNear) stickToBottom();
  } else if (data.type === 'open-link' && typeof data.url === 'string') {
    // Only a click inside the generated UI (it then has focus) opens a link directly, at most once a
    // second, and only while this window still has the focus: once a link opened, the browser has it,
    // so a widget cannot keep opening tabs on a timer. Anything else has to be confirmed.
    const now = Date.now();
    if (document.hasFocus() && document.activeElement === frameEl && now - lastLinkOpen > 1000) {
      lastLinkOpen = now;
      openExternal(data.url);
    } else {
      askToOpen(data.url);
    }
  } else if (data.type === 'send-prompt' && typeof data.text === 'string') {
    toast(`Ask your R1: “${clip(data.text, 90)}”`, { timeout: 5000 });
  }
});

// ---------------------------------------------------------------------------- input

let searchTimer = 0;
els.search.addEventListener('input', () => {
  state.query = els.search.value.trim();
  state.lastInteraction = Date.now();
  clearTimeout(searchTimer);
  if (!state.query) {
    state.searchIds = null;
    schedule('list');
    return;
  }
  schedule('list');
  const query = state.query;
  searchTimer = setTimeout(async () => {
    try {
      const body = await api.conversations({ q: query, limit: 50 });
      if (state.query !== query) return;
      const list = body && Array.isArray(body.conversations) ? body.conversations : [];
      store.mergeList(list);
      state.searchIds = list.map((c) => c.conversationId || c.id).filter(Boolean);
      schedule('list');
    } catch {
      // local filtering still works
    }
  }, 220);
});

function moveSelection(step) {
  const ids = visibleConversations().map((c) => c.conversationId);
  if (!ids.length) return;
  const index = ids.indexOf(state.selectedId);
  const next = ids[Math.max(0, Math.min(ids.length - 1, index < 0 ? 0 : index + step))];
  select(next, { user: true });
  const button = els.list.querySelector(`[data-id="${CSS.escape(next)}"]`);
  if (button) button.scrollIntoView({ block: 'nearest' });
}

/** Keys while Chats is the view in front (app.js routes them here); true when handled. */
function handleKey(event) {
  const meta = event.metaKey || event.ctrlKey;
  if (event.key === 'Escape') {
    if (document.activeElement !== els.search) return false;
    if (els.search.value) {
      els.search.value = '';
      els.search.dispatchEvent(new Event('input'));
    } else {
      els.search.blur();
    }
    return true;
  }
  const typing = document.activeElement && ['INPUT', 'TEXTAREA'].includes(document.activeElement.tagName);
  if (!typing && !overlayOpen() && (event.key === 'ArrowDown' || event.key === 'ArrowUp') && (event.altKey || meta)) {
    event.preventDefault();
    moveSelection(event.key === 'ArrowDown' ? 1 : -1);
    return true;
  }
  if (typing && document.activeElement === els.search && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
    event.preventDefault();
    moveSelection(event.key === 'ArrowDown' ? 1 : -1);
    return true;
  }
  return false;
}

function focusSearch() {
  els.search.focus();
  els.search.select();
}

els.scroller.addEventListener('scroll', () => {
  if (nearBottom()) els.jump.hidden = true;
}, { passive: true });

// The first time the view comes to the front, generated UIs and images laid out while it was hidden grow into place
// (the frame's height transition only runs once it is displayed): it keeps to the end until they settle, unless the
// user scrolls.
let settleUntil = 0;
if (typeof ResizeObserver === 'function') {
  new ResizeObserver(() => {
    if (Date.now() < settleUntil) stickToBottom();
  }).observe(els.timeline);
}
els.scroller.addEventListener('wheel', () => {
  settleUntil = 0;
}, { passive: true });
els.jump.prepend(icon('arrowDown', { size: 13 }));
els.jump.addEventListener('click', () => stickToBottom(true));
window.addEventListener('hashchange', () => {
  const id = hashId();
  if (id && id !== state.selectedId) select(id, { user: true });
});
window.addEventListener('resize', () => reportDragExclusions());

// ---------------------------------------------------------------------------- ticks

setInterval(() => tickTimers(els.timeline), 1000);
setInterval(() => schedule('list', 'status'), 30_000);
setInterval(() => {
  const c = selectedSummary();
  const timeline = c && store.timelines.get(c.conversationId);
  if (timeline && timeline.loaded) schedule('timeline', 'foot');
}, 15_000);
setInterval(() => {
  if (state.listStatus === 'ok') loadList({ quiet: true });
}, 60_000);

// ---------------------------------------------------------------------------- the shell's API and boot

/** What the shell (app.js) and the other views use: open a conversation, refresh, search, the list for Home. */
export const chats = {
  store,
  handleKey,
  focusSearch,
  openConversation(id) {
    if (store.get(id)) select(id, { user: true });
    else {
      setHash(id);
      scheduleListRefresh(0);
      state.initialSelectionDone = false;
    }
  },
  refresh() {
    loadList({ manual: true });
    if (state.selectedId) refreshTimeline(state.selectedId);
  },
  summary() {
    return { conversations: store.byId.size, selected: Boolean(state.selectedId), stream: state.streamState, list: state.listStatus };
  },
  /** The native shell blocked a generated UI's own navigation to `url`; offer it instead. */
  confirmOpen(url) {
    if (typeof url === 'string') askToOpen(url);
  },
  /** Called with no arguments whenever the list or the sync status changed (Home's cards, the nav's live dot). */
  onChange: null,
  /** Set by the shell: bring the Chats view to the front (a toast's "View"). */
  show: null,
  /** The view came to the front: draw what changed while it was hidden, at the bottom if it was there. */
  shown() {
    if (state.stickOnShow !== false) {
      pendingScrollToBottom = true;
      settleUntil = Date.now() + 1200;
    }
    schedule('list', 'status', 'head', 'main', 'foot');
    reportDragExclusions();
  },
  /** The view went behind another: remember whether the timeline was at its end. */
  hidden() {
    state.stickOnShow = pendingScrollToBottom || nearBottom();
  },
  get streamState() {
    return state.streamState;
  },
  get listStatus() {
    return state.listStatus;
  },
};

schedule('list', 'status', 'main');
stream.start();
loadList();
