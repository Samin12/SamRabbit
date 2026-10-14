// shoot.sh eval: what the Swift shell pushes once the page is ready (MainWindowBridge.swift), so a headless shot looks
// like the app: MacVoice idle with "Hey Rabbit" armed, the dock on, the shortcuts, the app's version, the window shown.
SamRabbitApp.native({
  app: { version: '1.5', bridge: '127.0.0.1:3780' },
  window: { visible: true },
  dock: { enabled: true, turnedOn: true, canCustomize: false },
  shortcuts: [
    { id: 'talk', label: 'Talk to SamRabbit', keys: '⌃⌥Space', problem: null },
    { id: 'compose', label: 'Open the Agent Dock on a new task', keys: '⌃⌥K', problem: null },
  ],
  voice: {
    state: 'idle', heard: '', caption: '', level: 0, micMuted: false, wakeArmed: true, wakeEnabled: true, wakeProblem: null,
    brain: 'realtime', conversationId: null, shortcut: '⌃⌥Space', shortcutProblem: null,
  },
});
