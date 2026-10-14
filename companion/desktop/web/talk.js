// Talk in the window: the sidebar's Talk button and the live transcript panel. The conversation is MacVoice's (the
// same one ⌃⌥Space, "Hey Rabbit" and the dock's mic start): the page asks the shell to start, mute, stop speaking or
// end it ({type: "voice", action}) and draws what the shell pushes back (voice.js turns it into a transcript). There
// is no second audio engine here.
//
// The shell pushes the mic level about 12 times a second and the reply at word rate, so nothing here is rebuilt on a
// push: a click is a press and a release on the same element, and a button replaced in between never gets it. The
// button and the panel are built once and patched in place; the panel's controls sit on its bottom edge, which stays
// put while the transcript above them grows.

import { h } from './dom.js';
import { icon } from './icons.js';
import { nativeState, onNative, postNative } from './native.js';
import { createOrb } from './orb.js';
import { keycap, toast } from './ui.js';
import { VoiceTranscript, idleCaption, isActive, normalizeVoice, voiceLabel } from './voice.js';

const LINGER_MS = 12_000;
/** Within this many px of the end the transcript follows new text; scrolled further up, it stays where Samin put it. */
const FOLLOW_PX = 48;

/** Sets what changed only (a text node or an attribute rewritten with the same value is still a DOM change). */
function setText(el, value) {
  if (el.textContent !== value) el.textContent = value;
}

function setAttr(el, name, value) {
  if (value == null) {
    if (el.hasAttribute(name)) el.removeAttribute(name);
  } else if (el.getAttribute(name) !== value) {
    el.setAttribute(name, value);
  }
}

/** The `hidden` attribute (styles.css hides it), which SVG icons take too (they have no `hidden` property). */
function show(el, visible) {
  if (el.hasAttribute('hidden') === visible) el.toggleAttribute('hidden', !visible);
}

export function createTalk(ctx) {
  const transcript = new VoiceTranscript();
  const root = document.getElementById('voice-root');
  let panel = null;
  let hideTimer = 0;
  let hovering = false;

  function send(action) {
    if (postNative({ type: 'voice', action })) return true;
    toast('Talking works in the SamRabbit app (the voice runs natively).');
    return false;
  }

  function start() {
    send('start');
  }

  function toggle() {
    const voice = nativeState().voice;
    send(voice && isActive(normalizeVoice(voice)) ? 'end' : 'start');
  }

  // ------------------------------------------------------------------ the sidebar button (built once)

  const mic = icon('mic', { size: 15 });
  const bars = h('span', { class: 'talk-bars' }, h('i'), h('i'), h('i'), h('i'));
  const label = h('span', { class: 'talk-label', text: 'Talk' });
  const end = h('span', { class: 'talk-end', text: 'End' });
  const key = keycap('⌃⌥Space');
  const button = h('button', { class: 'talk-btn', type: 'button', onclick: () => toggle() },
    h('span', { class: 'talk-icon' }, mic, bars), label, end, key);

  function renderButton() {
    const voice = normalizeVoice(nativeState().voice);
    const active = isActive(voice);
    const shortcut = voice.shortcut || '⌃⌥Space';
    button.classList.toggle('active', active);
    button.classList.toggle('error', voice.state === 'error');
    setAttr(button, 'title', active ? `End the conversation (${shortcut})` : `Talk to SamRabbit (${shortcut})`);
    show(mic, !active);
    show(bars, active);
    setText(label, active ? `${voiceLabel(voice).label}…` : 'Talk');
    show(end, active);
    show(key, !active && !voice.shortcutProblem);
    setText(key, shortcut);
    button.style.setProperty('--level', String(active ? voice.level : 0));
  }

  // ------------------------------------------------------------------ the transcript panel (built once per showing)

  function circle(name, title, onclick, { danger = false, alt = null } = {}) {
    const glyph = icon(name, { size: 16 });
    const other = alt ? icon(alt, { size: 16 }) : null;
    if (other) other.setAttribute('hidden', '');
    const node = h('button', { class: `voice-btn${danger ? ' danger' : ''}`, type: 'button', title, 'aria-label': title, onclick },
      glyph, other);
    node.glyphs = [glyph, other];
    return node;
  }

  function buildPanel() {
    const orb = createOrb({ size: 76, energy: 0.2, speed: 1.4, className: 'voice-orb' });
    const parts = {
      orb,
      label: h('div', { class: 'voice-label' }),
      sub: h('div', { class: 'voice-sub' }),
      scroller: h('div', { class: 'voice-transcript' }),
      idle: h('div', { class: 'vt-idle' }),
      typing: h('div', { class: 'vt vt-assistant vt-typing' }, h('img', { class: 'vt-avatar', src: 'orb.svg', alt: '' }),
        h('div', { class: 'typing' }, h('span'), h('span'), h('span'))),
      lines: new Map(),
      mute: circle('mic', 'Mute the microphone', () => send(normalizeVoice(nativeState().voice).micMuted ? 'unmute' : 'mute'), { alt: 'micOff' }),
      stop: circle('stop', 'Stop speaking', () => send('stopSpeaking')),
      end: circle('close', 'End the conversation', () => send('end'), { danger: true }),
      chats: h('button', {
        class: 'btn-ghost', type: 'button',
        onclick: () => {
          ctx.show('chats');
          ctx.chats.openConversation(transcript.conversationId);
          dismiss();
        },
      }, icon('bubble', { size: 13 }), h('span', { text: 'Open in Chats' })),
      again: h('button', { class: 'btn-ghost', type: 'button', onclick: () => start() }, icon('mic', { size: 13 }), h('span', { text: 'Talk again' })),
      close: circle('close', 'Close', () => dismiss()),
      /** At the newest line: new text and a smaller window keep it there; scrolled up, it stays where it was put. */
      following: true,
      resized: null,
    };
    const scroller = parts.scroller;
    scroller.addEventListener('scroll', () => {
      parts.following = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < FOLLOW_PX;
    });
    if (typeof ResizeObserver === 'function') {
      parts.resized = new ResizeObserver(() => {
        if (parts.following) scroller.scrollTop = scroller.scrollHeight;
      });
      parts.resized.observe(scroller);
    }
    parts.live = h('div', { class: 'voice-buttons live' }, parts.mute, parts.stop, parts.end);
    parts.after = h('div', { class: 'voice-buttons after' }, parts.chats, parts.again, parts.close);
    const node = h('section', { class: 'voice-panel', role: 'region', 'aria-label': 'Voice conversation' },
      parts.scroller,
      h('div', { class: 'voice-head' }, orb, h('div', { class: 'voice-titles' }, parts.label, parts.sub), parts.live, parts.after));
    node.parts = parts;
    node.addEventListener('mouseenter', () => {
      hovering = true;
    });
    node.addEventListener('mouseleave', () => {
      hovering = false;
      scheduleHide();
    });
    root.append(node);
    return node;
  }

  /** One transcript line: kept per turn id, its text patched as the reply streams. */
  function line(parts, turn, streaming) {
    let entry = parts.lines.get(turn.id);
    if (!entry || entry.role !== turn.role) {
      if (turn.role === 'user') {
        const text = h('div', { class: 'vt-bubble' });
        entry = { role: 'user', el: h('div', { class: 'vt vt-user' }, text), text };
      } else {
        const text = h('div', { class: 'vt-text' });
        entry = {
          role: 'assistant', el: h('div', { class: 'vt vt-assistant' }, h('img', { class: 'vt-avatar', src: 'orb.svg', alt: '' }), text),
          text, words: document.createTextNode(''), caret: h('span', { class: 'caret' }),
        };
        text.append(entry.words);
      }
      parts.lines.set(turn.id, entry);
    }
    if (entry.role === 'user') setText(entry.text, turn.text);
    else {
      if (entry.words.data !== turn.text) entry.words.data = turn.text;
      if (streaming !== entry.caret.isConnected) {
        if (streaming) entry.text.append(entry.caret);
        else entry.caret.remove();
      }
    }
    return entry.el;
  }

  /** Puts `wanted` in the scroller in order, moving or removing only what isn't already in its place. */
  function arrange(scroller, wanted) {
    let cursor = scroller.firstChild;
    for (const node of wanted) {
      if (node === cursor) cursor = cursor.nextSibling;
      else scroller.insertBefore(node, cursor);
    }
    while (cursor) {
      const next = cursor.nextSibling;
      cursor.remove();
      cursor = next;
    }
  }

  function renderPanel() {
    const voice = transcript.snapshot;
    if (!transcript.visible(Date.now(), LINGER_MS)) {
      if (panel) {
        const closing = panel;
        panel = null;
        closing.classList.add('closing');
        closing.parts.orb.orb?.destroy?.();
        closing.parts.resized?.disconnect();
        setTimeout(() => closing.remove(), 220);
      }
      return;
    }
    if (!panel) panel = buildPanel();
    const parts = panel.parts;
    const active = transcript.active;
    const { label: title, tone } = active ? voiceLabel(voice) : transcript.error ? { label: 'Voice problem', tone: 'error' }
      : { label: 'Conversation ended', tone: 'idle' };
    setAttr(panel, 'class', `voice-panel tone-${tone}${active ? ' active' : ' ended'}`);
    parts.orb.orb.set(active
      ? { energy: 0.2 + voice.level * 0.7, speed: voice.state === 'speaking' ? 2.4 : voice.state === 'thinking' ? 1.8 : 1.2, glow: 1 }
      : { energy: 0.05, speed: 0.4, glow: tone === 'error' ? 0.35 : 0.7 });
    const brain = voice.brain === 'realtime' ? 'Realtime voice' : voice.brain === 'claude' ? 'Claude voice' : '';
    const shortcut = voice.shortcut || '⌃⌥Space';
    setAttr(parts.label, 'class', `voice-label tone-${tone}`);
    setText(parts.label, title);
    setText(parts.sub, active ? [brain, `${shortcut} or Esc ends it`].filter(Boolean).join(' · ')
      : transcript.error || (transcript.turns.length ? 'Saved in Chats with your other conversations.' : 'Nothing was said.'));

    // The controls: while it runs mute / stop speaking / end, after it Open in Chats / Talk again / close.
    show(parts.live, active);
    show(parts.after, !active);
    const muteTitle = voice.micMuted ? 'Unmute the microphone' : 'Mute the microphone';
    setAttr(parts.mute, 'title', muteTitle);
    setAttr(parts.mute, 'aria-label', muteTitle);
    parts.mute.classList.toggle('on', voice.micMuted);
    show(parts.mute.glyphs[0], !voice.micMuted);
    show(parts.mute.glyphs[1], voice.micMuted);
    parts.stop.disabled = !(voice.state === 'speaking' || voice.state === 'thinking');
    const endTitle = `End the conversation (${shortcut})`;
    setAttr(parts.end, 'title', endTitle);
    setAttr(parts.end, 'aria-label', endTitle);
    show(parts.chats, Boolean(transcript.conversationId && transcript.turns.length));

    // The lines: one per turn, kept and patched; the typing dots while it thinks after something was said.
    const scroller = parts.scroller;
    const turns = transcript.turns;
    const wanted = turns.map((turn, index) => line(parts, turn, active && !turn.final && index === turns.length - 1));
    for (const id of [...parts.lines.keys()]) {
      if (!turns.some((turn) => turn.id === id)) parts.lines.delete(id);
    }
    if (!turns.length) {
      setText(parts.idle, active ? idleCaption(voice) : '');
      wanted.push(parts.idle);
    }
    if (active && turns.length && voice.state === 'thinking') wanted.push(parts.typing);
    arrange(scroller, wanted);
    if (parts.following) scroller.scrollTop = scroller.scrollHeight;
    scheduleHide();
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    if (transcript.active || !transcript.ended) return;
    const left = LINGER_MS - (Date.now() - (transcript.endedAt || 0));
    hideTimer = setTimeout(() => {
      if (hovering) {
        transcript.endedAt = Date.now() - LINGER_MS + 3000;
        scheduleHide();
        return;
      }
      renderPanel();
    }, Math.max(50, left));
  }

  function dismiss() {
    transcript.dismiss();
    renderPanel();
  }

  onNative((state, changed) => {
    if (!changed.includes('voice')) return;
    transcript.apply(state.voice);
    renderButton();
    renderPanel();
  });
  renderButton();

  return {
    button,
    start,
    toggle,
    transcript,
    visible: () => Boolean(panel),
    /** Esc with nothing else to close: end a conversation, or put the ended panel away. */
    escape() {
      if (transcript.active) send('end');
      else dismiss();
    },
  };
}
