#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CabinetModel {
    Vintage,
    Modern,
    Open,
}

impl CabinetModel {
    pub fn parse(value: &str) -> Option<Self> {
        match value.to_ascii_lowercase().as_str() {
            "vintage" | "4x12" => Some(Self::Vintage),
            "modern" | "tight" => Some(Self::Modern),
            "open" | "1x12" | "open-back" => Some(Self::Open),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Vintage => "vintage",
            Self::Modern => "modern",
            Self::Open => "open",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct FxSettings {
    pub flanger_enabled: bool,
    pub flanger_rate_hz: f32,
    pub flanger_depth: f32,
    pub flanger_delay_ms: f32,
    pub flanger_feedback: f32,
    pub flanger_mix: f32,
    pub flanger_rate_step_per_tick: f32,
    pub flanger_depth_step_per_tick: f32,
    pub flanger_delay_step_per_tick: f32,
    pub flanger_feedback_step_per_tick: f32,
    pub flanger_mix_step_per_tick: f32,
    pub chorus_enabled: bool,
    pub chorus_rate_hz: f32,
    pub chorus_depth: f32,
    pub chorus_delay_ms: f32,
    pub chorus_mix: f32,
    pub chorus_rate_step_per_tick: f32,
    pub chorus_depth_step_per_tick: f32,
    pub chorus_delay_step_per_tick: f32,
    pub chorus_mix_step_per_tick: f32,
    pub reverb_enabled: bool,
    pub reverb_mix: f32,
    pub reverb_decay: f32,
    pub reverb_mix_step_per_tick: f32,
    pub reverb_decay_step_per_tick: f32,
    pub delay_enabled: bool,
    pub delay_time_secs: f32,
    pub delay_feedback: f32,
    pub delay_mix: f32,
    pub delay_time_step_per_tick: f32,
    pub delay_feedback_step_per_tick: f32,
    pub delay_mix_step_per_tick: f32,
    pub cabinet_enabled: bool,
    pub cabinet_model: CabinetModel,
    pub cabinet_mix: f32,
}

impl Default for FxSettings {
    fn default() -> Self {
        Self {
            flanger_enabled: false,
            flanger_rate_hz: 0.22,
            flanger_depth: 0.75,
            flanger_delay_ms: 2.8,
            flanger_feedback: 0.45,
            flanger_mix: 0.35,
            flanger_rate_step_per_tick: 0.0,
            flanger_depth_step_per_tick: 0.0,
            flanger_delay_step_per_tick: 0.0,
            flanger_feedback_step_per_tick: 0.0,
            flanger_mix_step_per_tick: 0.0,
            chorus_enabled: false,
            chorus_rate_hz: 0.7,
            chorus_depth: 0.55,
            chorus_delay_ms: 18.0,
            chorus_mix: 0.32,
            chorus_rate_step_per_tick: 0.0,
            chorus_depth_step_per_tick: 0.0,
            chorus_delay_step_per_tick: 0.0,
            chorus_mix_step_per_tick: 0.0,
            reverb_enabled: false,
            reverb_mix: 0.18,
            reverb_decay: 0.65,
            reverb_mix_step_per_tick: 0.0,
            reverb_decay_step_per_tick: 0.0,
            delay_enabled: false,
            delay_time_secs: 0.28,
            delay_feedback: 0.42,
            delay_mix: 0.22,
            delay_time_step_per_tick: 0.0,
            delay_feedback_step_per_tick: 0.0,
            delay_mix_step_per_tick: 0.0,
            cabinet_enabled: false,
            cabinet_model: CabinetModel::Vintage,
            cabinet_mix: 1.0,
        }
    }
}

/// A short, zero-allocation FIR cabinet stage intended for the live NAM input.
/// The bundled responses make scores portable; they are deliberately short to
/// keep the per-sample audio callback predictable.
pub struct CabinetProcessor {
    impulse: Vec<f32>,
    history: Vec<f32>,
    pos: usize,
    model: CabinetModel,
}

impl CabinetProcessor {
    pub fn new(sample_rate: f32) -> Self {
        let model = CabinetModel::Vintage;
        let impulse = cabinet_impulse(model, sample_rate);
        Self { history: vec![0.0; impulse.len()], impulse, pos: 0, model }
    }

    pub fn set_model(&mut self, model: CabinetModel, sample_rate: f32) {
        if self.model == model { return; }
        self.model = model;
        self.impulse = cabinet_impulse(model, sample_rate);
        self.history.resize(self.impulse.len(), 0.0);
        self.history.fill(0.0);
        self.pos = 0;
    }

    pub fn process(&mut self, input: f32, settings: FxSettings) -> f32 {
        if !settings.cabinet_enabled { return input; }
        self.history[self.pos] = input;
        let mut wet = 0.0;
        let mut read = self.pos;
        for coefficient in &self.impulse {
            wet += self.history[read] * coefficient;
            read = if read == 0 { self.history.len() - 1 } else { read - 1 };
        }
        self.pos = (self.pos + 1) % self.history.len();
        input * (1.0 - settings.cabinet_mix) + wet * settings.cabinet_mix
    }
}

fn cabinet_impulse(model: CabinetModel, sample_rate: f32) -> Vec<f32> {
    let (low_hz, high_hz, resonance, damping) = match model {
        CabinetModel::Vintage => (85.0, 5_200.0, 115.0, 32.0),
        CabinetModel::Modern => (105.0, 6_400.0, 145.0, 42.0),
        CabinetModel::Open => (70.0, 7_200.0, 92.0, 25.0),
    };
    let sr = sample_rate.max(8_000.0);
    let len = ((sr * 0.006).round() as usize).clamp(64, 384);
    let mut out = Vec::with_capacity(len);
    let mut previous_lp = 0.0;
    let lp_alpha = 1.0 - (-2.0 * std::f32::consts::PI * high_hz / sr).exp();
    let hp_decay = (-2.0 * std::f32::consts::PI * low_hz / sr).exp();
    let mut hp_state = 0.0;
    for n in 0..len {
        let t = n as f32 / sr;
        let excitation = if n == 0 { 1.0 } else { 0.0 }
            + (2.0 * std::f32::consts::PI * resonance * t).sin() * (-damping * t).exp() * 0.22;
        previous_lp += lp_alpha * (excitation - previous_lp);
        let high_passed = previous_lp - hp_state;
        hp_state = previous_lp + hp_decay * high_passed;
        out.push(high_passed * (-70.0 * t).exp());
    }
    let peak = out.iter().fold(0.0f32, |p, value| p.max(value.abs())).max(1e-6);
    for value in &mut out { *value /= peak; }
    out
}

impl FxSettings {
    pub fn active(self) -> bool {
        self.flanger_enabled || self.chorus_enabled || self.reverb_enabled || self.delay_enabled
    }

    pub fn advance_tick(&mut self) {
        if self.flanger_enabled {
            self.flanger_rate_hz =
                (self.flanger_rate_hz + self.flanger_rate_step_per_tick).clamp(0.01, 8.0);
            self.flanger_depth =
                (self.flanger_depth + self.flanger_depth_step_per_tick).clamp(0.0, 1.0);
            self.flanger_delay_ms =
                (self.flanger_delay_ms + self.flanger_delay_step_per_tick).clamp(0.1, 10.0);
            self.flanger_feedback =
                (self.flanger_feedback + self.flanger_feedback_step_per_tick).clamp(-0.95, 0.95);
            self.flanger_mix = (self.flanger_mix + self.flanger_mix_step_per_tick).clamp(0.0, 1.0);
        }
        if self.chorus_enabled {
            self.chorus_rate_hz =
                (self.chorus_rate_hz + self.chorus_rate_step_per_tick).clamp(0.01, 8.0);
            self.chorus_depth =
                (self.chorus_depth + self.chorus_depth_step_per_tick).clamp(0.0, 1.0);
            self.chorus_delay_ms =
                (self.chorus_delay_ms + self.chorus_delay_step_per_tick).clamp(5.0, 35.0);
            self.chorus_mix = (self.chorus_mix + self.chorus_mix_step_per_tick).clamp(0.0, 1.0);
        }
        if self.reverb_enabled {
            self.reverb_mix = (self.reverb_mix + self.reverb_mix_step_per_tick).clamp(0.0, 1.0);
            self.reverb_decay =
                (self.reverb_decay + self.reverb_decay_step_per_tick).clamp(0.0, 0.98);
        }
        if self.delay_enabled {
            self.delay_time_secs =
                (self.delay_time_secs + self.delay_time_step_per_tick).clamp(0.01, 2.0);
            self.delay_feedback =
                (self.delay_feedback + self.delay_feedback_step_per_tick).clamp(0.0, 0.95);
            self.delay_mix = (self.delay_mix + self.delay_mix_step_per_tick).clamp(0.0, 1.0);
        }
    }
}

pub struct FxProcessor {
    settings: FxSettings,
    sample_rate: f32,
    delay_l: Vec<f32>,
    delay_r: Vec<f32>,
    delay_pos: usize,
    delay_samples: usize,
    flanger_l: Vec<f32>,
    flanger_r: Vec<f32>,
    flanger_pos: usize,
    flanger_phase: f32,
    chorus_l: Vec<f32>,
    chorus_r: Vec<f32>,
    chorus_pos: usize,
    chorus_phase: f32,
    reverb: Reverb,
}

impl FxProcessor {
    pub fn new(sample_rate: f32) -> Self {
        let sample_rate = sample_rate.max(1.0);
        let max_delay = (sample_rate * 2.0).ceil() as usize + 1;
        let max_flanger = (sample_rate * 0.025).ceil() as usize + 4;
        let max_chorus = (sample_rate * 0.060).ceil() as usize + 4;
        let mut fx = Self {
            settings: FxSettings::default(),
            sample_rate,
            delay_l: vec![0.0; max_delay],
            delay_r: vec![0.0; max_delay],
            delay_pos: 0,
            delay_samples: 1,
            flanger_l: vec![0.0; max_flanger],
            flanger_r: vec![0.0; max_flanger],
            flanger_pos: 0,
            flanger_phase: 0.0,
            chorus_l: vec![0.0; max_chorus],
            chorus_r: vec![0.0; max_chorus],
            chorus_pos: 0,
            chorus_phase: 0.0,
            reverb: Reverb::new(sample_rate),
        };
        fx.recompute_cached_lengths();
        fx
    }

    pub fn set_settings(&mut self, settings: FxSettings) {
        self.settings = settings;
        self.recompute_cached_lengths();
    }

    /// Silences every effect's memory and returns to the default settings (the Clear before a
    /// load). Never allocates, so the output callback can call it.
    pub fn reset(&mut self) {
        for buf in [
            &mut self.delay_l,
            &mut self.delay_r,
            &mut self.flanger_l,
            &mut self.flanger_r,
            &mut self.chorus_l,
            &mut self.chorus_r,
        ] {
            buf.fill(0.0);
        }
        self.delay_pos = 0;
        self.delay_samples = 1;
        self.flanger_pos = 0;
        self.flanger_phase = 0.0;
        self.chorus_pos = 0;
        self.chorus_phase = 0.0;
        self.reverb.clear();
        self.set_settings(FxSettings::default());
    }

    pub fn process(&mut self, left: f32, right: f32) -> (f32, f32) {
        if !self.settings.active() {
            // Off, even though process_reverb is skipped: turning it on starts from silence.
            self.reverb.running = false;
            return (left, right);
        }
        let (left, right) = self.process_flanger(left, right);
        let (left, right) = self.process_chorus(left, right);
        let (left, right) = self.process_pingpong(left, right);
        self.process_reverb(left, right)
    }

    fn recompute_cached_lengths(&mut self) {
        self.delay_samples = (self.settings.delay_time_secs * self.sample_rate)
            .round()
            .clamp(1.0, (self.delay_l.len() - 1) as f32) as usize;
        self.reverb.set_decay(self.settings.reverb_decay);
    }

    fn process_flanger(&mut self, left: f32, right: f32) -> (f32, f32) {
        if !self.settings.flanger_enabled {
            return (left, right);
        }
        let lfo = 0.5 + 0.5 * self.flanger_phase.sin();
        let base = self.settings.flanger_delay_ms * self.sample_rate * 0.001;
        let sweep = base * self.settings.flanger_depth;
        let delay =
            (base + sweep * (lfo - 0.5) * 2.0).clamp(1.0, self.flanger_l.len() as f32 - 2.0);
        let wet_l = read_delay(&self.flanger_l, self.flanger_pos, delay);
        let wet_r = read_delay(&self.flanger_r, self.flanger_pos, delay);
        self.flanger_l[self.flanger_pos] =
            (left + wet_l * self.settings.flanger_feedback).clamp(-1.0, 1.0);
        self.flanger_r[self.flanger_pos] =
            (right + wet_r * self.settings.flanger_feedback).clamp(-1.0, 1.0);
        self.flanger_pos = (self.flanger_pos + 1) % self.flanger_l.len();
        self.flanger_phase = advance_lfo(
            self.flanger_phase,
            self.settings.flanger_rate_hz,
            self.sample_rate,
        );
        let dry = 1.0 - self.settings.flanger_mix;
        (
            (left * dry + wet_l * self.settings.flanger_mix).clamp(-1.0, 1.0),
            (right * dry + wet_r * self.settings.flanger_mix).clamp(-1.0, 1.0),
        )
    }

    fn process_chorus(&mut self, left: f32, right: f32) -> (f32, f32) {
        if !self.settings.chorus_enabled {
            return (left, right);
        }
        let lfo_l = 0.5 + 0.5 * self.chorus_phase.sin();
        let lfo_r = 0.5 + 0.5 * (self.chorus_phase + std::f32::consts::PI * 0.67).sin();
        let base = self.settings.chorus_delay_ms * self.sample_rate * 0.001;
        let sweep = base * self.settings.chorus_depth * 0.75;
        let delay_l =
            (base + sweep * (lfo_l - 0.5) * 2.0).clamp(1.0, self.chorus_l.len() as f32 - 2.0);
        let delay_r =
            (base + sweep * (lfo_r - 0.5) * 2.0).clamp(1.0, self.chorus_r.len() as f32 - 2.0);
        let wet_l = read_delay(&self.chorus_l, self.chorus_pos, delay_l);
        let wet_r = read_delay(&self.chorus_r, self.chorus_pos, delay_r);
        self.chorus_l[self.chorus_pos] = left;
        self.chorus_r[self.chorus_pos] = right;
        self.chorus_pos = (self.chorus_pos + 1) % self.chorus_l.len();
        self.chorus_phase = advance_lfo(
            self.chorus_phase,
            self.settings.chorus_rate_hz,
            self.sample_rate,
        );
        let dry = 1.0 - self.settings.chorus_mix;
        (
            (left * dry + wet_l * self.settings.chorus_mix).clamp(-1.0, 1.0),
            (right * dry + wet_r * self.settings.chorus_mix).clamp(-1.0, 1.0),
        )
    }

    fn process_pingpong(&mut self, left: f32, right: f32) -> (f32, f32) {
        if !self.settings.delay_enabled {
            return (left, right);
        }
        let read = (self.delay_pos + self.delay_l.len() - self.delay_samples) % self.delay_l.len();
        let dl = self.delay_l[read];
        let dr = self.delay_r[read];
        self.delay_l[self.delay_pos] = (left + dr * self.settings.delay_feedback).clamp(-1.0, 1.0);
        self.delay_r[self.delay_pos] = (right + dl * self.settings.delay_feedback).clamp(-1.0, 1.0);
        self.delay_pos = (self.delay_pos + 1) % self.delay_l.len();
        (
            (left + dl * self.settings.delay_mix).clamp(-1.0, 1.0),
            (right + dr * self.settings.delay_mix).clamp(-1.0, 1.0),
        )
    }

    /// The specification's reverb (spec/Requirements.lean, markdown `reverb`), which replaces
    /// upstream's two clamped echoes: the wet pair from `Reverb`, crossfaded by mix; this final
    /// clamp is the reverb's only one.
    fn process_reverb(&mut self, left: f32, right: f32) -> (f32, f32) {
        if !self.settings.reverb_enabled {
            self.reverb.running = false;
            return (left, right);
        }
        if !self.reverb.running {
            self.reverb.clear();
            self.reverb.running = true;
        }
        // Per-tick decay steps change settings.reverb_decay; set_decay returns at once if unchanged.
        self.reverb.set_decay(self.settings.reverb_decay);
        let (wet_l, wet_r) = self.reverb.process(left, right);
        let dry = 1.0 - self.settings.reverb_mix;
        (
            (left * dry + wet_l * self.settings.reverb_mix).clamp(-1.0, 1.0),
            (right * dry + wet_r * self.settings.reverb_mix).clamp(-1.0, 1.0),
        )
    }
}

/// Every value written into reverb state below this magnitude becomes 0 (no subnormal floats).
const FLUSH_BELOW: f32 = 1e-15;

fn flush(x: f32) -> f32 {
    if x.abs() < FLUSH_BELOW {
        0.0
    } else {
        x
    }
}

/// The decay-to-T60 map of the specification: 0.25 s at decay 0, 4 s at 0.98.
pub fn reverb_t60(decay: f32) -> f32 {
    0.25 * 16.0f32.powf(decay / 0.98)
}

/// A delay of `len` samples inside `Reverb::storage`: the sample at `start + pos` was written
/// `len` samples ago.
#[derive(Clone, Copy)]
struct Line {
    start: usize,
    len: usize,
    pos: usize,
}

/// The specification's reverb (markdown `reverb`): two one-pole high-passes at 120 Hz and four
/// allpass diffusers per channel, then an eight-line tank with a Householder feedback matrix,
/// per-line decay gains and a one-pole damping low-pass at 5 kHz. `process` returns the wet pair
/// only; it is linear (no clamp) and never allocates. All delay memory is one Vec allocated by
/// `new`, cut into disjoint lines.
pub struct Reverb {
    storage: Vec<f32>,
    lines: [Line; 8],
    allpasses: [[Line; 4]; 2],
    /// Damped line outputs z_i.
    z: [f32; 8],
    /// Per channel: input of stage 1, output of stage 1, output of stage 2.
    hp: [[f32; 3]; 2],
    gains: [f32; 8],
    wet_gain: f32,
    decay: f32,
    hp_a: f32,
    damp_c: f32,
    sample_rate: f32,
    /// Whether it ran in the previous sample; turning it on clears it first.
    running: bool,
}

impl Reverb {
    pub const LINE_MS: [f32; 8] = [29.7, 37.1, 41.1, 43.7, 53.3, 59.9, 67.7, 73.3];
    pub const ALLPASS_MS: [f32; 4] = [4.77, 3.59, 12.73, 9.31];
    pub const RIGHT_STRETCH: f32 = 1.07;
    pub const ALLPASS_GAIN: f32 = 0.6;
    pub const HIGHPASS_HZ: f32 = 120.0;
    pub const DAMPING_HZ: f32 = 5000.0;

    fn samples(ms: f32, sample_rate: f32) -> usize {
        ((ms * sample_rate / 1000.0).round() as usize).max(1)
    }

    pub fn new(sample_rate: f32) -> Self {
        let sr = sample_rate.max(1.0);
        let mut at = 0;
        let mut take = |ms: f32| {
            let len = Self::samples(ms, sr);
            let line = Line { start: at, len, pos: 0 };
            at += len;
            line
        };
        let lines = Self::LINE_MS.map(&mut take);
        let mut allpasses = [[Line { start: 0, len: 1, pos: 0 }; 4]; 2];
        for (k, ms) in Self::ALLPASS_MS.iter().enumerate() {
            allpasses[0][k] = take(*ms);
            allpasses[1][k] = take(*ms * Self::RIGHT_STRETCH);
        }
        let mut reverb = Self {
            storage: vec![0.0; at],
            lines,
            allpasses,
            z: [0.0; 8],
            hp: [[0.0; 3]; 2],
            gains: [0.0; 8],
            wet_gain: 0.0,
            decay: f32::NAN,
            hp_a: (-2.0 * std::f32::consts::PI * Self::HIGHPASS_HZ / sr).exp(),
            damp_c: 1.0 - (-2.0 * std::f32::consts::PI * Self::DAMPING_HZ / sr).exp(),
            sample_rate: sr,
            running: false,
        };
        reverb.set_decay(0.65);
        reverb
    }

    /// Silence: no tail, no filter memory. Never allocates.
    pub fn clear(&mut self) {
        self.storage.fill(0.0);
        for line in self.lines.iter_mut().chain(self.allpasses.iter_mut().flatten()) {
            line.pos = 0;
        }
        self.z = [0.0; 8];
        self.hp = [[0.0; 3]; 2];
    }

    /// Recomputes the per-line gains and the wet gain for `decay`; returns at once if unchanged.
    pub fn set_decay(&mut self, decay: f32) {
        if decay == self.decay {
            return;
        }
        self.decay = decay;
        let t60 = reverb_t60(decay.clamp(0.0, 0.98));
        for (gain, line) in self.gains.iter_mut().zip(self.lines.iter()) {
            *gain = 10.0f32.powf(-3.0 * line.len as f32 / (self.sample_rate * t60));
        }
        self.wet_gain = 0.6 / t60.sqrt();
    }

    fn read(&self, line: Line) -> f32 {
        self.storage[line.start + line.pos]
    }

    fn write(storage: &mut [f32], line: &mut Line, v: f32) {
        storage[line.start + line.pos] = v;
        line.pos = if line.pos + 1 >= line.len { 0 } else { line.pos + 1 };
    }

    fn highpass(&mut self, ch: usize, x: f32) -> f32 {
        let a = self.hp_a;
        let h = &mut self.hp[ch];
        let y1 = flush(a * (h[1] + x - h[0]));
        let y2 = flush(a * (h[2] + y1 - h[1]));
        h[0] = flush(x);
        h[1] = y1;
        h[2] = y2;
        y2
    }

    fn diffuse(&mut self, ch: usize, x: f32) -> f32 {
        let mut v = x;
        for k in 0..4 {
            let b = self.read(self.allpasses[ch][k]);
            let w = v + Self::ALLPASS_GAIN * b;
            v = b - Self::ALLPASS_GAIN * w;
            Self::write(&mut self.storage, &mut self.allpasses[ch][k], flush(w));
        }
        v
    }

    /// One stereo sample in, the wet pair out.
    pub fn process(&mut self, left: f32, right: f32) -> (f32, f32) {
        let hl = self.highpass(0, left);
        let il = self.diffuse(0, hl);
        let hr = self.highpass(1, right);
        let ir = self.diffuse(1, hr);
        let mut sum = 0.0;
        for i in 0..8 {
            let s = self.read(self.lines[i]);
            let z = flush(self.z[i] + self.damp_c * (self.gains[i] * s - self.z[i]));
            self.z[i] = z;
            sum += z;
        }
        let mean = sum * 0.25;
        let mut sum_l = 0.0;
        for i in 0..8 {
            let inject = if i % 2 == 0 { il } else { ir };
            let fb = flush(self.z[i] - mean + inject);
            Self::write(&mut self.storage, &mut self.lines[i], fb);
            if i % 2 == 0 {
                sum_l += self.z[i];
            }
        }
        (self.wet_gain * sum_l, self.wet_gain * (sum - sum_l))
    }
}

fn advance_lfo(phase: f32, rate_hz: f32, sample_rate: f32) -> f32 {
    let next = phase + std::f32::consts::TAU * rate_hz / sample_rate.max(1.0);
    if next >= std::f32::consts::TAU {
        next - std::f32::consts::TAU
    } else {
        next
    }
}

fn read_delay(buf: &[f32], write_pos: usize, delay_samples: f32) -> f32 {
    let len = buf.len();
    let read = write_pos as f32 - delay_samples;
    let read = if read < 0.0 { read + len as f32 } else { read };
    let i0 = read.floor() as usize % len;
    let i1 = (i0 + 1) % len;
    let frac = read - read.floor();
    buf[i0] * (1.0 - frac) + buf[i1] * frac
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modulation_effects_produce_delayed_output() {
        let mut settings = FxSettings::default();
        settings.flanger_enabled = true;
        settings.chorus_enabled = true;
        let mut fx = FxProcessor::new(48_000.0);
        fx.set_settings(settings);

        let mut peak = 0.0f32;
        for sample in 0..2_000 {
            let input = if sample == 0 { 1.0 } else { 0.0 };
            let (left, right) = fx.process(input, input);
            if sample > 10 {
                peak = peak.max(left.abs()).max(right.abs());
            }
        }

        assert!(peak > 0.001);
    }

    /// The wet impulse response of a fresh reverb (`amp` into both channels at sample 0).
    fn reverb_impulse(sr: f32, decay: f32, amp: f32, n: usize) -> (Vec<f32>, Vec<f32>) {
        let mut r = Reverb::new(sr);
        r.set_decay(decay);
        (0..n)
            .map(|t| {
                let x = if t == 0 { amp } else { 0.0 };
                r.process(x, x)
            })
            .unzip()
    }

    fn rms(xs: &[f32]) -> f64 {
        (xs.iter().map(|&x| x as f64 * x as f64).sum::<f64>() / xs.len().max(1) as f64).sqrt()
    }

    fn db(ratio: f64) -> f64 {
        20.0 * ratio.max(1e-30).log10()
    }

    #[test]
    fn reverb_tail_follows_its_decay() {
        let sr = 48_000.0;
        let w = 2400; // 50 ms
        for decay in [0.0f32, 0.65] {
            let t60 = reverb_t60(decay);
            let n = (sr * t60 * 1.5) as usize + w + 1;
            let (l, _) = reverb_impulse(sr, decay, 1.0, n);
            let early = rms(&l[1440..1440 + w]); // 30..80 ms
            let half_at = (sr * t60 * 0.5) as usize;
            let late_at = (sr * t60 * 1.5) as usize;
            assert!(db(rms(&l[late_at..late_at + w]) / early) <= -60.0);
            assert!(db(rms(&l[half_at..half_at + w]) / early) > -60.0);
        }
        assert!((reverb_t60(0.0) - 0.25).abs() < 1e-6);
        assert!((reverb_t60(0.98) - 4.0).abs() < 1e-5);
    }

    #[test]
    fn reverb_is_dense_and_wide() {
        let (l, r) = reverb_impulse(48_000.0, 0.65, 1.0, 9600);
        let (l, r) = (&l[4800..], &r[4800..]);
        assert!(l.iter().chain(r.iter()).all(|&x| x != 0.0));
        let n = l.len() as f64;
        let ml = l.iter().map(|&x| x as f64).sum::<f64>() / n;
        let mr = r.iter().map(|&x| x as f64).sum::<f64>() / n;
        let (mut sab, mut saa, mut sbb) = (0.0, 0.0, 0.0);
        for (&a, &b) in l.iter().zip(r.iter()) {
            let (da, db) = (a as f64 - ml, b as f64 - mr);
            sab += da * db;
            saa += da * da;
            sbb += db * db;
        }
        assert!((sab / (saa * sbb).sqrt()).abs() < 0.3);
    }

    #[test]
    fn reverb_is_linear() {
        let (fl, fr) = reverb_impulse(48_000.0, 0.98, 1.0, 24_000);
        let (hl, hr) = reverb_impulse(48_000.0, 0.98, 0.5, 24_000);
        let mut peak = 0.0f32;
        for i in 0..fl.len() {
            peak = peak.max(fl[i].abs());
            assert!((fl[i] * 0.5 - hl[i]).abs() <= 1e-6 + fl[i].abs() * 1e-5);
            assert!((fr[i] * 0.5 - hr[i]).abs() <= 1e-6 + fr[i].abs() * 1e-5);
        }
        assert!(peak > 0.01);
        let mut r = Reverb::new(48_000.0);
        r.set_decay(0.98);
        assert!(r.gains.iter().all(|&g| g > 0.0 && g < 1.0));
        let covered: usize =
            r.lines.iter().chain(r.allpasses.iter().flatten()).map(|l| l.len).sum();
        assert_eq!(covered, r.storage.len());
    }

    #[test]
    fn reverb_keeps_the_low_end_dry() {
        let sr = 48_000.0f32;
        let level = |hz: f32| {
            let mut r = Reverb::new(sr);
            r.set_decay(0.65);
            let n = 48_000;
            let mut acc = 0.0f64;
            for t in 0..n {
                let x = 0.5 * (2.0 * std::f32::consts::PI * hz * t as f32 / sr).sin();
                let (w, _) = r.process(x, x);
                if t >= n / 2 {
                    acc += w as f64 * w as f64;
                }
            }
            (acc / (n / 2) as f64).sqrt()
        };
        assert!(db(level(40.0) / level(1000.0)) <= -12.0);
    }

    #[test]
    fn reverb_state_fades_to_exact_zero() {
        let mut r = Reverb::new(48_000.0);
        r.set_decay(0.0);
        r.process(1.0, -1.0);
        for _ in 0..48_000 * 4 {
            r.process(0.0, 0.0);
        }
        let ok = |v: &f32| *v == 0.0 || v.abs() >= FLUSH_BELOW;
        assert!(r.storage.iter().all(ok) && r.z.iter().all(ok) && r.hp.iter().flatten().all(ok));
        // After 4 s at T60 = 0.25 s (-960 dB) everything has been flushed.
        assert!(r.storage.iter().all(|&v| v == 0.0));
    }

    #[test]
    fn turning_the_reverb_on_starts_from_silence() {
        let mut fx = FxProcessor::new(48_000.0);
        let mut settings = FxSettings::default();
        settings.reverb_enabled = true;
        settings.reverb_mix = 1.0;
        settings.reverb_decay = 0.98;
        fx.set_settings(settings);
        fx.process(1.0, 1.0);
        for _ in 0..4800 {
            fx.process(0.0, 0.0);
        }
        assert!(fx.process(0.0, 0.0).0.abs() > 1e-4); // a tail is ringing
        settings.reverb_enabled = false;
        fx.set_settings(settings);
        fx.process(0.0, 0.0);
        settings.reverb_enabled = true;
        fx.set_settings(settings);
        for _ in 0..4800 {
            assert_eq!(fx.process(0.0, 0.0).0, 0.0);
        }
        // The Clear before a load silences it too.
        fx.process(1.0, 1.0);
        for _ in 0..4800 {
            fx.process(0.0, 0.0);
        }
        fx.reset();
        fx.set_settings(settings);
        for _ in 0..4800 {
            assert_eq!(fx.process(0.0, 0.0).1, 0.0);
        }
    }

    #[test]
    fn cabinet_is_bypassed_or_convolves_without_allocating() {
        let mut cabinet = CabinetProcessor::new(48_000.0);
        let mut settings = FxSettings::default();
        assert_eq!(cabinet.process(0.25, settings), 0.25);

        settings.cabinet_enabled = true;
        settings.cabinet_mix = 1.0;
        let first = cabinet.process(1.0, settings);
        let tail = cabinet.process(0.0, settings);
        assert!(first.is_finite() && first.abs() > 0.01);
        assert!(tail.is_finite() && tail.abs() > 0.0001);
    }
}
