// The bridge's desktop APIs: conversation sync (CONTRACTS-WAVE3 hop 3), the agent inbox (WAVE6 §A) and the
// dashboard, calendar, journal and devices twins of the mobile routes (WAVE7 §A). Same origin; the desktop token
// travels as the sr_desktop cookie that the native app sets before loading this page.

export class ApiError extends Error {
  constructor(status, code, message, detail = '') {
    super(message);
    this.status = status;
    this.code = code;
    this.detail = detail;
  }

  /** A bridge without the sync module answers its own bearer-token 401 for /v1/sync/*. */
  get syncMissing() {
    return this.status === 404 || (this.status === 401 && /bridge token/i.test(this.detail));
  }
}

async function getJSON(path, { signal } = {}) {
  return requestJSON('GET', path, undefined, { signal });
}

async function requestJSON(method, path, body, { signal } = {}) {
  let response;
  const headers = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  try {
    response = await fetch(path, {
      method,
      credentials: 'same-origin',
      cache: 'no-store',
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal,
    });
  } catch (error) {
    if (error && error.name === 'AbortError') throw error;
    throw new ApiError(0, 'unreachable', 'The SamRabbit bridge is not answering.');
  }
  if (!response.ok) {
    let code = '';
    let detail = '';
    try {
      const body = await response.json();
      code = (body && body.error && body.error.code) || '';
      detail = (body && body.error && body.error.message) || '';
    } catch {
      // not JSON
    }
    throw new ApiError(response.status, code, `HTTP ${response.status}`, String(detail).slice(0, 200));
  }
  try {
    return await response.json();
  } catch {
    throw new ApiError(response.status, 'bad_json', 'The bridge sent something unreadable.');
  }
}

function query(params) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== '') search.set(key, String(value));
  }
  const text = search.toString();
  return text ? `?${text}` : '';
}

/** Events per page (the bridge's maximum). */
export const EVENTS_PAGE = 500;

/**
 * Whether an events page says more follow: the sync API's `more` (or `hasMore`). Without either
 * flag, a non-empty page whose cursor advanced means "ask again".
 */
export function pageHasMore(body, after) {
  const events = body && Array.isArray(body.events) ? body.events : [];
  const cursor = body && body.cursor != null ? body.cursor : null;
  if (cursor == null || String(cursor) === String(after ?? '')) return false;
  const flag = body.more ?? body.hasMore;
  if (typeof flag === 'boolean') return flag;
  return events.length > 0;
}

/** "sha256:<hex>" -> "<hex>" (the path form of a blob id). */
export function blobPath(blobId) {
  const id = String(blobId ?? '');
  return id.startsWith('sha256:') ? id.slice(7) : id;
}

export const api = {
  conversations({ limit = 100, before, q, signal } = {}) {
    return getJSON(`/v1/sync/conversations${query({ limit, before, q })}`, { signal });
  },
  events(conversationId, after, { limit = EVENTS_PAGE, signal } = {}) {
    return getJSON(`/v1/sync/conversations/${encodeURIComponent(conversationId)}/events${query({ after, limit })}`,
      { signal });
  },
  blobUrl(blobId) {
    return `/v1/sync/blobs/${encodeURIComponent(blobPath(blobId))}`;
  },
  documentUrl(artifactId) {
    return `/v1/ui/artifacts/${encodeURIComponent(artifactId)}/document`;
  },
  async documentText(artifactId) {
    const response = await fetch(this.documentUrl(artifactId), { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) throw new ApiError(response.status, '', `HTTP ${response.status}`);
    return response.text();
  },
};

/**
 * `/v1/desktop/inbox/items/<id>[/<action>]`. Ids look like `t3:<id>`; everything outside a safe set is escaped (a `/`
 * in an id must not become a path separator), the colon stays (as the dock sends it).
 */
export function itemPath(id, action) {
  const escaped = encodeURIComponent(String(id ?? '')).replace(/%3A/gi, ':');
  return `/v1/desktop/inbox/items/${escaped}${action ? `/${action}` : ''}`;
}

/** Before the bridge has the desktop twins, the mobile device list answers the desktop token too. */
function orMobile(call, fallback) {
  return call().catch((error) => {
    if (error instanceof ApiError && error.status === 404 && error.code !== 'device_not_found') return fallback();
    throw error;
  });
}

export const desktop = {
  inbox({ after, wait, signal } = {}) {
    return getJSON(`/v1/desktop/inbox${query({ after, wait })}`, { signal });
  },
  item(id, { signal } = {}) {
    return getJSON(itemPath(id), { signal });
  },
  /** approve {requestId, decision} · answer {requestId, answers} · reply {text} · stop · seen · open */
  act(id, action, body = {}) {
    return requestJSON('POST', itemPath(id, action), body);
  },
  targets() {
    return getJSON('/v1/desktop/inbox/targets');
  },
  newTask(body) {
    return requestJSON('POST', '/v1/desktop/inbox/new', body);
  },
  summary({ signal } = {}) {
    return getJSON('/v1/desktop/summary', { signal });
  },
  agenda(days = 7, { signal } = {}) {
    return getJSON(`/v1/desktop/calendar/agenda${query({ days })}`, { signal });
  },
  block(minutes, title) {
    return requestJSON('POST', '/v1/desktop/calendar/block', title ? { minutes, title } : { minutes });
  },
  /** The note goes into today's journal word for word: only ever from an explicit "Add" by Samin. */
  journal(text) {
    return requestJSON('POST', '/v1/desktop/journal', { text });
  },
  devices() {
    return orMobile(() => getJSON('/v1/desktop/devices'), () => getJSON('/v1/mobile/devices'));
  },
  unpair(deviceId) {
    const id = encodeURIComponent(deviceId);
    return orMobile(() => requestJSON('DELETE', `/v1/desktop/devices/${id}`),
      () => requestJSON('DELETE', `/v1/mobile/devices/${id}`));
  },
  chatgpt() {
    return getJSON('/v1/assistant/chatgpt/status');
  },
  /** The morning brief (CONTRACTS-WAVE8 §A3): `after` + `wait` long-poll for a newer revision. */
  briefing({ after, wait, signal } = {}) {
    return getJSON(`/v1/desktop/briefing${query({ after, wait })}`, { signal });
  },
  /** Builds it again (at most once in 5 minutes on the bridge). */
  briefingRefresh() {
    return requestJSON('POST', '/v1/desktop/briefing/refresh', {});
  },
  /** {action: draft_reply|make_task|block_time|remind|done|dismiss|open, at?}: a draft is only ever a draft. */
  briefingAct(id, body) {
    return requestJSON('POST', `/v1/desktop/briefing/items/${encodeURIComponent(String(id ?? ''))}/act`, body);
  },
};

const INBOX_BACKOFF_MS = [1000, 2000, 4000, 8000, 15000, 30000];

/**
 * The inbox long poll: `GET /v1/desktop/inbox?after=<revision>&wait=25`, again as soon as it answers; backs off on
 * errors (30 s at least when the bridge has no inbox or refuses the token). `fetchInbox` and `sleep` are injectable
 * for the tests.
 */
export class InboxPoller {
  constructor({ onInbox, onError, fetchInbox = (options) => desktop.inbox(options), sleep, wait = 25 }) {
    this.onInbox = onInbox;
    this.onError = onError;
    this.fetchInbox = fetchInbox;
    this.sleep = sleep || ((ms) => new Promise((resolve) => { this.timer = setTimeout(resolve, ms); }));
    this.wait = wait;
    this.revision = null;
    this.attempt = 0;
    this.running = false;
    this.controller = null;
    this.generation = 0;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.loop(++this.generation);
  }

  stop() {
    this.running = false;
    this.generation += 1;
    clearTimeout(this.timer);
    if (this.controller) this.controller.abort();
  }

  /** Ask now (after an action), without waiting for the long poll to come back. */
  poke() {
    if (!this.running) return;
    this.stop();
    this.revision = null;
    this.attempt = 0;
    this.start();
  }

  /** The delay before the next try after a failure (ms). */
  static backoff(attempt, status) {
    const delay = INBOX_BACKOFF_MS[Math.min(attempt, INBOX_BACKOFF_MS.length - 1)];
    return [401, 403, 404].includes(status) ? Math.max(delay, 30000) : delay;
  }

  async loop(generation) {
    while (this.running && generation === this.generation) {
      const asked = Date.now();
      const controller = typeof AbortController === 'function' ? new AbortController() : null;
      this.controller = controller;
      try {
        const first = this.revision == null;
        const body = await this.fetchInbox({
          after: first ? undefined : this.revision, wait: first ? 0 : this.wait, signal: controller?.signal,
        });
        if (generation !== this.generation) return;
        this.attempt = 0;
        const unchanged = body && body.revision === this.revision;
        this.revision = body && Number.isFinite(body.revision) ? body.revision : null;
        this.onInbox?.(body);
        // A bridge that answers a long poll at once without news must not be asked in a tight loop.
        if (unchanged && Date.now() - asked < 500) await this.sleep(1000);
      } catch (error) {
        if (generation !== this.generation || (error && error.name === 'AbortError')) return;
        this.revision = null;
        this.onError?.(error);
        const delay = InboxPoller.backoff(this.attempt, error && error.status);
        this.attempt += 1;
        await this.sleep(delay);
      }
    }
  }
}

/** Normalizes one SSE payload: either the event itself or {event, cursor}. */
export function unwrapStreamPayload(data) {
  if (data && typeof data === 'object' && data.event && typeof data.event === 'object' && !data.type) {
    return { event: data.event, cursor: data.cursor ?? null };
  }
  return { event: data, cursor: data && typeof data === 'object' ? (data.cursor ?? null) : null };
}

const BACKOFF_MS = [1000, 2000, 4000, 8000, 15000];

/**
 * GET /v1/sync/stream (SSE, `event: sync`) with our own reconnect: resumes with ?after=<cursor>
 * (the last SSE id, or the cursor inside the payload) and reports state changes so the UI can
 * re-fetch anything it might have missed while the stream was down.
 */
export class SyncStream {
  constructor({ onEvent, onState, onResume }) {
    this.onEvent = onEvent;
    this.onState = onState;
    this.onResume = onResume;
    this.cursor = null;
    this.source = null;
    this.attempt = 0;
    this.timer = 0;
    this.state = 'connecting';
    this.hadError = false;
    this.stopped = false;
  }

  start() {
    this.stopped = false;
    this.open();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    if (this.source) this.source.close();
    this.source = null;
  }

  setState(state) {
    if (state === this.state) return;
    this.state = state;
    this.onState?.(state);
  }

  open() {
    clearTimeout(this.timer);
    if (this.source) this.source.close();
    const url = `/v1/sync/stream${this.cursor != null ? `?after=${encodeURIComponent(this.cursor)}` : ''}`;
    let source;
    try {
      source = new EventSource(url, { withCredentials: true });
    } catch {
      this.retry();
      return;
    }
    this.source = source;
    const handle = (message) => this.message(message);
    source.addEventListener('sync', handle);
    source.addEventListener('message', handle);
    source.addEventListener('open', () => {
      this.attempt = 0;
      this.hadError = false;
      this.setState('live');
      // Every (re)connect: fetch what may have happened while the stream was not open.
      this.onResume?.();
    });
    source.addEventListener('error', () => {
      if (source !== this.source) return;
      source.close();
      this.source = null;
      this.hadError = true;
      this.retry();
    });
  }

  retry() {
    if (this.stopped) return;
    this.setState('reconnecting');
    const delay = BACKOFF_MS[Math.min(this.attempt, BACKOFF_MS.length - 1)];
    this.attempt += 1;
    this.timer = setTimeout(() => this.open(), delay);
  }

  message(message) {
    let data;
    try {
      data = JSON.parse(message.data);
    } catch {
      return;
    }
    const { event, cursor } = unwrapStreamPayload(data);
    if (message.lastEventId) this.cursor = message.lastEventId;
    else if (cursor != null) this.cursor = cursor;
    if (event && typeof event === 'object') this.onEvent?.(event);
  }
}
