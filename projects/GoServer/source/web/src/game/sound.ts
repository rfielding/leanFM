// The Lab's sounds. One audio context for the page, unlocked by the first gesture.
let audio: AudioContext | null = null;
export const soundPrefs = {on: true};
function unlock() { try { if (!audio) { const A = window.AudioContext || window.webkitAudioContext; if (A) audio = new A(); } if (audio && audio.state === 'suspended') void audio.resume(); } catch { /* no audio */ } }
document.addEventListener('pointerdown', unlock); document.addEventListener('keydown', unlock);

export function beep(freq: number, ms: number, at = 0) {
  if (!soundPrefs.on || !audio) return;
  try { const t = audio.currentTime + at, o = audio.createOscillator(), g = audio.createGain(); o.type = 'sine'; o.frequency.value = freq; g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.25, t + 0.01); g.gain.exponentialRampToValueAtTime(0.0001, t + ms / 1000); o.connect(g); g.connect(audio.destination); o.start(t); o.stop(t + ms / 1000 + 0.02); } catch { /* ignore */ }
}
function clack(freq: number, vol: number) {
  if (!soundPrefs.on || !audio) return;
  try { const t = audio.currentTime, len = Math.floor(audio.sampleRate * 0.05), buf = audio.createBuffer(1, len, audio.sampleRate), d = buf.getChannelData(0); for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 4);
    const src = audio.createBufferSource(), f = audio.createBiquadFilter(), g = audio.createGain(); src.buffer = buf; f.type = 'bandpass'; f.frequency.value = freq; f.Q.value = 3; g.gain.value = vol; src.connect(f); f.connect(g); g.connect(audio.destination); src.start(t); } catch { /* ignore */ }
}
export function moveSound(ch: any) { if (!ch || !ch.info) return; if (ch.move >= 0) { clack(2400, .9); if (ch.info.captured) setTimeout(() => { clack(900, 1); clack(600, .8); }, 90); } }
