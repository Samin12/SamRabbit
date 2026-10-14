// shoot.sh eval: a Mac voice conversation as MacVoice publishes it (state, heard, caption streaming, level), pushed
// the way the shell does, so the window's live transcript can be shot without a microphone or a speaker.
(() => {
  const base = {
    micMuted: false, wakeArmed: false, wakeEnabled: true, wakeProblem: null, brain: 'realtime',
    conversationId: 'mac-20261014-1', shortcut: '⌃⌥Space', shortcutProblem: null,
  };
  const push = (voice) => SamRabbitApp.native({ voice: { ...base, ...voice } });
  const q1 = 'What’s on my calendar this afternoon?';
  const a1 = 'You have the 1:1 with Priya at 2 and the gym at 6:30. The design review moved to tomorrow morning.';
  const q2 = 'Block thirty minutes before the one-on-one to prep.';
  const a2 = 'Done — I blocked 1:30 to 2 as “Prep for Priya”. Anything else?';
  push({ state: 'starting', heard: '', caption: '', level: 0 });
  push({ state: 'listening', heard: '', caption: '', level: 0.3 });
  push({ state: 'thinking', heard: q1, heardId: 't1', caption: '', level: 0 });
  push({ state: 'speaking', heard: q1, heardId: 't1', caption: a1.slice(0, 40), level: 0.5 });
  push({ state: 'speaking', heard: q1, heardId: 't1', caption: a1, level: 0.6 });
  push({ state: 'listening', heard: q1, heardId: 't1', caption: a1, level: 0.2 });
  push({ state: 'thinking', heard: q2, heardId: 't2', caption: a1, level: 0 });
  push({ state: 'speaking', heard: q2, heardId: 't2', caption: a2.slice(0, 30), level: 0.55 });
  push({ state: 'speaking', heard: q2, heardId: 't2', caption: a2.slice(0, 52), level: 0.7 });
})();
