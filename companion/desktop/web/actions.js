// The quick actions Home and Calendar share: Block time (a popover: how long, a title, then
// POST /v1/desktop/calendar/block) and Journal note (a sheet: the words go into today's Heptabase journal exactly as
// typed, only when Samin presses Add).

import { BLOCK_CHOICES, BLOCK_DEFAULT, BLOCK_TITLE, blockWindow, blockedLine, durationLabel } from './agenda.js';
import { h } from './dom.js';
import { timeLabel } from './format.js';
import { icon } from './icons.js';
import { autosize, closePopover, popover, sheet, spinner, toast } from './ui.js';

let blockMinutes = BLOCK_DEFAULT;

/** "Block time" under `anchor`; `onDone()` after the calendar has the block (to read the agenda again). */
export function openBlockTime(anchor, api, { onDone } = {}) {
  const title = h('input', { class: 'field', type: 'text', value: BLOCK_TITLE, maxlength: '120', 'aria-label': 'Title' });
  title.value = BLOCK_TITLE;
  const preview = h('div', { class: 'block-preview' });
  const go = h('button', { class: 'btn wide', type: 'button' });
  const error = h('div', { class: 'popover-error', hidden: true });
  const chips = h('div', { class: 'block-chips' });

  const draw = () => {
    chips.replaceChildren(...BLOCK_CHOICES.map((minutes) => h('button', {
      class: `chip-btn${minutes === blockMinutes ? ' picked' : ''}`,
      type: 'button',
      onclick: () => {
        blockMinutes = minutes;
        draw();
      },
    }, durationLabel(minutes))));
    const { start, end } = blockWindow(Date.now(), blockMinutes);
    preview.replaceChildren(icon('clock', { size: 13 }), h('span', { text: `${timeLabel(start)} – ${timeLabel(end)} · today` }));
    go.replaceChildren(icon('calendar', { size: 14 }), h('span', { text: `Block ${durationLabel(blockMinutes)}` }));
  };

  const submit = async () => {
    if (go.disabled) return;
    go.disabled = true;
    error.hidden = true;
    go.replaceChildren(spinner(), h('span', { text: 'Adding to your calendar…' }));
    const name = title.value.trim() || BLOCK_TITLE;
    try {
      const answer = await api.block(blockMinutes, name);
      const end = answer && answer.event && answer.event.endsAt ? Date.parse(answer.event.endsAt) : blockWindow(Date.now(), blockMinutes).end;
      closePopover();
      toast(blockedLine(blockMinutes, name, end), { tone: 'ok' });
      onDone?.();
    } catch (failure) {
      go.disabled = false;
      draw();
      error.hidden = false;
      error.textContent = failure && failure.status === 0 ? 'The Mac bridge isn’t answering.'
        : (failure && failure.detail) || 'Google Calendar didn’t take it. Try again in a moment.';
    }
  };
  go.addEventListener('click', submit);
  title.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') submit();
  });
  draw();
  const node = popover(anchor, [
    h('div', { class: 'popover-title' }, icon('calendar', { size: 15 }), h('span', { text: 'Block time' })),
    h('div', { class: 'popover-sub', text: 'From now, on your Google Calendar.' }),
    chips,
    h('label', { class: 'popover-field' }, h('span', { text: 'Title' }), title),
    preview,
    error,
    go,
  ], { width: 312 });
  title.focus();
  title.select();
  return node;
}

/** "Journal note": a sheet with a field; Add puts the words, as typed, into today's journal. */
export function openJournalNote(api) {
  const area = h('textarea', {
    class: 'field area', rows: '4', maxlength: '4000', spellcheck: 'true',
    placeholder: 'What should go into today’s journal?', 'aria-label': 'Journal note',
  });
  const error = h('div', { class: 'popover-error', hidden: true });
  const add = h('button', { class: 'btn', type: 'button', disabled: true }, icon('note', { size: 14 }), h('span', { text: 'Add to journal' }));
  const cancel = h('button', { class: 'btn-ghost big', type: 'button' }, 'Cancel');
  const { close } = sheet({
    title: 'Journal note',
    text: 'Goes into today’s Heptabase journal word for word, with the time. ⌘↩ adds it.',
    body: h('div', { class: 'dialog-body' }, area, error),
    buttons: [cancel, add],
    className: 'journal',
  });
  autosize(area, 260);
  area.addEventListener('input', () => {
    add.disabled = !area.value.trim();
  });
  const submit = async () => {
    const text = area.value.trim();
    if (!text || add.dataset.busy) return;
    add.dataset.busy = '1';
    add.disabled = true;
    add.replaceChildren(spinner(), h('span', { text: 'Adding…' }));
    error.hidden = true;
    try {
      const answer = await api.journal(text);
      close();
      toast(answer && answer.dryRun ? 'Journal note recorded (dry run: the journal was not changed)'
        : `Added to today’s journal${answer && answer.time ? ` at ${answer.time}` : ''}`, { tone: 'ok' });
    } catch (failure) {
      delete add.dataset.busy;
      add.disabled = false;
      add.replaceChildren(icon('note', { size: 14 }), h('span', { text: 'Add to journal' }));
      error.hidden = false;
      error.textContent = failure && failure.status === 0 ? 'The Mac bridge isn’t answering.'
        : (failure && failure.detail) || 'Heptabase didn’t take it. Is the Heptabase app open?';
    }
  };
  add.addEventListener('click', submit);
  cancel.addEventListener('click', close);
  area.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      submit();
    }
  });
  setTimeout(() => area.focus(), 30);
}
