// Settings: the devices (the R1, paired iPhones and watches with Unpair, Pair iPhone…), the Mac's ChatGPT login
// (including "using your Codex login"), the voice (talk shortcut, "Hey Rabbit"), the Agent Dock on/off and its
// shortcuts, and about. The native parts (pairing and ChatGPT windows, the voice, the dock) go through the shell.

import { h } from './dom.js';
import { icon } from './icons.js';
import { hasShell, nativeState, onNative, postNative } from './native.js';
import { Resource } from './resource.js';
import { assistantLine, chatgptStatus, deviceLine, groupDevices, platformLabel, r1Status } from './status.js';
import { keycap, reportDragExclusions, sheet, spinner, toast, toggle } from './ui.js';
import { isActive, normalizeVoice } from './voice.js';

export function createSettings(ctx, el) {
  const { summary } = ctx;
  let visible = false;
  let drawn = '';
  const devices = new Resource(async () => {
    const answer = await ctx.api.devices();
    return answer && Array.isArray(answer.devices) ? answer.devices : [];
  });
  const chatgpt = new Resource(() => ctx.api.chatgpt());
  const unpairing = new Set();

  const head = h('header', { class: 'view-head titlebar' });
  const body = h('div', { class: 'view-scroll' });
  const content = h('div', { class: 'settings' });
  body.append(content);
  el.append(head, body);

  function group(title, footer, ...rows) {
    return h('section', { class: 'set-group' },
      title ? h('h2', { class: 'set-title', text: title }) : null,
      h('div', { class: 'set-card' }, rows.flat().filter(Boolean)),
      footer ? h('p', { class: 'set-foot', text: footer }) : null);
  }

  function row({ glyph, tile = '', title, sub = '', note = '', trailing = null, child = false, tone = '' }) {
    return h('div', { class: `set-row${child ? ' child' : ''}${tone ? ` tone-${tone}` : ''}` },
      glyph ? h('span', { class: `set-tile ${tile}`.trim() }, icon(glyph, { size: 16 })) : null,
      h('div', { class: 'set-main' },
        h('div', { class: 'set-row-title', text: title }),
        sub ? h('div', { class: 'set-row-sub', text: sub }) : null,
        note ? h('div', { class: 'set-row-note', text: note }) : null),
      trailing ? h('div', { class: 'set-trailing' }, trailing) : null);
  }

  function nativeButton(label, message, { primary = false } = {}) {
    const shell = hasShell();
    return h('button', {
      class: primary ? 'btn small' : 'btn-ghost', type: 'button', disabled: !shell,
      title: shell ? label : 'Works in the SamRabbit app',
      onclick: () => {
        if (!postNative(message)) toast('That opens in the SamRabbit app.');
      },
    }, h('span', { text: label }));
  }

  function presence(tone) {
    return h('span', { class: `presence tone-${tone}` });
  }

  // ------------------------------------------------------------------ devices

  function confirmUnpair(device, children) {
    const go = h('button', { class: 'btn danger', type: 'button' }, h('span', { text: 'Unpair' }));
    const cancel = h('button', { class: 'btn-ghost big', type: 'button' }, 'Cancel');
    const watches = children.map((c) => c.name);
    const { close } = sheet({
      title: `Unpair ${device.name}?`,
      text: (watches.length ? `${watches.join(' and ')} ${watches.length === 1 ? 'is' : 'are'} unpaired with it. ` : '')
        + 'It stops reaching this Mac at once. To use it again, pair it with a new code.',
      buttons: [cancel, go],
      className: 'confirm',
    });
    cancel.addEventListener('click', close);
    go.addEventListener('click', async () => {
      close();
      unpairing.add(device.deviceId);
      render(true);
      try {
        await ctx.api.unpair(device.deviceId);
        toast(`${device.name} is unpaired`, { tone: 'ok' });
      } catch (error) {
        toast(error && error.status === 404 ? 'It was already unpaired.' : 'Couldn’t unpair it. Is the bridge running?');
      } finally {
        unpairing.delete(device.deviceId);
        await devices.refresh();
        summary.refresh();
      }
    });
    setTimeout(() => go.focus(), 30);
  }

  function devicesGroup(now) {
    const r1 = r1Status(summary.value, now);
    const list = devices.value || (summary.value && Array.isArray(summary.value.devices) ? summary.value.devices : null);
    const grouped = groupDevices(list || []);
    const rows = [row({
      glyph: 'r1', title: 'Rabbit R1', tone: r1.tone,
      sub: summary.value ? `${r1.line} · its conversations are in Chats` : summary.error ? 'The bridge’s summary isn’t answering.' : 'Checking…',
      trailing: [r1.battery != null ? h('span', { class: 'battery-text', text: `${r1.battery}%` }) : null, presence(r1.tone)],
    })];
    for (const device of grouped) {
      const children = device.child ? [] : grouped.filter((d) => d.child && d.parentId === device.deviceId);
      const busy = unpairing.has(device.deviceId);
      const recent = device.lastSeenAt != null && now - device.lastSeenAt < 10 * 60_000;
      rows.push(row({
        glyph: device.platform === 'watchos' ? 'watch' : 'phone', child: device.child,
        title: device.name, sub: `${platformLabel(device.platform)} · ${deviceLine(device, now)}`, tone: recent ? 'ok' : 'idle',
        trailing: device.child ? presence(recent ? 'ok' : 'idle') : busy ? spinner() : h('button', {
          class: 'btn-ghost danger', type: 'button', onclick: () => confirmUnpair(device, children),
        }, icon('unlink', { size: 13 }), h('span', { text: 'Unpair…' })),
      }));
    }
    if (list && !grouped.length) {
      rows.push(row({ glyph: 'phone', tile: 'dim', title: 'No iPhone yet', sub: 'Pair the SamRabbit iPhone app to get Tasks, Chats and Talk on the go.' }));
    } else if (!list && devices.error) {
      rows.push(row({ glyph: 'alert', tile: 'dim', title: 'Couldn’t read the paired devices', sub: 'Is the bridge running?' }));
    }
    rows.push(h('div', { class: 'set-actions' }, nativeButton('Pair iPhone…', { type: 'pairPhone' }, { primary: true }),
      hasShell() ? null : h('span', { class: 'set-row-note', text: 'Pairing opens in the SamRabbit app.' })));
    return group('Devices', 'Unpairing an iPhone unpairs its watch too.', rows);
  }

  // ------------------------------------------------------------------ ChatGPT

  function chatgptGroup() {
    const status = chatgptStatus(chatgpt.value);
    const brain = assistantLine(summary.value);
    return group('ChatGPT', 'The Mac’s voice and the watch talk through ChatGPT’s realtime voice when it is connected; otherwise they answer with Claude.',
      row({
        glyph: 'sparkles', tile: status.connected ? 'accent' : '', tone: status.tone,
        title: chatgpt.error && !chatgpt.value ? 'Couldn’t read the ChatGPT login' : `ChatGPT · ${status.title}`,
        sub: status.detail, note: status.note,
        trailing: [presence(status.tone), nativeButton(status.connected ? 'Manage…' : 'Connect ChatGPT…', { type: 'connectChatGPT' }, { primary: !status.connected })],
      }),
      brain ? row({ glyph: 'mic', title: 'Voice brain', sub: brain }) : null);
  }

  // ------------------------------------------------------------------ voice and the dock

  function voiceGroup() {
    const voice = normalizeVoice(nativeState().voice);
    const shell = hasShell();
    const shortcut = voice.shortcut || (shell && voice.shortcutProblem ? '' : '⌃⌥Space');
    const wake = !shell ? 'Works in the SamRabbit app.' : !voice.wakeEnabled ? 'Off: only the shortcut, the Talk button and the dock start a conversation.'
      : voice.wakeArmed ? 'Listening on this Mac. Nothing leaves it before the phrase.'
        : voice.wakeProblem || (isActive(voice) ? 'Paused while you talk.' : 'Getting ready…');
    return group('Voice', 'Say “Hey Rabbit, …” or press the shortcut from any app. The conversation shows here and in the dock; it is saved in Chats.',
      row({
        glyph: 'keyboard', title: 'Talk to SamRabbit',
        sub: voice.shortcutProblem || 'From any app; again to end.',
        tone: voice.shortcutProblem ? 'warn' : '',
        trailing: shortcut ? keycap(shortcut) : h('span', { class: 'set-row-note', text: 'Unavailable' }),
      }),
      row({
        glyph: 'mic', title: 'Listen for “Hey Rabbit”', sub: wake,
        tone: shell && voice.wakeEnabled && !voice.wakeArmed && voice.wakeProblem ? 'warn' : '',
        trailing: toggle({
          checked: voice.wakeEnabled, disabled: !shell, label: 'Listen for Hey Rabbit',
          onchange: (on) => postNative({ type: 'voice', action: 'wake', on }),
        }),
      }));
  }

  function dockGroup() {
    const dock = nativeState().dock;
    const shell = hasShell() && dock !== null;
    const enabled = dock ? dock.enabled !== false : true;
    const shortcuts = (nativeState().shortcuts || []).filter((s) => s && s.id !== 'talk');
    return group('Agent Dock', 'The dock floats over other apps whenever this window isn’t in front: what needs you, what’s working, a new task and Talk.',
      row({
        glyph: 'dock', title: 'Show the Agent Dock',
        sub: !shell ? 'Works in the SamRabbit app.' : enabled ? 'On: it steps aside while you are in this window.' : 'Off until you turn it on here or press ⌃⌥K.',
        trailing: toggle({
          checked: enabled, disabled: !shell, label: 'Show the Agent Dock',
          onchange: (on) => postNative({ type: 'dock', enabled: on }),
        }),
      }),
      shortcuts.map((shortcut) => row({
        glyph: 'keyboard', title: shortcut.label || shortcut.id, sub: shortcut.problem || '', tone: shortcut.problem ? 'warn' : '',
        trailing: shortcut.keys ? keycap(shortcut.keys) : null,
      })),
      dock && dock.canCustomize ? h('div', { class: 'set-actions' }, nativeButton('Customize Shortcuts…', { type: 'dockSettings' })) : null);
  }

  function aboutGroup() {
    const app = nativeState().app || {};
    const mac = summary.value && summary.value.mac ? summary.value.mac : null;
    return group('About', null,
      row({
        glyph: 'laptop', title: mac && mac.name ? mac.name : 'This Mac',
        sub: [summary.value ? 'Bridge running' : summary.error ? 'Bridge not answering' : 'Checking the bridge…', app.bridge || location.host].filter(Boolean).join(' · '),
        tone: summary.value ? 'ok' : summary.error ? 'error' : 'idle',
        trailing: presence(summary.value ? 'ok' : summary.error ? 'error' : 'idle'),
      }),
      row({
        glyph: 'info', title: `SamRabbit ${app.version || ''}`.trim(),
        sub: 'Your R1, iPhone, Watch and Mac in one place.',
        trailing: h('button', { class: 'btn-ghost', type: 'button', onclick: () => window.SamRabbitApp.refresh() },
          icon('refresh', { size: 13 }), h('span', { text: 'Reload' })),
      }));
  }

  // ------------------------------------------------------------------ drawing

  function render(force = false) {
    if (!visible) return;
    const now = Date.now();
    const native = nativeState();
    const voice = native.voice ? { ...normalizeVoice(native.voice), level: 0, caption: '', heard: '', state: isActive(normalizeVoice(native.voice)) } : null;
    const key = JSON.stringify([summary.loadedAt, Boolean(summary.error), devices.loadedAt, Boolean(devices.error), chatgpt.loadedAt,
      Boolean(chatgpt.error), voice, native.dock, native.shortcuts, native.app, [...unpairing], Math.floor(now / 60_000)]);
    if (!force && key === drawn) return;
    drawn = key;
    head.replaceChildren(h('div', { class: 'head-stack' }, h('h1', { class: 'view-title', text: 'Settings' })));
    const scroll = body.scrollTop;
    content.replaceChildren(devicesGroup(now), chatgptGroup(), voiceGroup(), dockGroup(), aboutGroup());
    body.scrollTop = scroll;
    reportDragExclusions();
  }

  for (const resource of [summary, devices, chatgpt]) resource.on(() => render());
  // Pairing and the ChatGPT login finish in their own windows: read again when this one is back in front.
  window.addEventListener('focus', () => {
    if (!visible) return;
    devices.fresh(5_000);
    chatgpt.fresh(5_000);
  });
  onNative((_state, changed) => {
    if (changed.some((key) => key !== 'voice') || visible) render();
  });

  return {
    el,
    shown() {
      visible = true;
      drawn = '';
      summary.fresh(15_000);
      devices.fresh(15_000);
      chatgpt.fresh(15_000);
      render();
    },
    hidden() {
      visible = false;
    },
    handleKey() {
      return false;
    },
  };
}
