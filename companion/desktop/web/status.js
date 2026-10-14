// What Home and Settings say about SamRabbit's devices and connections (GET /v1/desktop/summary, /devices,
// /v1/assistant/chatgpt/status): the R1, the paired iPhones and watches, the ChatGPT login, the greeting and the
// headline. Pure (tests/status.test.mjs).

import { dayName } from './agenda.js';
import { plural, relativeTime, startOfDay, timeLabel, toMs } from './format.js';

const MINUTE = 60_000;

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

export function greeting(now = Date.now()) {
  const hour = new Date(now).getHours();
  if (hour < 5) return 'Good evening';
  if (hour < 12) return 'Good morning';
  if (hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/** "2 need you · 4 working · Next: Design review at 3:00 PM". */
export function headline(counts, next, now = Date.now()) {
  const parts = [];
  parts.push(counts.needsYou ? `${counts.needsYou} need${counts.needsYou === 1 ? 's' : ''} you` : 'Nothing needs you');
  if (counts.working) parts.push(`${counts.working} working`);
  if (next) parts.push(nextLine(next, now));
  return parts.join(' · ');
}

/**
 * The next event as the headline says it, with its day when it isn't today (the agenda is a week long): "Next: Standup
 * at 9:30 AM", "Next: Standup tomorrow at 9:30 AM", "Next: Offsite Monday at 9:00 AM", "Next: Focus now"; all day:
 * "Today: Holiday" while it covers today, else "Tomorrow: Offsite", "Monday: Offsite".
 */
export function nextLine(event, now = Date.now()) {
  const today = startOfDay(now);
  const day = startOfDay(event.start);
  if (event.allDay) {
    const covers = event.start <= now && (event.end == null || event.end > today);
    return `${covers || day === today ? 'Today' : dayName(day, now)}: ${event.title}`;
  }
  if (event.start <= now) return `Next: ${event.title} now`;
  if (day === today) return `Next: ${event.title} at ${timeLabel(event.start)}`;
  const name = dayName(day, now);
  return `Next: ${event.title} ${name === 'Tomorrow' ? 'tomorrow' : name} at ${timeLabel(event.start)}`;
}

/** "Seen 3 min ago" with a floor: anything within two minutes reads as now. */
function seen(ms, now) {
  if (ms == null) return null;
  return now - ms < 2 * MINUTE ? 'Active now' : `Seen ${relativeTime(ms, now)}`;
}

/** The R1 row: live, recently seen or not seen; the battery when the bridge knows it. */
export function r1Status(summary, now = Date.now()) {
  const r1 = summary && summary.r1 && typeof summary.r1 === 'object' ? summary.r1 : {};
  const lastSeen = toMs(r1.lastSeenAt);
  const battery = Number.isFinite(r1.battery) ? Math.max(0, Math.min(100, Math.round(r1.battery))) : null;
  if (r1.live) {
    return { tone: 'live', line: r1.liveTitle ? `Live · ${r1.liveTitle}` : 'Live conversation', battery, lastSeen };
  }
  if (r1.online === true || (lastSeen != null && now - lastSeen < 5 * MINUTE)) {
    return { tone: 'ok', line: lastSeen != null ? seen(lastSeen, now) : 'Online', battery, lastSeen };
  }
  if (lastSeen != null) return { tone: 'idle', line: `Last seen ${relativeTime(lastSeen, now)}`, battery, lastSeen };
  return { tone: 'idle', line: 'Not seen yet', battery, lastSeen };
}

export function platformLabel(platform) {
  return { ios: 'iPhone', watchos: 'Apple Watch', macos: 'Mac' }[platform] || 'Device';
}

/** Paired devices as Settings lists them: each phone followed by its watches; strays (no phone) at the end. */
export function groupDevices(devices) {
  const list = (Array.isArray(devices) ? devices : []).filter((d) => d && text(d.deviceId)).map((d) => ({
    deviceId: text(d.deviceId),
    name: text(d.name) || platformLabel(d.platform),
    platform: text(d.platform),
    createdAt: toMs(d.createdAt),
    lastSeenAt: toMs(d.lastSeenAt),
    parentId: text(d.parentId) || null,
  }));
  const ids = new Set(list.map((d) => d.deviceId));
  const top = list.filter((d) => !d.parentId || !ids.has(d.parentId))
    .sort((a, b) => (a.platform === 'ios' ? 0 : 1) - (b.platform === 'ios' ? 0 : 1) || (b.lastSeenAt || 0) - (a.lastSeenAt || 0));
  const out = [];
  for (const device of top) {
    out.push({ ...device, child: false });
    for (const child of list.filter((d) => d.parentId === device.deviceId)) {
      out.push({ ...child, child: true, parentName: device.name });
    }
  }
  return out;
}

/** "Paired Oct 8 · Active now" / "Through iPhone 15 · Seen 9 min ago". */
export function deviceLine(device, now = Date.now()) {
  const parts = [];
  if (device.child && device.parentName) parts.push(`Through ${device.parentName}`);
  else if (device.createdAt) {
    parts.push(`Paired ${new Date(device.createdAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}`);
  }
  const last = seen(device.lastSeenAt, now);
  if (last) parts.push(last);
  return parts.join(' · ');
}

/**
 * Home's Devices card: the R1, then each paired phone and watch, then this Mac. `{kind, name, line, tone, battery}`.
 */
export function deviceRows(summary, devices, now = Date.now()) {
  const rows = [];
  const r1 = r1Status(summary, now);
  rows.push({ kind: 'r1', name: 'Rabbit R1', line: r1.line, tone: r1.tone, battery: r1.battery });
  for (const device of groupDevices(devices)) {
    const recent = device.lastSeenAt != null && now - device.lastSeenAt < 10 * MINUTE;
    rows.push({
      kind: device.platform === 'watchos' ? 'watch' : 'iphone',
      name: device.name,
      line: device.lastSeenAt != null ? seen(device.lastSeenAt, now) : 'Paired',
      tone: recent ? 'ok' : 'idle',
      battery: null,
      deviceId: device.deviceId,
    });
  }
  const mac = summary && summary.mac && typeof summary.mac === 'object' ? summary.mac : null;
  if (mac) {
    rows.push({
      kind: 'mac',
      name: text(mac.name) || 'This Mac',
      line: mac.screenLocked ? 'Bridge running · screen locked' : 'Bridge running',
      tone: 'ok',
      battery: null,
    });
  }
  return rows;
}

/** The devices the summary carries (WAVE7 §A adds them), else none. */
export function summaryDevices(summary) {
  return summary && Array.isArray(summary.devices) ? summary.devices : null;
}

/**
 * Settings' ChatGPT row: `{connected, title, detail, note, tone}`. "Using your Codex login" when the bridge borrows
 * the login Codex keeps on this Mac.
 */
export function chatgptStatus(status) {
  if (!status || typeof status !== 'object') {
    return { connected: false, title: 'Checking…', detail: '', note: '', tone: 'idle' };
  }
  const plan = text(status.plan);
  const planLabel = plan ? `ChatGPT ${plan[0].toUpperCase()}${plan.slice(1)}` : '';
  const detail = [planLabel, text(status.email)].filter(Boolean).join(' · ');
  if (status.connected) {
    return {
      connected: true,
      title: 'Connected',
      detail,
      note: status.source === 'codex' ? 'Using your Codex login on this Mac' : '',
      tone: 'ok',
    };
  }
  const login = status.login && typeof status.login === 'object' ? status.login : {};
  if (login.state === 'waiting') {
    return { connected: false, title: 'Waiting for you to sign in', detail: 'Finish in the Connect ChatGPT window.', note: '', tone: 'warn' };
  }
  if (status.reason === 'reconnect_required') {
    return { connected: false, title: 'Sign in again', detail: 'ChatGPT asked SamRabbit to sign in once more.', note: '', tone: 'warn' };
  }
  return { connected: false, title: 'Not connected', detail: 'The Mac’s voice answers with Claude until you connect.', note: '', tone: 'idle' };
}

/** "SamRabbit voice: realtime" style line for the assistant part of the summary. */
export function assistantLine(summary) {
  const part = summary && summary.assistant && typeof summary.assistant === 'object' ? summary.assistant : null;
  if (!part) return null;
  if (!part.available) return 'Voice assistant unavailable';
  return part.brain === 'realtime' ? 'Realtime voice (ChatGPT)' : 'Claude voice';
}

/**
 * Settings' "Show the Agent Dock" from what the shell says (`dock`: {enabled, turnedOn}; `shortcuts`): `{on, line}`.
 * `enabled` is whether it is really on (not hidden for a while); on but hidden says so, and how to bring it back.
 */
export function dockSwitch(dock, shortcuts, shell = true) {
  if (!shell || !dock || typeof dock !== 'object') return { on: true, line: 'Works in the SamRabbit app.' };
  const on = dock.enabled !== false;
  const keys = (id) => ((Array.isArray(shortcuts) ? shortcuts : []).find((s) => s && s.id === id && s.keys && !s.problem) || {}).keys;
  const back = keys('showHide') || keys('compose');
  if (on) return { on, line: 'On: it steps aside while you are in this window.' };
  if (dock.turnedOn) return { on, line: `Hidden for now. Turn it on${back ? ` or press ${back}` : ''} to bring it back.` };
  return { on, line: `Off until you turn it on here${back ? ` or press ${back}` : ''}.` };
}

/** "3 events today" etc. for the calendar card's caption. */
export function eventsCaption(count) {
  return count ? plural(count, 'event') : 'Nothing scheduled';
}
