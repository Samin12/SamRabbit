// Tasks: the whole agent inbox (CONTRACTS-WAVE7 §B) — Needs you, Working and Recent, filtered by source (T3 · Claude ·
// Codex), a detail pane with the item's last messages and every action it supports right now, and the "New task"
// composer (T3 project, Claude or Codex, model). The keys are the dock's: J/K or ↓/↑ move, ↩ opens where it lives,
// E approves with the recommended option, R replies, N starts a new task, Esc closes the composer, then the selection.

import { h } from './dom.js';
import { icon } from './icons.js';
import {
  FILTERS, agentLabel, filterCounts, isChat, keyAction, keyName, keyRow, metaLine, needsYou, openLabel,
  replyPlaceholder, rowIds, sourceLabel, supports,
} from './inbox.js';
import { approvalCard, itemMeta, itemRow, noteLine, questionCard, shortAgo, sourceGlyph } from './items.js';
import { createOrb } from './orb.js';
import { isVoiceNote, noteAction } from './inbox.js';
import { autosize, keycap, redrawWhenFree, reportDragExclusions, segmented, spinner } from './ui.js';

const FILTER_KEY = 'samrabbit.tasks.filter';

function typingIn(node) {
  const active = document.activeElement;
  return Boolean(active && node.contains(active) && (['INPUT', 'TEXTAREA', 'SELECT'].includes(active.tagName)
    || active.isContentEditable));
}

/** Redraws `container` without losing the field that has the keys (matched by data-focus), its text and caret. */
function redrawKeepingFocus(container, children) {
  const active = document.activeElement;
  const key = active && container.contains(active) && active.dataset ? active.dataset.focus : null;
  const caret = key && typeof active.selectionStart === 'number' ? [active.selectionStart, active.selectionEnd] : null;
  const scroll = container.scrollTop;
  container.replaceChildren(...children.flat().filter(Boolean));
  container.scrollTop = scroll;
  if (!key) return;
  const again = container.querySelector(`[data-focus="${CSS.escape(key)}"]`);
  if (!again) return;
  again.focus({ preventScroll: true });
  if (caret) {
    try {
      again.setSelectionRange(caret[0], caret[1]);
    } catch {
      // not a text field
    }
  }
}

export function createTasks(ctx, el) {
  const { agents, chats } = ctx;
  let visible = false;
  let filter = 'all';
  try {
    filter = FILTERS.some((f) => f.value === localStorage.getItem(FILTER_KEY)) ? localStorage.getItem(FILTER_KEY) : 'all';
  } catch {
    // private mode
  }
  let selected = null;
  let composing = false;
  let composeText = '';
  let listKey = '';
  let detailKey = '';

  // ------------------------------------------------------------------ skeleton

  const listHead = h('header', { class: 'view-head titlebar tasks-head' });
  const filterBar = h('div', { class: 'tasks-filter' });
  const listScroll = h('div', { class: 'tasks-scroll', role: 'listbox', 'aria-label': 'Tasks' });
  const listPane = h('aside', { class: 'tasks-list' }, listHead, filterBar, listScroll);
  const detailHead = h('header', { class: 'view-head titlebar detail-head' });
  const detailScroll = h('div', { class: 'detail-scroll' });
  const detailFoot = h('footer', { class: 'detail-foot' });
  const detailPane = h('main', { class: 'tasks-detail' }, detailHead, detailScroll, detailFoot);
  el.append(h('div', { class: 'tasks' }, listPane, detailPane));
  const emptyOrb = createOrb({ size: 120, energy: 0.12, speed: 0.8, className: 'empty-orb' });

  // ------------------------------------------------------------------ the list

  function sections() {
    return agents.store.sections(filter);
  }

  function visibleRows() {
    return rowIds(sections()).map((id) => agents.item(id)).filter(Boolean);
  }

  function renderListHead() {
    const counts = agents.counts();
    const parts = [];
    if (agents.connection === 'online' || agents.items.length) {
      parts.push(counts.needsYou ? `${counts.needsYou} need${counts.needsYou === 1 ? 's' : ''} you` : 'Nothing needs you');
      if (counts.working) parts.push(`${counts.working} working`);
    }
    listHead.replaceChildren(
      h('div', { class: 'head-stack' },
        h('h1', { class: 'view-title', text: 'Tasks' }),
        h('span', { class: 'view-meta', text: parts.join(' · ') })),
      h('button', {
        class: `tool-btn${composing ? ' on' : ''}`, type: 'button', title: 'New task (N)', 'aria-label': 'New task',
        onclick: () => openComposer(),
      }, icon('plus', { size: 15 }), h('span', { text: 'New task' })));
    const counted = filterCounts(agents.items);
    filterBar.replaceChildren(segmented(FILTERS.map((f) => ({ ...f, count: counted[f.value] || 0 })), filter, (value) => {
      filter = value;
      try {
        localStorage.setItem(FILTER_KEY, value);
      } catch {
        // private mode
      }
      render();
    }, { label: 'Source' }));
  }

  function offlineBanner() {
    if (agents.connection !== 'offline') return null;
    const status = agents.offlineStatus;
    const [title, text] = status === 404
      ? ['This bridge has no agent inbox yet', 'Update it with companion/mac-bridge/install.sh.']
      : status === 401 || status === 403 ? ['The bridge didn’t accept SamRabbit', 'Run companion/desktop/install.sh again.']
        : ['The Mac bridge isn’t answering', 'SamRabbit keeps trying.'];
    return h('div', { class: 'banner' }, icon('alert', { size: 15 }),
      h('div', null, h('div', { class: 'banner-title', text: title }), h('div', { class: 'banner-text', text }),
        agents.items.length ? h('div', { class: 'banner-text', text: 'What you see below may be out of date.' }) : null));
  }

  function renderList() {
    const now = Date.now();
    const list = sections();
    const busy = [...agents.busy].join();
    const key = JSON.stringify([list, selected, busy, filter, agents.connection, Math.floor(now / 60_000)]);
    renderListHead();
    if (key === listKey) return;
    listKey = key;
    const children = [offlineBanner()];
    if (!list.length) {
      if (agents.connection === 'connecting') {
        children.push(h('div', { class: 'conv-skeleton' }, [0, 1, 2, 3].map(() => h('div', { class: 'sk-row' }, h('span'), h('span')))));
      } else if (agents.connection === 'online') {
        children.push(h('div', { class: 'list-empty' }, icon('checkCircle', { size: 20 }),
          h('div', { text: filter === 'all' ? 'No agents right now.' : `No ${sourceLabel(filter)} sessions in the last days.` })));
      }
    }
    for (const section of list) {
      const needs = section.kind === 'needsYou';
      children.push(h('section', { class: `task-group ${section.kind}` },
        h('h2', { class: `conv-group-title${needs ? ' live' : ''}` }, h('span', { text: section.title }),
          h('span', { class: 'group-count', text: String(section.items.length) })),
        section.items.map((item) => itemRow(item, {
          now,
          selected: item.id === selected,
          busy: agents.busy.get(item.id) || '',
          onclick: () => select(item.id),
        }))));
    }
    const scroll = listScroll.scrollTop;
    listScroll.replaceChildren(...children.filter(Boolean));
    listScroll.scrollTop = scroll;
  }

  // ------------------------------------------------------------------ selection

  function select(id, { scroll = false } = {}) {
    composing = false;
    selected = id;
    agents.watch(id && !id.startsWith('pending:') ? id : null);
    listKey = '';
    detailKey = '';
    render();
    if (scroll && id) {
      const row = listScroll.querySelector(`[data-id="${CSS.escape(id)}"]`);
      if (row) row.scrollIntoView({ block: 'nearest' });
    }
  }

  // ------------------------------------------------------------------ the detail pane

  function openItem(item) {
    if (isChat(item)) {
      ctx.show('chats');
      chats.openConversation(item.id.slice(item.id.indexOf(':') + 1));
      return;
    }
    agents.open(item).then((reply) => {
      if (reply && reply.how === 'desktop' && reply.conversationId) {
        ctx.show('chats');
        chats.openConversation(reply.conversationId);
      }
    });
  }

  function capsule(label, glyph, onclick, { tone = '', disabled = false, title = '' } = {}) {
    return h('button', { class: `capsule${tone ? ` ${tone}` : ''}`, type: 'button', disabled, title: title || label, onclick },
      glyph ? icon(glyph, { size: 13 }) : null, h('span', { text: label }));
  }

  function busyLabel(kind) {
    return { approve: 'Sending…', answer: 'Sending…', reply: 'Replying…', stop: 'Stopping…', open: 'Opening…', seen: 'Marking…', act: 'On it…' }[kind] || '…';
  }

  function actionBar(item) {
    const busy = agents.busy.get(item.id);
    // A voice note: what the bridge suggested ("Start as task"), or "Try again" when it failed.
    const note = noteAction(item);
    return h('div', { class: 'detail-actions' },
      note ? capsule(note.label, note.action ? 'send' : 'refresh', () => agents.actOnNote(item), { tone: 'accent', disabled: Boolean(busy) }) : null,
      supports(item, 'open') ? capsule(openLabel(item), isChat(item) ? 'bubble' : 'external', () => openItem(item), { disabled: Boolean(busy) }) : null,
      supports(item, 'stop') && item.status === 'working'
        ? capsule('Stop', 'stop', () => agents.stopItem(item), { disabled: Boolean(busy) }) : null,
      supports(item, 'seen') && item.unread
        ? capsule('Mark seen', 'check', () => agents.markSeen(item), { tone: 'quiet', disabled: Boolean(busy) }) : null,
      busy ? h('span', { class: 'busy-line' }, spinner(), h('span', { text: busyLabel(busy) })) : null);
  }

  function messageList(item) {
    const detail = agents.details.get(item.id);
    const messages = detail ? detail.messages : [];
    if (!messages.length) {
      if (agents.loadingDetail.has(item.id)) {
        return h('div', { class: 'detail-loading' }, spinner(), h('span', { text: 'Loading the conversation…' }));
      }
      return item.summary ? h('div', { class: 'thread' },
        h('div', { class: 'tm tm-assistant' }, h('div', { class: 'tm-who', text: whoLabel(item, 'assistant') }),
          h('div', { class: 'tm-text', text: item.summary }))) : null;
    }
    return h('div', { class: 'thread' }, messages.map((message) => h('div', { class: `tm tm-${message.role}` },
      h('div', { class: 'tm-who' }, h('span', { text: whoLabel(item, message.role) }),
        message.at ? h('time', { text: shortAgo(message.at) }) : null),
      h('div', { class: 'tm-text', text: message.text }))));
  }

  function whoLabel(item, role) {
    if (role === 'user') return 'You';
    if (isChat(item) || isVoiceNote(item)) return 'SamRabbit';
    return agentLabel(item) || sourceLabel(item.source);
  }

  function waitingElsewhere(item) {
    if (item.status !== 'needs-approval' || supports(item, 'approve') || agents.notes.get(item.id)) return null;
    return noteLine({
      text: item.source === 'claude' ? (item.live ? 'It’s waiting in the terminal — Open to answer there.' : 'Answer it in the terminal — Open takes you there.')
        : 'Answer it in the app it runs in — Open takes you there.',
      isError: false,
    });
  }

  function detailBody(item) {
    const now = Date.now();
    const busy = agents.busy.has(item.id);
    const pendingCards = [];
    if (supports(item, 'approve')) {
      for (const approval of item.pending.approvals) {
        pendingCards.push(approvalCard(item, approval, { busy, onDecide: (decision) => agents.approve(item, approval.requestId, decision) }));
      }
    }
    if (supports(item, 'answer')) {
      for (const request of item.pending.inputs) {
        const card = questionCard(item, request, agents, { busy });
        card.querySelectorAll('input.field').forEach((field, index) => {
          field.dataset.focus = `answer:${item.id}:${request.requestId}:${index}`;
        });
        pendingCards.push(card);
      }
    }
    const note = agents.notes.get(item.id);
    return [
      h('div', { class: 'detail-top' },
        sourceGlyph(item, 44),
        h('div', { class: 'detail-titles' },
          h('h2', { class: 'detail-title', text: item.title }),
          itemMeta(item),
          h('div', { class: 'detail-sub', text: metaLine(sourceLabel(item.source), item.cwd ? item.cwd.replace(/^\/Users\/[^/]+/, '~') : null,
            item.updatedAt ? `Updated ${shortAgo(item.updatedAt, now) === 'now' ? 'just now' : `${shortAgo(item.updatedAt, now)} ago`}` : null) }))),
      actionBar(item),
      note ? noteLine(note, { onOpen: supports(item, 'open') ? () => openItem(item) : null }) : null,
      waitingElsewhere(item),
      item.status === 'working' && (item.phase || typeof item.progress === 'number') ? h('div', { class: 'detail-progress' },
        h('div', { class: 'detail-progress-line' }, h('span', { text: item.phase || 'Working' }),
          typeof item.progress === 'number' ? h('span', { class: 'pct', text: `${Math.round(item.progress * 100)}%` }) : null),
        typeof item.progress === 'number' ? h('div', { class: 'item-progress big' },
          h('span', { style: `width:${Math.round(Math.max(0.03, Math.min(1, item.progress)) * 100)}%` })) : null) : null,
      h('div', { class: 'detail-section-title', text: 'Conversation' }),
      messageList(item),
      pendingCards.length ? h('div', { class: 'detail-pending' }, pendingCards) : null,
    ];
  }

  // The reply field lives across redraws (its draft and caret survive inbox updates).
  const replyArea = h('textarea', { class: 'reply-input', rows: '1', spellcheck: 'true', 'data-focus': 'reply' });
  const replySend = h('button', { class: 'send-btn', type: 'button', title: 'Send (↩)', 'aria-label': 'Send' }, icon('arrowUp', { size: 15 }));
  const replyBox = h('div', { class: 'reply-box' }, replyArea, replySend);
  const fitReply = autosize(replyArea, 180);
  let replyFor = null;

  function sendReply() {
    const item = agents.item(replyFor);
    if (!item) return;
    agents.replyDrafts.set(item.id, replyArea.value);
    if (!replyArea.value.trim()) return;
    agents.reply(item).then(() => {
      if (replyFor === item.id) {
        replyArea.value = agents.replyDrafts.get(item.id) || '';
        fitReply();
      }
    });
    replyArea.value = '';
    fitReply();
  }
  replyArea.addEventListener('input', () => {
    if (replyFor) agents.replyDrafts.set(replyFor, replyArea.value);
    replySend.disabled = !replyArea.value.trim();
  });
  replyArea.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      sendReply();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      replyArea.blur();
    }
  });
  replySend.addEventListener('click', sendReply);

  function renderFoot(item) {
    if (!item || composing || !supports(item, 'reply')) {
      detailFoot.hidden = true;
      replyFor = null;
      return;
    }
    detailFoot.hidden = false;
    if (replyFor !== item.id) {
      replyFor = item.id;
      replyArea.value = agents.replyDrafts.get(item.id) || '';
      requestAnimationFrame(fitReply);
    }
    replyArea.placeholder = replyPlaceholder(item);
    replySend.disabled = !replyArea.value.trim() || agents.busy.has(item.id);
    if (!detailFoot.contains(replyBox)) {
      detailFoot.replaceChildren(replyBox, h('div', { class: 'reply-hint' },
        h('span', { text: '↩ send · ⇧↩ new line' }),
        h('span', { class: 'reply-to', text: item.source === 't3' ? 'Goes to the T3 thread' : 'Continues the session in Terminal' })));
    } else {
      detailFoot.querySelector('.reply-to').textContent = item.source === 't3' ? 'Goes to the T3 thread' : 'Continues the session in Terminal';
    }
  }

  function emptyDetail() {
    const counts = agents.counts();
    return [h('div', { class: 'detail-empty' }, emptyOrb,
      h('h2', { class: 'empty-title', text: counts.needsYou ? `${counts.needsYou} need${counts.needsYou === 1 ? 's' : ''} you` : 'All caught up' }),
      h('p', { class: 'empty-text', text: 'Pick a task to see its last messages and answer it here. T3 Code threads, Claude Code and Codex sessions all land in this list.' }),
      h('div', { class: 'key-legend' },
        [['J', 'K', 'move'], ['↩', null, 'open'], ['E', null, 'approve'], ['R', null, 'reply'], ['N', null, 'new task']]
          .map(([a, b, label]) => h('span', { class: 'legend' }, keycap(a), b ? keycap(b) : null, h('span', { text: label })))),
      h('button', { class: 'btn', type: 'button', onclick: () => openComposer() }, icon('plus', { size: 14 }), h('span', { text: 'New task' })))];
  }

  // ------------------------------------------------------------------ new task

  const composeArea = h('textarea', {
    class: 'compose-input', rows: '4', spellcheck: 'true', 'data-focus': 'compose', placeholder: 'What should the agent do?',
    'aria-label': 'New task',
  });
  const fitCompose = autosize(composeArea, 320);
  composeArea.addEventListener('input', () => {
    composeText = composeArea.value;
    const go = el.querySelector('.compose-send');
    if (go) go.disabled = !composeText.trim() || agents.composeBusy;
  });
  composeArea.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      submitTask();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      if (!composeArea.value.trim()) closeComposer();
      else composeArea.blur();
    }
  });

  function openComposer() {
    composing = true;
    detailKey = '';
    listKey = '';
    agents.loadTargets();
    render();
    requestAnimationFrame(() => {
      composeArea.focus();
      fitCompose();
    });
  }

  function closeComposer() {
    composing = false;
    detailKey = '';
    listKey = '';
    render();
  }

  async function submitTask() {
    if (!composeText.trim() || agents.composeBusy) return;
    const id = await agents.newTask(composeText);
    if (!id) return;
    composeText = '';
    composeArea.value = '';
    composing = false;
    filter = filter === 'all' || filter === 't3' ? filter : 'all';
    select(id);
  }

  function picker(label, glyph, options, value, onchange) {
    const select = h('select', { class: 'picker-select', 'aria-label': label });
    for (const option of options) {
      const node = h('option', { value: option.value, text: option.label });
      if (option.value === value) node.selected = true;
      select.append(node);
    }
    select.addEventListener('change', () => onchange(select.value));
    return h('label', { class: 'picker' }, h('span', { class: 'picker-label', text: label }),
      h('span', { class: 'picker-box' }, icon(glyph, { size: 14 }), select, icon('chevronDown', { size: 12 })));
  }

  function composerBody() {
    const targets = agents.targets;
    const choice = agents.choice;
    const projects = targets && Array.isArray(targets.projects) ? targets.projects : [];
    const agentList = targets && Array.isArray(targets.agents) ? targets.agents : [];
    const agent = agentList.find((a) => a.id === choice.agent);
    const models = agent && Array.isArray(agent.models) ? agent.models : [];
    let pickers;
    if (!targets && agents.targetsError) {
      pickers = h('div', { class: 'item-note error' }, icon('alert', { size: 13 }),
        h('span', { text: agents.targetsError.status === 409 || agents.targetsError.status === 503
          ? 'T3 Code isn’t connected to the bridge, so a new task can’t start yet.' : 'The bridge didn’t say where a task can go.' }),
        h('button', { class: 'link', type: 'button', onclick: () => agents.loadTargets({ force: true }) }, 'Try again'));
    } else if (!targets) {
      pickers = h('div', { class: 'detail-loading' }, spinner(), h('span', { text: 'Loading your T3 projects…' }));
    } else {
      pickers = h('div', { class: 'pickers' },
        picker('Project', 'folder', projects.map((p) => ({ value: p.id, label: p.title })), choice.projectId,
          (projectId) => agents.pick({ projectId })),
        h('div', { class: 'picker' }, h('span', { class: 'picker-label', text: 'Agent' }),
          segmented(agentList.map((a) => ({ value: a.id, label: a.label, icon: a.id === 'codex' ? 'code' : 'asterisk' })),
            choice.agent, (id) => agents.pick({ agent: id, model: null }), { label: 'Agent' })),
        picker('Model', 'cpu', models.map((m) => ({ value: m.id, label: m.label })), choice.model,
          (model) => agents.pick({ model })));
    }
    composeArea.value = composeText;
    const ready = Boolean(targets) && Boolean(composeText.trim()) && !agents.composeBusy;
    return [h('div', { class: 'compose' },
      h('div', { class: 'compose-head' },
        h('span', { class: 'compose-icon' }, icon('sparkles', { size: 18 })),
        h('div', null, h('h2', { class: 'detail-title', text: 'New task' }),
          h('div', { class: 'detail-sub', text: 'Starts a T3 Code thread with the agent and model you pick. It shows up under Working.' }))),
      h('div', { class: 'compose-card' }, composeArea,
        h('div', { class: 'compose-bar' },
          h('span', { class: 'reply-hint', text: '↩ start · ⇧↩ new line · Esc closes' }),
          h('button', { class: 'btn compose-send', type: 'button', disabled: !ready, onclick: () => submitTask() },
            agents.composeBusy ? spinner() : icon('arrowUp', { size: 14 }),
            h('span', { text: agents.composeBusy ? 'Starting…' : `Start with ${agents.choiceLabel() || 'the agent'}` })))),
      pickers,
      agents.composeNote ? noteLine(agents.composeNote) : null)];
  }

  // ------------------------------------------------------------------ drawing

  function renderDetail() {
    const item = selected ? agents.item(selected) : null;
    const detail = item ? agents.details.get(item.id) : null;
    const key = JSON.stringify([composing, composing ? [agents.targets, agents.choice, agents.composeBusy, agents.composeNote, Boolean(agents.targetsError)] : null,
      item, detail, agents.busy.get(selected) || '', agents.notes.get(selected) || null, agents.loadingDetail.has(selected),
      item ? agents.selections.get(item.id) : null, Math.floor(Date.now() / 60_000)]);
    renderFoot(item);
    if (key === detailKey) return;
    detailKey = key;
    detailHead.replaceChildren(...[
      composing ? h('button', { class: 'tool-btn', type: 'button', onclick: () => closeComposer() }, icon('close', { size: 14 }), h('span', { text: 'Cancel' }))
        : item ? h('div', { class: 'detail-crumb' }, h('span', { text: sourceLabel(item.source) }),
          item.project ? icon('chevronRight', { size: 12 }) : null, item.project ? h('span', { text: item.project }) : null) : null].filter(Boolean));
    if (composing) redrawKeepingFocus(detailScroll, composerBody());
    else if (item) redrawKeepingFocus(detailScroll, detailBody(item));
    else redrawKeepingFocus(detailScroll, emptyDetail());
    detailPane.classList.toggle('composing', composing);
    reportDragExclusions();
  }

  function render() {
    if (!visible) return;
    // Never between a press and its release: the row or the button under the pointer would be gone (ui.js).
    redrawWhenFree('tasks', () => {
      if (!visible) return;
      renderList();
      renderDetail();
    });
  }

  // ------------------------------------------------------------------ keys

  function handleKey(event) {
    if (typingIn(el)) return false;
    const name = keyName(event);
    if (!name) return false;
    const rows = visibleRows().map(keyRow);
    const action = keyAction(name, rows, selected && rows.some((r) => r.id === selected) ? selected : null, { composing });
    switch (action.type) {
      case 'select':
        event.preventDefault();
        select(action.id, { scroll: true });
        return true;
      case 'open': {
        event.preventDefault();
        const item = agents.item(action.id);
        if (item) openItem(item);
        return true;
      }
      case 'approve': {
        event.preventDefault();
        const item = agents.item(action.id);
        if (item) agents.approve(item, action.requestId, action.decision);
        return true;
      }
      case 'reply':
        event.preventDefault();
        replyArea.focus();
        return true;
      case 'compose':
        event.preventDefault();
        openComposer();
        return true;
      case 'closeCompose':
        event.preventDefault();
        closeComposer();
        return true;
      case 'deselect':
        event.preventDefault();
        select(null);
        return true;
      default:
        return false;
    }
  }

  agents.on((what) => {
    if (!visible) return;
    if (what.compose && !agents.composeBusy && composing) detailKey = '';
    render();
  });
  setInterval(() => render(), 30_000);

  return {
    el,
    shown(options = {}) {
      visible = true;
      listKey = '';
      detailKey = '';
      if (options.item) {
        if (filter !== 'all' && !agents.store.sections(filter).some((s) => s.items.some((i) => i.id === options.item))) filter = 'all';
        select(options.item, { scroll: true });
      } else if (options.compose) {
        openComposer();
      } else {
        if (!selected && !composing) {
          const first = visibleRows().find(needsYou) || null;
          if (first) {
            select(first.id);
            return;
          }
        }
        if (selected) agents.watch(selected);
        render();
      }
    },
    hidden() {
      visible = false;
      agents.watch(null);
    },
    handleKey,
  };
}
