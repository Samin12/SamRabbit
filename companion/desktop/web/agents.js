// The live agent inbox of the window: the long poll, the open items' last messages, what a new task can be sent to,
// drafts, and the actions (approve / answer / reply / stop / seen / open / new) with their optimistic results and a
// short note when the bridge says no. Home and Tasks draw from it. No DOM; the API is injected (tests/agents.test.mjs
// runs it against a fake).

import { InboxPoller } from './api.js';
import {
  InboxStore, actionInfo, agentLabel, buildAnswers, failureNote, normalizeDetail, optimisticItem, resolveChoice,
} from './inbox.js';

export class AgentInbox {
  constructor(api, { now = () => Date.now(), poll = true } = {}) {
    this.api = api;
    this.now = now;
    this.store = new InboxStore();
    /** 'connecting' | 'online' | 'offline' */
    this.connection = 'connecting';
    this.offlineStatus = null;
    this.details = new Map();
    this.loadingDetail = new Set();
    this.busy = new Map(); // id -> action
    this.notes = new Map(); // id -> {text, isError, offersOpen}
    this.replyDrafts = new Map();
    this.selections = new Map(); // id -> {questionId: [options]}
    this.customAnswers = new Map(); // id -> {questionId: text}
    this.targets = null;
    this.targetsAt = 0;
    this.choice = {};
    this.composeBusy = false;
    this.composeNote = null;
    this.watched = null;
    this.listeners = new Set();
    this.poller = poll ? new InboxPoller({
      fetchInbox: (options) => api.inbox(options),
      onInbox: (body) => this.receive(body),
      onError: (error) => this.failed(error),
    }) : null;
  }

  on(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit(what = {}) {
    for (const listener of this.listeners) listener(what);
  }

  start() {
    this.poller?.start();
  }

  stop() {
    this.poller?.stop();
  }

  get items() {
    return this.store.items;
  }

  counts() {
    return this.store.counts();
  }

  item(id) {
    return this.store.item(id);
  }

  receive(body) {
    const wasOnline = this.connection === 'online';
    this.connection = 'online';
    this.offlineStatus = null;
    const previous = this.watched ? this.store.item(this.watched) : null;
    const { changed, countsChanged } = this.store.apply(body, this.now());
    // Keep the open item's messages fresh when it changed.
    if (this.watched) {
      const fresh = this.store.item(this.watched);
      if (fresh && JSON.stringify(fresh) !== JSON.stringify(previous)) this.loadDetail(this.watched);
    }
    if (changed || !wasOnline) this.emit({ inbox: true, countsChanged });
  }

  failed(error) {
    const status = error && typeof error.status === 'number' ? error.status : 0;
    if (this.connection === 'offline' && this.offlineStatus === status) return;
    this.connection = 'offline';
    this.offlineStatus = status;
    this.emit({ inbox: true, connection: true });
  }

  /** Every 30 s: forget overlays and placeholders that outlived their time. */
  tick() {
    if (this.store.tick(this.now())) this.emit({ inbox: true });
  }

  // ------------------------------------------------------------------ details and targets

  /** The item on screen: its last messages are loaded now and kept fresh. */
  watch(id) {
    if (this.watched === id) return;
    this.watched = id;
    if (id) this.loadDetail(id);
  }

  async loadDetail(id) {
    if (!id || id.startsWith('pending:') || this.loadingDetail.has(id)) return;
    this.loadingDetail.add(id);
    this.emit({ detail: id });
    try {
      const detail = normalizeDetail(await this.api.item(id));
      this.details.set(id, detail);
    } catch {
      // the row still shows the summary
    } finally {
      this.loadingDetail.delete(id);
      this.emit({ detail: id });
    }
  }

  async loadTargets({ force = false } = {}) {
    if (!force && this.targets && this.now() - this.targetsAt < 60_000) return this.targets;
    this.targetsAt = this.now();
    try {
      this.targets = await this.api.targets();
      this.targetsError = null;
      this.choice = resolveChoice(this.targets, this.choice);
    } catch (error) {
      if (!this.targets) this.targetsError = error;
    }
    this.emit({ targets: true });
    return this.targets;
  }

  pick(change) {
    this.choice = resolveChoice(this.targets, { ...this.choice, ...change });
    this.emit({ targets: true });
  }

  // ------------------------------------------------------------------ actions

  /**
   * Runs one action: the optimistic item shows at once; on success it stays until the inbox catches up, on failure
   * it is rolled back and the item says why. Returns the bridge's answer, or null.
   */
  async perform(item, kind, body = {}, { optimistic = optimisticItem(item, kind, body), rollback = null } = {}) {
    if (!item || this.busy.has(item.id)) return null;
    this.busy.set(item.id, kind);
    this.notes.delete(item.id);
    if (optimistic) this.store.overlay(optimistic, this.now());
    this.emit({ inbox: true, item: item.id });
    try {
      const reply = await this.api.act(item.id, kind, body);
      if (optimistic) this.store.settle(item.id);
      const info = actionInfo(kind, reply);
      if (info) this.notes.set(item.id, { text: info, isError: false });
      this.poller?.poke();
      return reply || {};
    } catch (error) {
      this.store.rollback(item.id);
      rollback?.();
      this.notes.set(item.id, failureNote(error));
      return null;
    } finally {
      this.busy.delete(item.id);
      this.emit({ inbox: true, item: item.id });
    }
  }

  approve(item, requestId, decision) {
    return this.perform(item, 'approve', { requestId, decision });
  }

  /** Answers a question card from what was picked and typed; says so when something is missing. */
  answer(item, request) {
    const answers = buildAnswers(request, this.selections.get(item.id) || {}, this.customAnswers.get(item.id) || {});
    if (!answers) {
      this.notes.set(item.id, { text: 'Answer every question first.', isError: true });
      this.emit({ item: item.id });
      return Promise.resolve(null);
    }
    return this.perform(item, 'answer', { requestId: request.requestId, answers });
  }

  /** One click on an option of a single-choice question answers it. */
  answerWith(item, request, option) {
    const [question] = request.questions;
    if (!question) return Promise.resolve(null);
    return this.perform(item, 'answer', { requestId: request.requestId, answers: { [question.id]: option } });
  }

  toggleOption(item, question, option) {
    const picked = { ...(this.selections.get(item.id) || {}) };
    let chosen = picked[question.id] || [];
    if (chosen.includes(option)) chosen = chosen.filter((o) => o !== option);
    else chosen = question.multiSelect ? chosen.concat(option) : [option];
    picked[question.id] = chosen;
    this.selections.set(item.id, picked);
    if (!question.multiSelect) this.setCustom(item, question, '');
    this.emit({ item: item.id });
  }

  setCustom(item, question, value) {
    this.customAnswers.set(item.id, { ...(this.customAnswers.get(item.id) || {}), [question.id]: value });
  }

  async reply(item) {
    const text = String(this.replyDrafts.get(item.id) || '').trim();
    if (!text || this.busy.has(item.id)) return null;
    const before = this.details.get(item.id);
    if (before) {
      this.details.set(item.id, { ...before, messages: before.messages.concat({ role: 'user', text, at: this.now() }) });
    }
    this.replyDrafts.set(item.id, '');
    return this.perform(item, 'reply', { text }, {
      rollback: () => {
        if (before) this.details.set(item.id, before);
        if (!this.replyDrafts.get(item.id)) this.replyDrafts.set(item.id, text);
      },
    });
  }

  stopItem(item) {
    return this.perform(item, 'stop');
  }

  markSeen(item) {
    return this.perform(item, 'seen');
  }

  open(item) {
    return this.perform(item, 'open', {}, { optimistic: null });
  }

  /**
   * `POST /v1/desktop/inbox/new`: a T3 thread with the chosen project, agent and model. A row shows under Working at
   * once. Returns the new item's id, or null (then `composeNote` says why and the text is kept).
   */
  async newTask(text, change = {}) {
    const prompt = String(text || '').trim();
    if (!prompt || this.composeBusy) return null;
    const picked = resolveChoice(this.targets, { ...this.choice, ...change });
    this.composeBusy = true;
    this.composeNote = null;
    const project = this.targets && Array.isArray(this.targets.projects)
      ? (this.targets.projects.find((p) => p.id === picked.projectId) || {}).title : null;
    const placeholder = this.store.addPlaceholder({ text: prompt, project, agent: picked.agent }, this.now());
    this.emit({ inbox: true, compose: true });
    const body = { text: prompt };
    if (picked.projectId) body.projectId = picked.projectId;
    if (picked.agent) body.agent = picked.agent;
    if (picked.model) body.model = picked.model;
    try {
      const reply = await this.api.newTask(body);
      const itemId = reply && typeof reply.itemId === 'string' ? reply.itemId : null;
      this.store.resolvePlaceholder(placeholder, itemId);
      this.poller?.poke();
      return itemId || placeholder;
    } catch (error) {
      this.store.dropPlaceholder(placeholder);
      this.composeNote = failureNote(error);
      return null;
    } finally {
      this.composeBusy = false;
      this.emit({ inbox: true, compose: true });
    }
  }

  /** "Claude · Opus 5.5" for the compose button. */
  choiceLabel() {
    const agents = this.targets && Array.isArray(this.targets.agents) ? this.targets.agents : [];
    const agent = agents.find((a) => a.id === this.choice.agent);
    const model = agent && (agent.models || []).find((m) => m.id === this.choice.model);
    return [agent ? agent.label : agentLabel({ agent: this.choice.agent, source: 't3' }), model && model.label]
      .filter(Boolean).join(' · ');
  }
}
