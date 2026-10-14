// The calendar as the window shows it (GET /v1/desktop/calendar/agenda, POST …/block): events by day, what is on now
// and next, and the "block time" choices. Pure (tests/agenda.test.mjs).

import { startOfDay, timeLabel, toMs } from './format.js';

const DAY = 86_400_000;
const MINUTE = 60_000;

export const BLOCK_CHOICES = [15, 30, 45, 60, 90, 120];
export const BLOCK_DEFAULT = 30;
export const BLOCK_TITLE = 'Focus';

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

/** One agenda event: {id, title, start, end (ms), allDay, location, meetingUrl}; null without a start. */
export function normalizeEvent(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const start = toMs(raw.startsAt);
  if (start == null) return null;
  const allDay = raw.allDay === true;
  let end = toMs(raw.endsAt);
  if (end == null || end <= start) end = start + (allDay ? DAY : 30 * MINUTE);
  const meeting = text(raw.meetingUrl);
  return {
    id: text(raw.eventId) || `${start}:${text(raw.title)}`,
    title: text(raw.title) || '(No title)',
    start,
    end,
    allDay,
    location: text(raw.location) || null,
    meetingUrl: /^https:\/\//i.test(meeting) ? meeting : null,
  };
}

export function normalizeEvents(list) {
  return (Array.isArray(list) ? list : []).map(normalizeEvent).filter(Boolean)
    .sort((a, b) => (a.start - b.start) || a.title.localeCompare(b.title));
}

/** "Today", "Tomorrow", else the weekday. */
export function dayName(dayStart, now = Date.now()) {
  const diff = Math.round((dayStart - startOfDay(now)) / DAY);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Tomorrow';
  if (diff === -1) return 'Yesterday';
  return new Date(dayStart).toLocaleDateString(undefined, { weekday: 'long' });
}

/** The next `days` days from today, each with its events (all-day ones apart): every day, empty or not. */
export function groupByDay(events, now = Date.now(), days = 7) {
  const today = startOfDay(now);
  const out = [];
  let dayStart = today;
  for (let index = 0; index < days; index += 1) {
    // Days are walked by calendar date, not by 24 h, so a daylight-saving change never skips or repeats one.
    const next = new Date(dayStart);
    next.setDate(next.getDate() + 1);
    const dayEnd = next.getTime();
    const overlapping = events.filter((e) => e.start < dayEnd && e.end > dayStart);
    out.push({
      dayStart,
      name: dayName(dayStart, now),
      date: new Date(dayStart).toLocaleDateString(undefined, { month: 'long', day: 'numeric' }),
      weekday: new Date(dayStart).toLocaleDateString(undefined, { weekday: 'short' }),
      dayOfMonth: new Date(dayStart).getDate(),
      allDay: overlapping.filter((e) => e.allDay),
      // A timed event that started on an earlier day shows on its first day only.
      timed: overlapping.filter((e) => !e.allDay && (e.start >= dayStart || index === 0)),
    });
    dayStart = dayEnd;
  }
  return out;
}

/** 'past' | 'now' | 'soon' (within 15 min) | 'later'. */
export function timing(event, now = Date.now()) {
  if (event.end <= now) return 'past';
  if (event.start <= now) return 'now';
  if (event.start - now <= 15 * MINUTE) return 'soon';
  return 'later';
}

/** "in 25 min", "in 2 hr", "Now · until 3:30 PM", "Ended". */
export function relativeStart(event, now = Date.now()) {
  const when = timing(event, now);
  if (when === 'past') return 'Ended';
  if (when === 'now') return event.allDay ? 'Today' : `Now · until ${timeLabel(event.end)}`;
  const minutes = Math.max(1, Math.round((event.start - now) / MINUTE));
  if (minutes < 60) return `in ${minutes} min`;
  const hours = minutes / 60;
  if (hours < 24 && startOfDay(event.start) === startOfDay(now)) {
    return `in ${hours < 10 ? Math.round(hours * 2) / 2 : Math.round(hours)} hr`;
  }
  return dayName(startOfDay(event.start), now);
}

/** "9:30 – 10:00 AM" (one AM/PM when both share it), "All day". */
export function timeRange(event) {
  if (event.allDay) return 'All day';
  const start = timeLabel(event.start);
  const end = timeLabel(event.end);
  const suffix = (label) => (label.match(/\s?[AP]M$/i) || [''])[0];
  if (suffix(start) && suffix(start) === suffix(end)) return `${start.slice(0, -suffix(start).length)} – ${end}`;
  return `${start} – ${end}`;
}

/** The next `count` events that haven't ended: timed ones first (soonest first), then all-day ones (like the bridge). */
export function upcoming(events, now = Date.now(), count = 3) {
  const live = events.filter((e) => e.end > now);
  return live.filter((e) => !e.allDay).concat(live.filter((e) => e.allDay)).slice(0, count);
}

/** Where the "now" line goes in a day's timed events: the index of the first that starts after now (-1: not today). */
export function nowIndex(day, now = Date.now()) {
  if (day.dayStart !== startOfDay(now)) return -1;
  const index = day.timed.findIndex((e) => e.start > now);
  return index < 0 ? day.timed.length : index;
}

/** "Block N minutes": from now, rounded down to the minute (the bridge's block_window). */
export function blockWindow(now, minutes) {
  const start = Math.floor(now / MINUTE) * MINUTE;
  return { start, end: start + minutes * MINUTE };
}

/** "15 min", "1 hr", "1.5 hr", "2 hr". */
export function durationLabel(minutes) {
  if (minutes < 60) return `${minutes} min`;
  const hours = minutes / 60;
  return `${Number.isInteger(hours) ? hours : hours.toFixed(1)} hr`;
}

/** The toast after a block: "Blocked 30 min · Focus until 3:42 PM". */
export function blockedLine(minutes, title, end) {
  return `Blocked ${durationLabel(minutes)} · ${title || BLOCK_TITLE} until ${timeLabel(end)}`;
}
