// The window's calendar rules (web/agenda.js): events as the bridge sends them, days, now and next, block time.
// Run: node --test companion/desktop/tests/*.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  BLOCK_CHOICES, blockWindow, blockedLine, dayName, durationLabel, groupByDay, normalizeEvent, normalizeEvents, nowIndex,
  relativeStart, timeRange, timing, upcoming,
} from '../web/agenda.js';

const MIN = 60_000;
// Local times (the tests run in whatever zone the Mac is in; the rules use local days, as the window does).
const at = (day, hour, minute = 0) => new Date(2026, 9, 14 + day, hour, minute).getTime();
const iso = (ms) => new Date(ms).toISOString();
const NOW = at(0, 13, 10);

const raw = [
  { eventId: 'b', title: 'Design review', startsAt: iso(at(0, 15)), endsAt: iso(at(0, 15, 45)), meetingUrl: 'https://meet.google.com/abc' },
  { eventId: 'a', title: 'Standup', startsAt: iso(at(0, 9, 30)), endsAt: iso(at(0, 9, 45)) },
  { eventId: 'c', title: 'Focus', startsAt: iso(at(0, 12, 45)), endsAt: iso(at(0, 14)) },
  { eventId: 'd', title: 'Birthday', startsAt: iso(at(2, 0)), endsAt: iso(at(3, 0)), allDay: true },
  { eventId: 'e', title: 'Flight', startsAt: iso(at(3, 8, 5)), endsAt: iso(at(3, 14, 30)), location: 'JFK' },
  { title: 'no start' },
  { eventId: 'f', title: 'Phishy', startsAt: iso(at(1, 10)), endsAt: iso(at(1, 11)), meetingUrl: 'javascript:alert(1)' },
];

test('events: sorted, without a start dropped, a bad end mended, only https meeting links', () => {
  const events = normalizeEvents(raw);
  assert.deepEqual(events.map((e) => e.id), ['a', 'c', 'b', 'f', 'd', 'e']);
  assert.equal(events.find((e) => e.id === 'f').meetingUrl, null);
  const mended = normalizeEvent({ title: 'x', startsAt: iso(at(0, 9)), endsAt: iso(at(0, 8)) });
  assert.equal(mended.end - mended.start, 30 * MIN);
  assert.equal(normalizeEvent({ title: '', startsAt: iso(at(0, 9)) }).title, '(No title)');
});

test('timing and the words for it', () => {
  const [standup, focus, review] = normalizeEvents(raw);
  assert.equal(timing(standup, NOW), 'past');
  assert.equal(timing(focus, NOW), 'now');
  assert.equal(relativeStart(focus, NOW), `Now · until ${new Date(at(0, 14)).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`);
  assert.equal(relativeStart(review, NOW), 'in 2 hr');
  assert.equal(relativeStart(review, at(0, 14, 50)), 'in 10 min');
  assert.equal(timing(review, at(0, 14, 50)), 'soon');
  assert.equal(relativeStart(normalizeEvents(raw).find((e) => e.id === 'e'), NOW), dayName(at(3, 0), NOW));
});

test('next three: timed first (soonest first), then all-day, nothing that ended', () => {
  const next = upcoming(normalizeEvents(raw), NOW, 3);
  assert.deepEqual(next.map((e) => e.id), ['c', 'b', 'f']);
  assert.deepEqual(upcoming(normalizeEvents(raw), at(3, 15), 3).map((e) => e.id), []);
});

test('seven days by calendar date, every day present, all-day apart, the now line in place', () => {
  const days = groupByDay(normalizeEvents(raw), NOW, 7);
  assert.equal(days.length, 7);
  assert.deepEqual(days.map((d) => d.name).slice(0, 2), ['Today', 'Tomorrow']);
  assert.deepEqual(days[0].timed.map((e) => e.id), ['a', 'c', 'b']);
  assert.deepEqual(days[2].allDay.map((e) => e.id), ['d']);
  assert.equal(days[2].timed.length, 0);
  assert.deepEqual(days[3].timed.map((e) => e.id), ['e']);
  assert.equal(nowIndex(days[0], NOW), 2, 'after Focus (on now), before the review');
  assert.equal(nowIndex(days[1], NOW), -1, 'only today has a now line');
  for (let i = 1; i < days.length; i += 1) assert.ok(days[i].dayStart > days[i - 1].dayStart);
});

test('time ranges share one AM/PM; all day says so', () => {
  const [standup] = normalizeEvents(raw);
  const range = timeRange(standup);
  assert.match(range, /^9:30 – 9:45\s?AM$/);
  assert.equal(timeRange({ allDay: true }), 'All day');
});

test('block time: from now to the minute, the choices, the words', () => {
  const { start, end } = blockWindow(at(0, 13, 10) + 42_000, 30);
  assert.equal(start, at(0, 13, 10));
  assert.equal(end, at(0, 13, 40));
  assert.deepEqual(BLOCK_CHOICES, [15, 30, 45, 60, 90, 120]);
  assert.deepEqual([15, 60, 90, 120].map(durationLabel), ['15 min', '1 hr', '1.5 hr', '2 hr']);
  assert.match(blockedLine(30, 'Focus', end), /^Blocked 30 min · Focus until 1:40\s?PM$/);
});
