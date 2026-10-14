// Calendar: the next seven days of Google Calendar by day (GET /v1/desktop/calendar/agenda?days=7, read through the
// bridge), what is on now and next, Join for meetings, and Block time (POST /v1/desktop/calendar/block).

import { openBlockTime } from './actions.js';
import { groupByDay, nowIndex, relativeStart, timeRange, timing } from './agenda.js';
import { h } from './dom.js';
import { hostOf, plural } from './format.js';
import { icon } from './icons.js';
import { openExternal, redrawWhenFree, reportDragExclusions, spinner } from './ui.js';

const DAYS = 7;

export function createCalendar(ctx, el) {
  const { agenda } = ctx;
  let visible = false;
  let drawn = '';

  const head = h('header', { class: 'view-head titlebar' });
  const strip = h('div', { class: 'week-strip', role: 'tablist', 'aria-label': 'Days' });
  const body = h('div', { class: 'view-scroll calendar-scroll' });
  const content = h('div', { class: 'calendar' });
  body.append(content);
  el.append(head, strip, body);

  function blockTime(anchor) {
    openBlockTime(anchor, ctx.api, { onDone: () => agenda.refresh() });
  }

  function renderHead() {
    const value = agenda.value;
    const zone = value && value.timezone ? value.timezone.replace(/_/g, ' ') : '';
    head.replaceChildren(
      h('div', { class: 'head-stack' },
        h('h1', { class: 'view-title', text: 'Calendar' }),
        h('span', { class: 'view-meta', text: ['Google Calendar', zone].filter(Boolean).join(' · ') })),
      h('div', { class: 'head-tools' },
        h('button', {
          class: 'icon-btn', type: 'button', title: 'Read the calendar again', 'aria-label': 'Refresh',
          onclick: () => agenda.refresh(),
        }, agenda.loading ? spinner() : icon('refresh', { size: 15 })),
        h('button', {
          class: 'tool-btn accent', type: 'button', title: 'Block time from now on your calendar',
          onclick: (event) => blockTime(event.currentTarget),
        }, icon('clock', { size: 14 }), h('span', { text: 'Block time' }))));
  }

  function eventRow(event, now) {
    const when = timing(event, now);
    return h('div', { class: `cal-event when-${when}` },
      h('div', { class: 'cal-time' },
        h('div', { class: 'cal-start', text: timeRange(event) }),
        when === 'now' || when === 'soon' ? h('div', { class: 'cal-rel', text: relativeStart(event, now) }) : null),
      h('div', { class: 'cal-bar' }),
      h('div', { class: 'cal-main' },
        h('div', { class: 'cal-title', text: event.title }),
        event.meetingUrl || event.location ? h('div', { class: 'cal-where' },
          icon(event.meetingUrl ? 'video' : 'pin', { size: 12 }),
          h('span', { text: event.meetingUrl ? meetingName(event.meetingUrl) : event.location })) : null),
      event.meetingUrl ? h('button', {
        class: `chip-btn join${when === 'now' || when === 'soon' ? ' primary' : ''}`, type: 'button',
        title: event.meetingUrl, onclick: () => openExternal(event.meetingUrl),
      }, icon('video', { size: 13 }), h('span', { text: 'Join' })) : null);
  }

  function meetingName(url) {
    const host = hostOf(url);
    if (/meet\.google\.com$/.test(host)) return 'Google Meet';
    if (/zoom\.us$/.test(host)) return 'Zoom';
    if (/teams\.microsoft\.com$/.test(host)) return 'Microsoft Teams';
    return host;
  }

  function nowLine(now) {
    const time = new Date(now).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    return h('div', { class: 'now-line', 'aria-label': `Now, ${time}` }, h('span', { class: 'now-time', text: time }), h('span', { class: 'now-rule' }));
  }

  function daySection(day, now) {
    const count = day.timed.length + day.allDay.length;
    const today = day.name === 'Today';
    const rows = [];
    const marker = nowIndex(day, now);
    day.timed.forEach((event, index) => {
      if (index === marker) rows.push(nowLine(now));
      rows.push(eventRow(event, now));
    });
    if (marker === day.timed.length && today && day.timed.length) rows.push(nowLine(now));
    return h('section', { class: `cal-day${today ? ' today' : ''}`, id: `day-${day.dayStart}` },
      h('header', { class: 'cal-day-head' },
        h('div', { class: 'cal-day-num', text: String(day.dayOfMonth) }),
        h('div', { class: 'cal-day-names' },
          h('div', { class: 'cal-day-name', text: day.name }),
          h('div', { class: 'cal-day-date', text: today || day.name === 'Tomorrow' ? `${day.weekday}, ${day.date}` : day.date })),
        h('span', { class: 'cal-day-count', text: count ? plural(count, 'event') : '' })),
      day.allDay.length ? h('div', { class: 'cal-allday' }, day.allDay.map((event) => h('span', { class: 'allday-chip' },
        icon('sun', { size: 12 }), h('span', { text: event.title })))) : null,
      rows.length ? h('div', { class: 'cal-events' }, rows)
        : h('div', { class: 'cal-free' }, h('span', { text: today ? 'Nothing else today.' : 'Nothing scheduled.' }),
          today ? h('button', { class: 'link', type: 'button', onclick: (event) => blockTime(event.currentTarget) }, 'Block time') : null));
  }

  function renderStrip(days) {
    strip.replaceChildren(...days.map((day) => {
      const count = day.timed.length + day.allDay.length;
      return h('button', {
        class: `day-pill${day.name === 'Today' ? ' today' : ''}`, type: 'button', role: 'tab',
        title: `${day.name}: ${count ? plural(count, 'event') : 'nothing scheduled'}`,
        onclick: () => {
          const target = content.querySelector(`#day-${day.dayStart}`);
          if (target) body.scrollTo({ top: target.offsetTop - 8, behavior: 'smooth' });
        },
      }, h('span', { class: 'day-pill-week', text: day.weekday }), h('span', { class: 'day-pill-num', text: String(day.dayOfMonth) }),
      h('span', { class: 'day-pill-dots' }, Array.from({ length: Math.min(count, 4) }, () => h('i'))));
    }));
    strip.hidden = !days.length;
  }

  function render() {
    // Never between a press and its release (Join and Block time are in what is redrawn; ui.js).
    if (visible) redrawWhenFree('calendar', draw);
  }

  function draw() {
    if (!visible) return;
    const now = Date.now();
    renderHead();
    const key = JSON.stringify([agenda.loadedAt, Boolean(agenda.error), agenda.error && agenda.error.status, Math.floor(now / 60_000)]);
    if (key === drawn) return;
    drawn = key;
    const value = agenda.value;
    if (!value) {
      strip.hidden = true;
      if (agenda.error) {
        const status = agenda.error.status;
        const text = status === 0 ? 'The Mac bridge isn’t answering.'
          : status === 404 ? 'This bridge can’t read the calendar for the window yet. Update it with companion/mac-bridge/install.sh.'
            : 'Google Calendar can’t be read from the Mac right now (Composio may need you to sign in again). SamRabbit tries again in a few minutes.';
        content.replaceChildren(h('div', { class: 'calendar-state' }, icon('calendar', { size: 26 }),
          h('h2', { class: 'empty-title', text: 'Your calendar isn’t available' }), h('p', { class: 'empty-text', text }),
          h('button', { class: 'btn', type: 'button', onclick: () => agenda.refresh() }, icon('refresh', { size: 14 }), h('span', { text: 'Try again' }))));
      } else {
        content.replaceChildren(h('div', { class: 'calendar-state' }, spinner(), h('p', { class: 'empty-text', text: 'Reading your calendar…' })));
      }
      reportDragExclusions();
      return;
    }
    const days = groupByDay(value.events, now, DAYS);
    renderStrip(days);
    const scroll = body.scrollTop;
    content.replaceChildren(...[
      agenda.error ? h('div', { class: 'banner' }, icon('alert', { size: 15 }),
        h('div', null, h('div', { class: 'banner-title', text: 'Couldn’t read the latest' }),
          h('div', { class: 'banner-text', text: 'This is what the calendar said last time.' }))) : null,
      ...days.map((day) => daySection(day, now))].filter(Boolean));
    body.scrollTop = scroll;
    reportDragExclusions();
  }

  agenda.on(() => {
    if (agenda.loading) redrawWhenFree('calendar-head', renderHead);
    else render();
  });
  setInterval(() => render(), 30_000);

  return {
    el,
    shown() {
      visible = true;
      drawn = '';
      agenda.fresh(60_000);
      render();
    },
    hidden() {
      visible = false;
    },
    handleKey(event) {
      if (event.metaKey || event.ctrlKey || event.altKey) return false;
      if (document.activeElement && ['INPUT', 'TEXTAREA'].includes(document.activeElement.tagName)) return false;
      if (event.key === 'b' || event.key === 'B') {
        event.preventDefault();
        blockTime(head.querySelector('.tool-btn.accent'));
        return true;
      }
      return false;
    },
  };
}
