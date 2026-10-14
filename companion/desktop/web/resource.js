// One thing the window reads from the bridge now and then (the summary, the agenda, the devices, the ChatGPT login):
// the last value, the last error, one request at a time, a refresh every `every` ms while started, and listeners.

export class Resource {
  constructor(fetcher, { every = 0 } = {}) {
    this.fetcher = fetcher;
    this.every = every;
    this.value = null;
    this.error = null;
    this.loading = null;
    this.loadedAt = 0;
    this.timer = 0;
    this.listeners = new Set();
  }

  on(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit() {
    for (const listener of this.listeners) listener(this);
  }

  /** Reads it again (a read already on its way is shared). */
  refresh() {
    if (this.loading) return this.loading;
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

  start(every = this.every) {
    this.stop();
    this.every = every;
    if (every > 0) this.timer = setInterval(() => this.refresh(), every);
  }

  stop() {
    clearInterval(this.timer);
    this.timer = 0;
  }
}
