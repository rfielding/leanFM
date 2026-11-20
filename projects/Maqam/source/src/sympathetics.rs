use std::f32::consts::TAU;

struct Mode {
    frequency: f32,
    coupling: f32,
    targeted: bool,
    modulation_phase: f32,
    modulation_rate: f32,
    y1: f32,
    y2: f32,
}

pub struct SympatheticStrings {
    sample_rate: f32,
    modes: Vec<Mode>,
    envelope: f32,
    previous_envelope: f32,
    noise_floor: f32,
    gate: f32,
    wet: f32,
    input_gain: f32,
    decay: f32,
    previous_input: f32,
}

impl SympatheticStrings {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate,
            modes: Vec::new(),
            envelope: 0.0,
            previous_envelope: 0.0,
            noise_floor: 0.002,
            gate: 0.0,
            wet: 0.65,
            input_gain: 2.0,
            decay: 0.999,
            previous_input: 0.0,
        }
    }

    pub fn set_targets(&mut self, frequencies: &[f64]) {
        let mut string_frequencies = frequencies.to_vec();
        if let Some(&tonic) = frequencies.first() {
            // Taraf strings prominently reinforce the tonic, fourth, and
            // fifth. Add the latter two explicitly even when the current
            // maqam's degree list does not land exactly on those ratios.
            string_frequencies.push(tonic * 4.0 / 3.0);
            string_frequencies.push(tonic * 3.0 / 2.0);
        }
        let weighted: Vec<_> = string_frequencies
            .into_iter()
            .map(|frequency| (frequency, 1.0))
            .collect();
        self.set_weighted_targets(&weighted);
    }

    pub fn set_weighted_targets(&mut self, frequencies: &[(f64, f32)]) {
        let mut targets: Vec<(f32, f32)> = Vec::new();
        for &(frequency, target_weight) in frequencies {
            let target_weight = target_weight.max(0.0);
            if target_weight <= f32::EPSILON {
                continue;
            }
            let mut hz = frequency as f32;
            // Keep the sympathetic bank well above the main instrument's body:
            // its lowest course lives in the 320–640 Hz octave.
            while hz >= 320.0 {
                hz *= 0.5;
            }
            while hz > 0.0 && hz < 320.0 {
                hz *= 2.0;
            }
            // A metal sympathetic course radiates a family of partials, not
            // just a single sine resonance. Odd partials are especially
            // important to the bright Sarod bridge response.
            for (harmonic, coupling) in [
                (1.0, 1.0),
                (2.0, 0.92),
                (3.0, 0.78),
                (4.0, 0.66),
                (5.0, 0.56),
                (6.0, 0.46),
                (8.0, 0.38),
                (10.0, 0.30),
                (12.0, 0.24),
            ] {
                let partial = hz * harmonic;
                if partial > 4_500.0 {
                    continue;
                }
                let coupling = coupling * target_weight;
                if let Some(existing) = targets
                    .iter_mut()
                    .find(|(other, _)| 1200.0 * (partial / *other).log2().abs() < 8.0)
                {
                    existing.1 += coupling;
                } else {
                    targets.push((partial, coupling));
                }
            }
        }
        targets.sort_by(|a, b| a.0.total_cmp(&b.0));
        targets.truncate(64);
        for mode in &mut self.modes {
            mode.targeted = false;
        }
        for (frequency, coupling) in targets {
            if let Some(mode) = self
                .modes
                .iter_mut()
                .find(|mode| 1200.0 * (frequency / mode.frequency).log2().abs() < 8.0)
            {
                mode.frequency = frequency;
                mode.coupling = coupling;
                mode.targeted = true;
            } else {
                self.modes.push(Mode {
                    frequency,
                    coupling,
                    targeted: true,
                    modulation_phase: (frequency * 0.071).fract() * TAU,
                    modulation_rate: 0.08 + (frequency * 0.013).fract() * 0.24,
                    y1: 0.0,
                    y2: 0.0,
                });
            }
        }
    }

    pub fn set_decay(&mut self, decay: f32) {
        self.decay = decay.clamp(0.9, 0.999_99);
    }

    pub fn set_input_gain(&mut self, gain: f32) {
        self.input_gain = gain.clamp(0.0, 512.0);
    }

    pub fn has_energy(&self) -> bool {
        self.modes
            .iter()
            .any(|mode| mode.y1.abs().max(mode.y2.abs()) > 0.000_01)
    }

    pub fn process(&mut self, input: f32) -> f32 {
        let driven_input = (input * self.input_gain).tanh();
        let magnitude = driven_input.abs();
        self.envelope += (magnitude - self.envelope) * 0.0025;
        let onset = (self.envelope - self.previous_envelope).max(0.0);
        self.previous_envelope = self.envelope;
        // Learn the floor only while input is close to quiet. This prevents a
        // sustained note from teaching the gate that the note itself is noise.
        if self.envelope < self.noise_floor * 2.0 {
            self.noise_floor += (self.envelope - self.noise_floor) * 0.0002;
        }
        self.noise_floor = self.noise_floor.clamp(0.000_05, 0.05);
        let threshold = (self.noise_floor * 3.5).max(0.0015);
        let wanted_gate = if self.envelope > threshold { 1.0 } else { 0.0 };
        let gate_rate = if wanted_gate > self.gate {
            0.01
        } else {
            0.0008
        };
        self.gate += (wanted_gate - self.gate) * gate_rate;
        // Bridge coupling emphasizes the input's changing edge while retaining
        // enough body to sustain a sung or bowed note.
        let edge = driven_input - self.previous_input;
        self.previous_input = driven_input;
        // The onset term represents broadband mechanical energy crossing the
        // bridge. It lights the whole taraf bank on an attack; pitched input
        // then sustains only the matching strings.
        let sustained_excitation = (driven_input * 0.72 + edge * 3.5) * self.gate;
        let bridge_strike = onset * 300.0;

        if self.modes.is_empty() {
            return 0.0;
        }
        let mut sum = 0.0;
        for mode in &mut self.modes {
            // `decay` is retention per millisecond, not per sample. This gives
            // the metal courses an acoustic ring measured in seconds. Upper
            // partials damp somewhat faster than the fundamental.
            mode.modulation_phase =
                (mode.modulation_phase + TAU * mode.modulation_rate / self.sample_rate) % TAU;
            // Independent sub-two-cent drift creates the slow movement of many
            // real metal courses without replacing their exact JI centers.
            let drift_cents = mode.modulation_phase.sin() * 1.7;
            let sounding_frequency = mode.frequency * 2.0f32.powf(drift_cents / 1200.0);
            let frequency_damping = (sounding_frequency / 440.0).max(0.5).sqrt();
            let radius = self
                .decay
                .powf(frequency_damping / (self.sample_rate * 0.001));
            let coefficient = 2.0 * radius * (TAU * sounding_frequency / self.sample_rate).cos();
            let drive = if mode.targeted {
                sustained_excitation * (1.0 - radius) + bridge_strike * 0.003
            } else {
                0.0
            };
            let y = coefficient * mode.y1 - radius * radius * mode.y2 + drive * mode.coupling;
            mode.y2 = mode.y1;
            mode.y1 = y.clamp(-4.0, 4.0);
            sum += mode.y1 * mode.coupling;
        }
        // Use a fixed bank normalization so adding the next phrase's strings
        // never turns down a chord that is already ringing.
        let raw = sum / 8.0 * self.wet;
        // A shallow asymmetric-free nonlinearity adds the odd upper partials
        // associated with a jawari-style buzzing bridge.
        let output = (raw + (raw * 3.0).tanh() * 0.22).tanh();
        self.modes
            .retain(|mode| mode.targeted || mode.y1.abs().max(mode.y2.abs()) > 0.000_01);
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_bank_is_bounded_and_silent_without_excitation() {
        let mut strings = SympatheticStrings::new(48_000.0);
        strings.set_targets(&[220.0, 275.0, 330.0]);
        assert!(!strings.modes.is_empty());
        assert!(strings.modes.len() <= 64);
        assert_eq!(strings.process(0.0), 0.0);
    }

    #[test]
    fn matching_input_audibly_excites_the_bank() {
        let mut strings = SympatheticStrings::new(48_000.0);
        strings.set_targets(&[440.0]);
        let mut peak = 0.0f32;
        for sample in 0..48_000 {
            let input = if sample < 12_000 {
                (TAU * 440.0 * sample as f32 / 48_000.0).sin() * 0.05
            } else {
                0.0
            };
            peak = peak.max(strings.process(input).abs());
        }
        assert!(peak > 0.01, "sympathetic peak was only {peak}");
    }

    #[test]
    fn taraf_bank_is_high_and_includes_tonic_fourth_and_fifth() {
        let mut strings = SympatheticStrings::new(48_000.0);
        strings.set_targets(&[220.0]);

        assert!(strings.modes.iter().all(|mode| mode.frequency >= 320.0));
        for wanted in [220.0 * 4.0 / 3.0, 220.0 * 3.0 / 2.0] {
            let wanted = if wanted < 320.0 { wanted * 2.0 } else { wanted };
            assert!(strings
                .modes
                .iter()
                .any(|mode| 1200.0 * (mode.frequency / wanted).log2().abs() < 8.0));
        }
    }

    #[test]
    fn bridge_strike_leaves_a_ringing_tail() {
        let mut strings = SympatheticStrings::new(48_000.0);
        strings.set_targets(&[220.0, 275.0, 330.0]);
        strings.process(0.2);
        let mut tail_energy = 0.0;
        for sample in 0..9_600 {
            let output = strings.process(0.0);
            if sample >= 2_400 {
                tail_energy += output * output;
            }
        }
        let tail_rms = (tail_energy / 7_200.0).sqrt();
        assert!(tail_rms > 0.0001, "taraf tail was only {tail_rms}");
    }

    #[test]
    fn retuning_preserves_energy_in_old_strings() {
        let mut strings = SympatheticStrings::new(48_000.0);
        strings.set_targets(&[440.0]);
        for sample in 0..4_800 {
            let input = (TAU * 440.0 * sample as f32 / 48_000.0).sin() * 0.1;
            strings.process(input);
        }
        strings.set_targets(&[554.0]);

        let old = strings
            .modes
            .iter()
            .find(|mode| (mode.frequency - 440.0).abs() < 1.0)
            .expect("old tonic string should remain while ringing");
        assert!(!old.targeted);
        assert!(old.y1.abs().max(old.y2.abs()) > 0.000_01);
        assert!(strings.process(0.0).abs() > 0.000_01);
    }
}
