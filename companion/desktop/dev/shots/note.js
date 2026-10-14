// shoot.sh eval: a voice note recording, as the shell pushes it (Sources/VoiceNote.swift): Home's Voice note button
// says a press sends it, with the time.
SamRabbitApp.native({
  note: { state: 'recording', held: false, line: 'Recording…', detail: '', shortcut: '⌃⌥N', waiting: 0, startedAt: Date.now() - 7400 },
});
