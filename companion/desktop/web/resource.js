// One thing the window reads from the bridge now and then (the summary, the agenda, the devices, the ChatGPT login):
// the last value, the last error, one request at a time, a refresh every `every` ms while started, and listeners.
//
// The page lives as long as the app: it loads at launch (with --login too, before any window shows) and stays when the
// window is closed. A summary read makes the bridge look at Google Calendar and the journal, so a Resource given a
// `presence` reads only while somebody can see the window: asked while it is hidden, it remembers to, and reads once
// when the window is back (also when its last value is older than `every`). DOM-free (tests/resource.test.mjs).

/**
 * Whether the window is on screen: the page is visible (WebKit says hidden when the window is closed, minimised, in a
 * hidden app or covered) and the shell doesn't say otherwise (`shell()` → false). Listeners hear each change.
 */
export class Presence {
  constructor({ doc = globalThis.document, shell = () => true } = {}) {
    this.doc = doc;
    this.shell = shell;
    this.listeners = new Set();
    this.watched = this.compute();
    doc?.addEventListener?.('visibilitychange', () => this.update());
  }

  compute() {
    return (!this.doc || this.doc.visibilityState !== 'hidden') && this.shell() !== false;
  }

  /** Looks again (the shell pushed the window's state); tells the listeners when it changed. */
  update() {
    const watched = this.compute();
    if (watched === this.watched) return;
    this.watched = watched;
    for (const listener of this.listeners) listener(watched);
  }

  on(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}

export class Resource {
  constructor(fetcher, { every = 0, presence = null } = {}) {
    this.fetcher = fetcher;
    this.every = every;
    this.presence = presence;
    this.value = null;
    this.error = null;
    this.loading = null;
    this.loadedAt = 0;
    this.timer = 0;
    this.running = false;
    /** A read was asked for while nobody could see the window. */
    this.stale = false;
    this.listeners = new Set();
    presence?.on((watched) => this.watchedChanged(watched));
  }

  /** Nobody can see the window: reads wait. */
  get asleep() {
    return Boolean(this.presence) && !this.presence.watched;
  }

  on(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit() {
    for (const listener of this.listeners) listener(this);
  }

  /** Reads it again (a read already on its way is shared); while asleep, once the window is back. */
  refresh() {
    if (this.loading) return this.loading;
    if (this.asleep) {
      this.stale = true;
      return Promise.resolve(this.value);
    }
    this.stale = false;
    this.loading = (async () => {
      try {
        this.value = await this.fetcher();
        this.error = null;
        this.loadedAt = Date.now();
      } catch (error) {
        this.error = error;
      } finally {
        this.loading = null;
      }
      this.emit();
      return this.value;
    })();
    this.emit();
    return this.loading;
  }

  /** Reads it unless a read younger than `maxAge` ms is there. */
  fresh(maxAge = 15_000) {
    if (this.value != null && Date.now() - this.loadedAt < maxAge) return Promise.resolve(this.value);
    return this.refresh();
  }

  /** Reads it every `every` ms from now on (only while the window is seen, when there is a presence). */
  start(every = this.every) {
    this.every = every;
    this.running = true;
    this.arm();
  }

  stop() {
    this.running = false;
    this.arm();
  }

  arm() {
    clearInterval(this.timer);
    this.timer = 0;
    if (this.running && this.every > 0 && !this.asleep) this.timer = setInterval(() => this.refresh(), this.every);
  }

  watchedChanged(watched) {
    this.arm();
    if (!watched) return;
    const old = this.running && this.every > 0 && Date.now() - this.loadedAt >= this.every;
    if (this.stale || old) this.refresh();
  }
}
