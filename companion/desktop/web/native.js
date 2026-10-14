// The native shell (Sources/MainWindow.swift + MainWindowBridge.swift): messages to it, and the state it pushes in.
// In a plain browser (the dev harness) there is no shell: postNative answers false and the state stays empty, except
// what a test pushes through window.SamRabbitApp.native(…).

export const nativeHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.samrabbit;
export const nativeInfo = window.SAMRABBIT_NATIVE || null;
export const params = new URLSearchParams(location.search);

export function postNative(message) {
  if (!nativeHandler) return false;
  try {
    nativeHandler.postMessage(message);
    return true;
  } catch {
    return false;
  }
}

const root = document.documentElement;
if (nativeHandler || nativeInfo || params.has('chrome')) root.classList.add('in-app');
if (params.has('chrome')) root.classList.add('fake-chrome');
if (nativeInfo && nativeInfo.trafficLights) {
  const { right, centerY } = nativeInfo.trafficLights;
  if (Number.isFinite(right)) root.style.setProperty('--traffic-right', `${Math.round(right)}px`);
  if (Number.isFinite(centerY)) root.style.setProperty('--titlebar-h', `${Math.max(32, Math.round(centerY * 2))}px`);
}

/**
 * What the shell said last: `voice` (MacVoice: state, heard, caption, level, micMuted, wake…), `dock` ({enabled,
 * turnedOn, canCustomize}), `shortcuts` ([{id, label, keys, problem}]), `app` ({version, bridge}) and `window`
 * ({visible}: on screen, not minimised, closed or hidden). Each push replaces the keys it carries.
 */
const state = { voice: null, dock: null, shortcuts: [], app: null, window: null };
const listeners = new Set();

export function nativeState() {
  return state;
}

/** Whether the shell answers (voice, the dock switch, the native windows). */
export function hasShell() {
  return Boolean(nativeHandler) || state.voice !== null;
}

export function onNative(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** window.SamRabbitApp.native(patch): the shell (or a dev fixture) pushes state. */
export function receiveNative(patch) {
  if (!patch || typeof patch !== 'object') return;
  const changed = [];
  for (const key of ['voice', 'dock', 'shortcuts', 'app', 'window']) {
    if (key in patch) {
      state[key] = patch[key];
      changed.push(key);
    }
  }
  if (!changed.length) return;
  for (const listener of listeners) {
    try {
      listener(state, changed);
    } catch {
      // one view's failure must not stop the others
    }
  }
}
