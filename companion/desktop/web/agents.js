// The live agent inbox of the window: the long poll, the open items' last messages, what a new task can be sent to,
// drafts, and the actions (approve / answer / reply / stop / seen / open / new / dismiss and its undo) with their
// optimistic results and a short note when the bridge says no. Home and Tasks draw from it. No DOM; the API is
// injected (tests/agents.test.mjs runs it against a fake).

import { InboxPoller } from './api.js';
import { noteAction } from './inbox.js';
import {
  InboxStore, UNDO_MS, actionInfo, agentLabel, buildAnswers, canDismiss, dismissProblem, failureNote, normalizeDetail,
  optimisticItem, resolveChoice,
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
    // id -> the last dismiss / undismiss call for it: a promise of whether the bridge keeps the item dismissed after
    // it. Each call waits for the one before (dismissCall), so the bridge gets them in the order they were made.
    this.dismissCalls = new Map();
    this.lastDismissed = null; // {item, at}: what ⌘Z brings back for a few seconds
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

  /** A voice note's button (inbox.js noteAction): the bridge does its suggestion, or tries a failed note again. */
  actOnNote(item) {
    const act = noteAction(item);
    if (!act) return Promise.resolve(null);
    return this.perform(item, 'act', act.action ? { action: act.action } : {});
  }

  open(item) {
    return this.perform(item, 'open', {}, { optimistic: null });
  }

  /**
   * Dismiss: the row goes at once (the counts with it), then `POST …/dismiss`; the bridge keeps it out of the list
   * until it changes. Resolves to {ok, problem}: a refusal puts the row back and `problem` says why. Nothing reaches
   * T3, Claude Code or Codex.
   */
  dismiss(item) {
    if (!canDismiss(item) || this.store.isDismissed(item.id)) return Promise.resolve({ ok: false, problem: null });
    this.store.dismiss(item, this.now());
    this.notes.delete(item.id);
    this.lastDismissed = { item, at: this.now() };
    this.emit({ inbox: true, item: item.id, dismissed: item.id });
    return this.dismissCall(item.id, async (_before, latest) => {
      try {
        const reply = await this.api.act(item.id, 'dismiss', {});
        // Undone (or dismissed again) meanwhile: the rows are the later call's.
        if (latest()) this.store.confirmDismiss(item.id, reply && Number.isFinite(reply.revision) ? reply.revision : undefined);
        this.poller?.poke();
        return { dismissed: true, result: { ok: true, problem: null } };
      } catch (error) {
        let shown = false;
        if (latest()) {
          shown = this.store.failDismiss(item.id);
          if (this.lastDismissed && this.lastDismissed.item.id === item.id) this.lastDismissed = null;
        }
        // Undone meanwhile: nothing to say.
        return { dismissed: false, result: { ok: false, problem: shown ? dismissProblem(error) : null } };
      } finally {
        this.emit({ inbox: true, item: item.id });
      }
    });
  }

  /**
   * The undo: the row is back at once (as it was), then `POST …/undismiss`, after the dismissal's own call if it is
   * still on its way. Resolves to {ok, problem}: a refusal hides it again and `problem` says why.
   */
  async undoDismiss(item) {
    if (!item) return { ok: false, problem: null };
    if (this.lastDismissed && this.lastDismissed.item.id === item.id) this.lastDismissed = null;
    this.store.undo(item, this.now());
    this.emit({ inbox: true, item: item.id, undone: item.id });
    return this.dismissCall(item.id, async (before, latest) => {
      if (before === false) {
        // The dismissal it undoes failed (or it is back already): nothing to undo, the inbox's own row stays.
        if (latest()) this.store.undoNotNeeded(item.id);
        this.emit({ inbox: true, item: item.id });
        return { dismissed: false, result: { ok: true, problem: null } };
      }
      try {
        const reply = await this.api.act(item.id, 'undismiss', {});
        if (latest()) this.store.confirmUndo(item.id, reply && Number.isFinite(reply.revision) ? reply.revision : undefined);
        this.poller?.poke();
        return { dismissed: false, result: { ok: true, problem: null } };
      } catch (error) {
        const mine = latest();
        if (mine) this.store.failUndo(item.id, this.now());
        return { dismissed: true, result: { ok: false, problem: mine ? dismissProblem(error, { undo: true }) : null } };
      } finally {
        this.emit({ inbox: true, item: item.id });
      }
    });
  }

  /**
   * Runs one dismiss / undismiss call for `id` after the one before it, so the bridge gets them in the order they
   * were made (dismiss, Undo, dismiss again ends dismissed). `run(before, latest)` gets whether the bridge kept the
   * item dismissed after that call (undefined: none) and `latest()`, true while no later call for `id` was made
   * (only the latest one changes the rows: an earlier one's answer is the later one's to settle). It resolves to
   * {dismissed, result}; this resolves to `result`.
   */
  dismissCall(id, run) {
    const before = this.dismissCalls.get(id);
    let tail = null;
    const latest = () => this.dismissCalls.get(id) === tail;
    const call = (async () => run(before ? await before : undefined, latest))();
    tail = call.then((outcome) => outcome.dismissed, () => false);
    this.dismissCalls.set(id, tail);
    tail.then(() => {
      if (this.dismissCalls.get(id) === tail) this.dismissCalls.delete(id);
    });
    return call.then((outcome) => outcome.result);
  }

  /** What ⌘Z would bring back (the last dismissal, for as long as its toast shows), or null. */
  undoable() {
    const last = this.lastDismissed;
    return last && this.now() - last.at < UNDO_MS ? last.item : null;
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
