// SamRabbit on the Mac: the whole app in one window (CONTRACTS-WAVE7 §B). A sidebar with the orb, Talk and the views
// (Home, Tasks, Chats, Calendar, Settings), live data from the bridge (the agent inbox long poll, the conversation
// sync stream, the summary, the agenda) and the native voice through the shell. ⌘1–⌘5 switch views.
//
// The page lives as long as the app (it loads at launch, with --login too, and stays when the window closes): the
// summary, the agenda and the inbox long poll run only while the window is on screen (`presence`), and each is read
// once when it is back.

import { AgentInbox } from './agents.js';
import { desktop } from './api.js';
import { createCalendar } from './calendar.js';
import { chats } from './chats.js';
import { h } from './dom.js';
import { createHome } from './home.js';
import { icon } from './icons.js';
import { keyName } from './inbox.js';
import { windowShortcut } from './keys.js';
import { nativeState, onNative, params, postNative, receiveNative } from './native.js';
import { createOrb } from './orb.js';
import { Presence, Resource } from './resource.js';
import { createSettings } from './settings.js';
import { createTalk } from './talk.js';
import { createTasks } from './tasks.js';
import { closeOverlay, closePopover, overlayOpen, reportDragExclusions, toast } from './ui.js';
import { normalizeEvents } from './agenda.js';

const VIEWS = [
  { id: 'home', label: 'Home', icon: 'home', key: '1' },
  { id: 'tasks', label: 'Tasks', icon: 'task', key: '2' },
  { id: 'chats', label: 'Chats', icon: 'bubble', key: '3' },
  { id: 'calendar', label: 'Calendar', icon: 'calendar', key: '4' },
  { id: 'settings', label: 'Settings', icon: 'gear', key: '5' },
];
const VIEW_IDS = VIEWS.map((v) => v.id);

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------- shared data

/** The window is on screen: the page is visible and the shell (MainWindowBridge) doesn't say the window is away. */
const presence = new Presence({ shell: () => (nativeState().window ? nativeState().window.visible !== false : true) });
const agents = new AgentInbox(desktop);
const summary = new Resource(() => desktop.summary(), { every: 60_000, presence });
const agenda = new Resource(async () => {
  const body = await desktop.agenda(7);
  return { ...body, events: normalizeEvents(body && body.events) };
}, { every: 5 * 60_000, presence });

const ctx = {
  api: desktop,
  agents,
  chats,
  summary,
  agenda,
  presence,
  show,
  current: () => current,
  toast,
};

// ---------------------------------------------------------------------------- views

let current = null;
const views = {};
const talk = createTalk(ctx);
ctx.talk = talk;
views.home = createHome(ctx, $('view-home'));
views.tasks = createTasks(ctx, $('view-tasks'));
views.chats = {
  el: $('view-chats'),
  shown: () => chats.shown(),
  hidden: () => chats.hidden(),
  handleKey: (event) => chats.handleKey(event),
};
views.calendar = createCalendar(ctx, $('view-calendar'));
views.settings = createSettings(ctx, $('view-settings'));
chats.show = () => show('chats');

/** Brings a view to the front. `options` go to the view (e.g. {item} for Tasks, {compose: true}). */
function show(id, options = {}) {
  if (!VIEW_IDS.includes(id)) return;
  closePopover();
  if (current !== id) {
    if (current) {
      views[current].el.hidden = true;
      views[current].hidden?.();
    }
    current = id;
    views[id].el.hidden = false;
    try {
      localStorage.setItem('samrabbit.view', id);
    } catch {
      // private mode
    }
    renderNav();
    views[id].shown?.(options);
  } else if (Object.keys(options).length) {
    views[id].shown?.(options);
  }
  requestAnimationFrame(() => reportDragExclusions());
}

function initialView() {
  const asked = params.get('view');
  if (VIEW_IDS.includes(asked)) return asked;
  if (/^#c=/.test(location.hash)) return 'chats';
  try {
    const remembered = localStorage.getItem('samrabbit.view');
    if (VIEW_IDS.includes(remembered)) return remembered;
  } catch {
    // private mode
  }
  return 'home';
}

// ---------------------------------------------------------------------------- the sidebar

const navOrb = createOrb({ size: 54, energy: 0.14, speed: 0.9, className: 'nav-orb' });
$('nav-brand').append(navOrb, h('div', { class: 'nav-brand-text' },
  h('div', { class: 'brand-name', text: 'SamRabbit' }),
  h('div', { class: 'brand-sub', id: 'brand-sub', text: 'On your Mac' })));
$('nav-talk').append(talk.button);

const navButtons = new Map();
for (const view of VIEWS) {
  const badge = h('span', { class: 'nav-badge', hidden: true });
  const button = h('button', {
    class: 'nav-item', type: 'button', role: 'tab', dataset: { view: view.id },
    title: `${view.label}  ⌘${view.key}`,
    onclick: () => show(view.id),
  }, h('span', { class: 'nav-icon' }, icon(view.icon, { size: 17 })), h('span', { class: 'nav-label', text: view.label }), badge,
  h('kbd', { class: 'nav-kbd', text: `⌘${view.key}` }));
  navButtons.set(view.id, { button, badge });
  $('nav-items').append(button);
}

function renderNav() {
  for (const [id, { button, badge }] of navButtons) {
    const selected = id === current;
    button.classList.toggle('selected', selected);
    button.setAttribute('aria-selected', selected ? 'true' : 'false');
    if (id === 'tasks') {
      const { needsYou } = agents.counts();
      badge.hidden = !needsYou;
      badge.textContent = String(needsYou);
      badge.className = 'nav-badge accent';
    } else if (id === 'chats') {
      const live = chats.store.list().some((c) => c.live);
      badge.hidden = !live;
      badge.textContent = '';
      badge.className = 'nav-badge live-dot';
      badge.title = live ? 'Live conversation' : '';
    }
  }
  const voice = nativeState().voice;
  const active = voice && ['starting', 'listening', 'thinking', 'speaking'].includes(voice.state);
  navOrb.orb.set(active
    ? { energy: 0.25 + Math.min(1, Number(voice.level) || 0) * 0.6, speed: voice.state === 'speaking' ? 2.2 : 1.5 }
    : { energy: agents.counts().working ? 0.2 : 0.12, speed: agents.counts().working ? 1.2 : 0.9 });
}

agents.on(() => renderNav());
chats.onChange = () => {
  renderNav();
  views.home.chatsChanged?.();
};
onNative((_state, changed) => {
  renderNav();
  if (changed.includes('window')) presence.update();
});

// The inbox long poll only while the window is on screen (the nav badge and Home are its only readers; the dock polls
// for itself). Back on screen it asks at once: the bridge answers right away when anything changed meanwhile.
presence.on((watched) => {
  if (watched) agents.start();
  else agents.stop();
});

// ---------------------------------------------------------------------------- keys

function runShortcut(shortcut) {
  switch (shortcut.type) {
    case 'view':
      show(VIEWS[shortcut.index].id);
      break;
    case 'search':
      show('chats');
      chats.focusSearch();
      break;
    case 'newTask':
      show('tasks', { compose: true });
      break;
    case 'settings':
      show('settings');
      break;
    default:
      break;
  }
}

document.addEventListener('keydown', (event) => {
  const typing = document.activeElement && (['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement.tagName)
    || document.activeElement.isContentEditable);
  const shortcut = windowShortcut(event, current);
  if (shortcut) {
    // Handled here (so the menus don't run it a second time); behind a sheet (a journal note, an unpair) nothing
    // moves: the sheet is modal.
    event.preventDefault();
    if (!overlayOpen()) runShortcut(shortcut);
    return;
  }
  if (event.key === 'Escape') {
    if (closePopover() || closeOverlay()) return;
    // The voice panel says "Esc ends it": a conversation comes before the view's own Esc (a field keeps its Esc).
    if (!typing && talk.visible()) {
      event.preventDefault();
      talk.escape();
      return;
    }
  }
  if (overlayOpen()) return;
  if (views[current] && views[current].handleKey && views[current].handleKey(event)) return;
  if (typing || event.metaKey || event.ctrlKey || event.altKey) return;
  // N anywhere (not typing): a new task, as in the dock.
  if (keyName(event) === 'compose') {
    event.preventDefault();
    show('tasks', { compose: true });
  }
});

window.addEventListener('resize', () => reportDragExclusions());

// ---------------------------------------------------------------------------- ticks

setInterval(() => agents.tick(), 30_000);
setInterval(() => renderNav(), 30_000);

// ---------------------------------------------------------------------------- the shell's API and boot

window.SamRabbitApp = {
  openConversation(id) {
    show('chats');
    chats.openConversation(id);
  },
  refresh() {
    chats.refresh();
    agents.poller?.poke();
    summary.refresh();
    agenda.refresh();
  },
  summary() {
    return {
      ...chats.summary(), view: current, inbox: agents.connection, needsYou: agents.counts().needsYou,
      watched: presence.watched, polling: Boolean(agents.poller && agents.poller.running),
    };
  },
  confirmOpen(url) {
    chats.confirmOpen(url);
  },
  /** ⌘1–⌘5 and Settings… from the app's menus: "home" | "tasks" | "chats" | "calendar" | "settings" (not behind a sheet). */
  show(view) {
    if (!overlayOpen()) show(view);
  },
  newTask() {
    if (!overlayOpen()) show('tasks', { compose: true });
  },
  focusSearch() {
    if (overlayOpen()) return;
    show('chats');
    chats.focusSearch();
  },
  /** The shell pushes MacVoice, the dock, the shortcuts and the window's state here (MainWindowBridge.swift). */
  native(patch) {
    receiveNative(patch);
  },
};

if (presence.watched) agents.start();
summary.refresh();
summary.start();
agenda.refresh();
agenda.start();
show(initialView());
renderNav();
postNative({ type: 'ready' });
