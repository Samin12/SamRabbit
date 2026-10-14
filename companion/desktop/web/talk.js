// Talk in the window: the sidebar's Talk button and the live transcript panel. The conversation is MacVoice's (the
// same one ⌃⌥Space, "Hey Rabbit" and the dock's mic start): the page asks the shell to start, mute, stop speaking or
// end it ({type: "voice", action}) and draws what the shell pushes back (voice.js turns it into a transcript). There
// is no second audio engine here.

import { h } from './dom.js';
import { icon } from './icons.js';
import { nativeState, onNative, postNative } from './native.js';
import { createOrb } from './orb.js';
import { keycap, toast } from './ui.js';
import { VoiceTranscript, idleCaption, isActive, normalizeVoice, voiceLabel } from './voice.js';

const LINGER_MS = 12_000;

export function createTalk(ctx) {
  const transcript = new VoiceTranscript();
  const root = document.getElementById('voice-root');
  const button = h('button', { class: 'talk-btn', type: 'button', onclick: () => toggle() });
  let panel = null;
  let orb = null;
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

  function snapshot() {
    return normalizeVoice(nativeState().voice);
  }

  // ------------------------------------------------------------------ the sidebar button

  function renderButton() {
    const voice = snapshot();
    const active = isActive(voice);
    const shortcut = voice.shortcut || '⌃⌥Space';
    button.classList.toggle('active', active);
    button.classList.toggle('error', voice.state === 'error');
    button.title = active ? `End the conversation (${shortcut})` : `Talk to SamRabbit (${shortcut})`;
    const { label } = voiceLabel(voice);
    button.replaceChildren(
      h('span', { class: 'talk-icon' }, active ? h('span', { class: 'talk-bars' }, h('i'), h('i'), h('i'), h('i')) : icon('mic', { size: 15 })),
      h('span', { class: 'talk-label', text: active ? `${label}…` : 'Talk' }),
      active ? h('span', { class: 'talk-end', text: 'End' }) : keycap(voice.shortcutProblem ? '' : shortcut));
    button.style.setProperty('--level', String(active ? voice.level : 0));
  }

  // ------------------------------------------------------------------ the transcript panel

  function ensurePanel() {
    if (panel) return panel;
    orb = createOrb({ size: 76, energy: 0.2, speed: 1.4, className: 'voice-orb' });
    panel = h('section', { class: 'voice-panel', role: 'region', 'aria-label': 'Voice conversation' });
    panel.addEventListener('mouseenter', () => {
      hovering = true;
    });
    panel.addEventListener('mouseleave', () => {
      hovering = false;
      scheduleHide();
    });
    root.append(panel);
    return panel;
  }

  function circle(name, title, onclick, { active = false, disabled = false, danger = false } = {}) {
    return h('button', {
      class: `voice-btn${active ? ' on' : ''}${danger ? ' danger' : ''}`, type: 'button', title, 'aria-label': title, disabled, onclick,
    }, icon(name, { size: 16 }));
  }

  function renderPanel() {
    const voice = transcript.snapshot;
    if (!transcript.visible(Date.now(), LINGER_MS)) {
      if (panel) {
        panel.classList.add('closing');
        const closing = panel;
        panel = null;
        orb?.orb?.destroy?.();
        orb = null;
        setTimeout(() => closing.remove(), 220);
      }
      return;
    }
    ensurePanel();
    const active = transcript.active;
    const { label, tone } = active ? voiceLabel(voice) : transcript.error ? { label: 'Voice problem', tone: 'error' }
      : { label: 'Conversation ended', tone: 'idle' };
    panel.className = `voice-panel tone-${tone}${active ? ' active' : ' ended'}`;
    orb.orb.set(active
      ? { energy: 0.2 + voice.level * 0.7, speed: voice.state === 'speaking' ? 2.4 : voice.state === 'thinking' ? 1.8 : 1.2, glow: 1 }
      : { energy: 0.05, speed: 0.4, glow: tone === 'error' ? 0.35 : 0.7 });
    const brain = voice.brain === 'realtime' ? 'Realtime voice' : voice.brain === 'claude' ? 'Claude voice' : '';
    const shortcut = voice.shortcut || '⌃⌥Space';
    const sub = active ? [brain, `${shortcut} or Esc ends it`].filter(Boolean).join(' · ')
      : transcript.error || (transcript.turns.length ? 'Saved in Chats with your other conversations.' : 'Nothing was said.');
    const buttons = active ? [
      circle(voice.micMuted ? 'micOff' : 'mic', voice.micMuted ? 'Unmute the microphone' : 'Mute the microphone',
        () => send(voice.micMuted ? 'unmute' : 'mute'), { active: voice.micMuted }),
      circle('stop', 'Stop speaking', () => send('stopSpeaking'), { disabled: !(voice.state === 'speaking' || voice.state === 'thinking') }),
      circle('close', `End the conversation (${shortcut})`, () => send('end'), { danger: true }),
    ] : [
      transcript.conversationId && transcript.turns.length ? h('button', {
        class: 'btn-ghost', type: 'button',
        onclick: () => {
          ctx.show('chats');
          ctx.chats.openConversation(transcript.conversationId);
          dismiss();
        },
      }, icon('bubble', { size: 13 }), h('span', { text: 'Open in Chats' })) : null,
      h('button', { class: 'btn-ghost', type: 'button', onclick: () => start() }, icon('mic', { size: 13 }), h('span', { text: 'Talk again' })),
      circle('close', 'Close', () => dismiss()),
    ];
    const lines = transcript.turns.length ? transcript.turns.map((turn, index) => {
      const last = index === transcript.turns.length - 1;
      if (turn.role === 'user') return h('div', { class: 'vt vt-user' }, h('div', { class: 'vt-bubble', text: turn.text }));
      return h('div', { class: 'vt vt-assistant' }, h('img', { class: 'vt-avatar', src: 'orb.svg', alt: '' }),
        h('div', { class: 'vt-text' }, turn.text, !turn.final && last && active ? h('span', { class: 'caret' }) : null));
    }) : [h('div', { class: 'vt-idle', text: active ? idleCaption(voice) : '' })];
    if (active && transcript.turns.length && voice.state === 'thinking') {
      lines.push(h('div', { class: 'vt vt-assistant' }, h('img', { class: 'vt-avatar', src: 'orb.svg', alt: '' }),
        h('div', { class: 'typing' }, h('span'), h('span'), h('span'))));
    }
    const scroller = h('div', { class: 'voice-transcript' }, lines);
    panel.replaceChildren(
      h('div', { class: 'voice-head' }, orb,
        h('div', { class: 'voice-titles' },
          h('div', { class: `voice-label tone-${tone}`, text: label }),
          h('div', { class: 'voice-sub', text: sub })),
        h('div', { class: 'voice-buttons' }, buttons)),
      scroller);
    requestAnimationFrame(() => {
      scroller.scrollTop = scroller.scrollHeight;
    });
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

  let drawn = '';
  onNative((state, changed) => {
    if (!changed.includes('voice')) return;
    transcript.apply(state.voice);
    renderButton();
    // The mic level comes ~12 times a second: it only moves the orb; everything else redraws the panel.
    const key = JSON.stringify([transcript.turns, transcript.active, transcript.ended, { ...transcript.snapshot, level: 0 }]);
    if (key !== drawn || !panel !== !transcript.visible(Date.now(), LINGER_MS)) {
      drawn = key;
      renderPanel();
    } else if (panel && orb && transcript.active) {
      const voice = transcript.snapshot;
      orb.orb.set({ energy: 0.2 + voice.level * 0.7 });
    }
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
