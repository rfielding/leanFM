// tuning.rs — just intonation tuning for oud-based maqam

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

pub const D_HZ: f64 = 293.6648_f64;
static TUNING_BASE_HZ: OnceLock<RwLock<f64>> = OnceLock::new();

fn clamp(x: f64) -> u8 {
    x.round().clamp(0.0, 255.0) as u8
}

// ── Pitch table ───────────────────────────────────────────────────────────────

const PITCH_TABLE: &[(&str, u32, u32)] = &[
    ("d", 1, 1),
    ("d+", 256, 243),
    ("e-", 256, 243),
    ("e¾", 12, 11),
    ("e", 9, 8),
    ("f", 32, 27),
    ("f+", 81, 64),
    ("g-", 81, 64),
    ("g", 4, 3),
    ("g+", 1024, 729),
    ("a-", 1024, 729),
    ("a", 3, 2),
    ("a+", 128, 81),
    ("b-", 128, 81),
    ("b", 27, 16),
    ("c-", 27, 16),
    ("c", 16, 9),
    ("c+", 1, 1),
];

fn pitch_ratio(letter: char, accidental: i8) -> (u32, u32) {
    let key: String = match accidental {
        1 => format!("{}+", letter),
        -1 => format!("{}-", letter),
        _ => letter.to_string(),
    };
    for (name, p, q) in PITCH_TABLE {
        if *name == key.as_str() {
            return (*p, *q);
        }
    }
    for (name, p, q) in PITCH_TABLE {
        if name.starts_with(letter) && name.len() == 1 {
            return (*p, *q);
        }
    }
    (1, 1)
}

fn tuning_base_hz() -> f64 {
    *TUNING_BASE_HZ
        .get_or_init(|| RwLock::new(D_HZ))
        .read()
        .unwrap()
}

pub fn reset_tuning_base() {
    *TUNING_BASE_HZ
        .get_or_init(|| RwLock::new(D_HZ))
        .write()
        .unwrap() = D_HZ;
}

pub fn tune_to_standard_pitch(pitch: Pitch) {
    let (p, q) = pitch_ratio(pitch.letter, pitch.accidental);
    let ratio = p as f64 / q as f64;
    let octave = 2f64.powi(pitch.octave as i32 - 4);
    let base = pitch.standard_midi_hz() / (ratio * octave);
    *TUNING_BASE_HZ
        .get_or_init(|| RwLock::new(D_HZ))
        .write()
        .unwrap() = base;
}

pub fn pitch_to_hz(letter: char, accidental: i8, octave: u8) -> f64 {
    let (p, q) = pitch_ratio(letter, accidental);
    tuning_base_hz() * p as f64 / q as f64 * 2f64.powi(octave as i32 - 4)
}

pub fn snap_to_oud_lattice(nominal_hz: f64) -> f64 {
    let base_hz = tuning_base_hz();
    let mut hz = nominal_hz;
    while hz < base_hz {
        hz *= 2.0;
    }
    while hz >= base_hz * 2.0 {
        hz /= 2.0;
    }
    let ratio = hz / base_hz;
    let mut best_hz = hz;
    let mut best_dist = f64::MAX;
    for &(_, p, q) in PITCH_TABLE {
        let r = p as f64 / q as f64;
        let dist = (r / ratio).log2().abs();
        if dist < best_dist {
            best_dist = dist;
            best_hz = base_hz * r;
        }
    }
    best_hz
}

// ── Jins registry ─────────────────────────────────────────────────────────────

type RatioList = Vec<(u32, u32)>;
type JinsRegistry = HashMap<String, RatioList>;

static REGISTRY: OnceLock<RwLock<JinsRegistry>> = OnceLock::new();

fn default_registry_map() -> JinsRegistry {
    let mut m = JinsRegistry::new();
    m.insert(
        "Nahawand".into(),
        vec![(1, 1), (9, 8), (32, 27), (4, 3), (3, 2)],
    );
    m.insert(
        "Bayati".into(),
        vec![(1, 1), (12, 11), (32, 27), (4, 3), (3, 2)],
    );
    m.insert(
        "Hijaz".into(),
        vec![(1, 1), (256, 243), (81, 64), (4, 3), (3, 2)],
    );
    m.insert(
        "Rast".into(),
        vec![(1, 1), (9, 8), (27, 22), (4, 3), (3, 2)],
    );
    m.insert(
        "Kurd".into(),
        vec![(1, 1), (256, 243), (32, 27), (4, 3), (3, 2)],
    );
    m.insert("Saba".into(), vec![(1, 1), (13, 12), (32, 27), (5, 4)]);
    m.insert("Zaba".into(), vec![(1, 1), (12, 11), (32, 27), (11, 8)]);
    m.insert("Zamzam".into(), vec![(1, 1), (16, 15), (32, 27), (6, 5)]);
    m.insert("Ajam".into(), vec![(1, 1), (9, 8), (5, 4), (4, 3), (3, 2)]);
    m.insert(
        "Nikriz".into(),
        vec![(1, 1), (256, 243), (81, 64), (4, 3), (3, 2)],
    );
    m.insert(
        "Suznak".into(),
        vec![(1, 1), (9, 8), (27, 22), (4, 3), (3, 2)],
    );
    m.insert(
        "Jiharkah".into(),
        vec![(1, 1), (9, 8), (5, 4), (4, 3), (3, 2)],
    );
    m.insert(
        "Major".into(),
        vec![(1, 1), (9, 8), (5, 4), (4, 3), (3, 2), (5, 3), (15, 8)],
    );
    m.insert(
        "Ionian".into(),
        vec![
            (1, 1),
            (9, 8),
            (81, 64),
            (4, 3),
            (3, 2),
            (27, 16),
            (243, 128),
        ],
    );
    m.insert(
        "Dorian".into(),
        vec![(1, 1), (9, 8), (32, 27), (4, 3), (3, 2), (27, 16), (16, 9)],
    );
    m.insert(
        "Phrygian".into(),
        vec![
            (1, 1),
            (256, 243),
            (32, 27),
            (4, 3),
            (3, 2),
            (128, 81),
            (16, 9),
        ],
    );
    m.insert(
        "Lydian".into(),
        vec![
            (1, 1),
            (9, 8),
            (81, 64),
            (729, 512),
            (3, 2),
            (27, 16),
            (243, 128),
        ],
    );
    m.insert(
        "Mixolydian".into(),
        vec![(1, 1), (9, 8), (81, 64), (4, 3), (3, 2), (27, 16), (16, 9)],
    );
    m.insert(
        "Minor".into(),
        vec![(1, 1), (9, 8), (32, 27), (4, 3), (3, 2), (27, 16), (16, 9)],
    );
    m.insert(
        "Aeolian".into(),
        vec![(1, 1), (9, 8), (32, 27), (4, 3), (3, 2), (128, 81), (16, 9)],
    );
    m.insert(
        "Locrian".into(),
        vec![
            (1, 1),
            (256, 243),
            (32, 27),
            (4, 3),
            (1024, 729),
            (128, 81),
            (16, 9),
        ],
    );
    m.insert(
        "Diminished".into(),
        vec![
            (1, 1),
            (9, 8),
            (6, 5),
            (4, 3),
            (64, 45),
            (8, 5),
            (5, 3),
            (15, 8),
        ],
    );
    m
}

fn registry() -> &'static RwLock<HashMap<String, Vec<(u32, u32)>>> {
    REGISTRY.get_or_init(|| RwLock::new(default_registry_map()))
}

// ── Maqam ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Maqam(pub String);

impl Maqam {
    pub fn new(name: &str) -> Self {
        Maqam(name.to_string())
    }

    /// Case-insensitive prefix match against registry names.
    pub fn parse(s: &str) -> Option<Self> {
        let s_lower = s.to_ascii_lowercase();
        if s_lower.len() < 2 {
            return None;
        }
        let reg = registry().read().unwrap();
        // Exact match first
        for name in reg.keys() {
            if name.to_ascii_lowercase() == s_lower {
                return Some(Maqam(name.clone()));
            }
        }
        // Prefix match — pick shortest to avoid ambiguity
        let mut matches: Vec<&String> = reg
            .keys()
            .filter(|n| n.to_ascii_lowercase().starts_with(&s_lower))
            .collect();
        matches.sort_by_key(|n| n.len());
        matches.into_iter().next().map(|n| Maqam(n.clone()))
    }

    pub fn name(&self) -> &str {
        &self.0
    }

    pub fn validate_ratios(ratios: &[(u32, u32)]) -> Result<(), String> {
        if ratios.is_empty() {
            return Err("need at least one ratio".into());
        }
        if !ratios.iter().any(|&(p, q)| p == q) {
            return Err("scale must include 1/1".into());
        }
        let mut prev = None::<f64>;
        for &(p, q) in ratios {
            if q == 0 {
                return Err("ratio denominator cannot be zero".into());
            }
            let cur = p as f64 / q as f64;
            if let Some(last) = prev {
                if cur <= last {
                    return Err("scale ratios must be strictly ascending".into());
                }
            }
            prev = Some(cur);
        }
        Ok(())
    }

    /// Ratios from the live registry — reflects runtime create/delete.
    pub fn ratios(&self) -> Vec<(u32, u32)> {
        registry()
            .read()
            .unwrap()
            .get(&self.0)
            .cloned()
            .unwrap_or_default()
    }

    /// Sorted list of all registered jins.
    pub fn list_all() -> Vec<(String, Vec<(u32, u32)>)> {
        let reg = registry().read().unwrap();
        let mut v: Vec<_> = reg.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    }

    /// Sorted list of jins that differ from the built-in defaults.
    pub fn list_custom() -> Vec<(String, Vec<(u32, u32)>)> {
        let defaults = default_registry_map();
        let reg = registry().read().unwrap();
        let mut v: Vec<_> = reg
            .iter()
            .filter(|(name, ratios)| defaults.get(*name) != Some(*ratios))
            .map(|(name, ratios)| (name.clone(), ratios.clone()))
            .collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    }

    pub fn color_for_ratios(ratios: &[(u32, u32)]) -> [u8; 3] {
        color_for_ratio_key(
            &ratios
                .iter()
                .map(|(p, q)| format!("{p}/{q}"))
                .collect::<Vec<_>>()
                .join("|"),
        )
    }

    pub fn color_for_ratio_strs(ratios: &[String]) -> [u8; 3] {
        color_for_ratio_key(&ratios.join("|"))
    }

    /// Create or overwrite a jins entry.
    pub fn create(name: &str, ratios: Vec<(u32, u32)>) -> Result<(), String> {
        Self::validate_ratios(&ratios)?;
        registry().write().unwrap().insert(name.to_string(), ratios);
        Ok(())
    }

    /// Delete a jins entry. Returns false if it didn't exist.
    pub fn delete(name: &str) -> bool {
        registry().write().unwrap().remove(name).is_some()
    }

    /// Replace the live registry with built-in defaults.
    pub fn reset_to_defaults() {
        *registry().write().unwrap() = default_registry_map();
    }

    #[allow(dead_code)]
    pub fn degree_hz(&self, root_hz: f64, degree: usize) -> f64 {
        let ratios = self.ratios();
        if ratios.is_empty() {
            return root_hz;
        }
        let (p, q) = ratios[degree.min(ratios.len() - 1)];
        root_hz * p as f64 / q as f64
    }
}

fn color_for_ratio_key(key: &str) -> [u8; 3] {
    const PALETTE: [[u8; 3]; 8] = [
        [188, 72, 84],
        [58, 136, 92],
        [72, 116, 184],
        [188, 136, 52],
        [120, 86, 188],
        [48, 154, 154],
        [196, 92, 44],
        [150, 124, 60],
    ];

    let mut h = 2166136261u32;
    for b in key.as_bytes() {
        h = h.wrapping_mul(16777619) ^ *b as u32;
    }
    let base = PALETTE[(h as usize) % PALETTE.len()];
    let bump = ((h >> 8) % 23) as f64 - 11.0;
    [
        clamp(base[0] as f64 + bump),
        clamp(base[1] as f64 - bump * 0.4),
        clamp(base[2] as f64 + bump * 0.2),
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        default_registry_map, pitch_to_hz, reset_tuning_base, tune_to_standard_pitch, Pitch,
    };

    #[test]
    fn zamzam_is_a_builtin_jins() {
        assert_eq!(
            default_registry_map().get("Zamzam"),
            Some(&vec![(1, 1), (16, 15), (32, 27), (6, 5)])
        );
    }

    #[test]
    fn western_modes_are_builtin_jins() {
        let defaults = default_registry_map();
        assert_eq!(
            defaults.get("Major"),
            Some(&vec![
                (1, 1),
                (9, 8),
                (5, 4),
                (4, 3),
                (3, 2),
                (5, 3),
                (15, 8)
            ])
        );
        assert_eq!(
            defaults.get("Minor"),
            Some(&vec![
                (1, 1),
                (9, 8),
                (32, 27),
                (4, 3),
                (3, 2),
                (27, 16),
                (16, 9)
            ])
        );
        assert_eq!(
            defaults.get("Locrian"),
            Some(&vec![
                (1, 1),
                (256, 243),
                (32, 27),
                (4, 3),
                (1024, 729),
                (128, 81),
                (16, 9)
            ])
        );
        assert_eq!(defaults.get("Ionian").unwrap()[2], (81, 64));
        assert_eq!(defaults.get("Dorian").unwrap()[2], (32, 27));
        assert_eq!(defaults.get("Phrygian").unwrap()[1], (256, 243));
        assert_eq!(defaults.get("Lydian").unwrap()[3], (729, 512));
        assert_eq!(defaults.get("Mixolydian").unwrap()[6], (16, 9));
        assert_eq!(defaults.get("Aeolian").unwrap()[5], (128, 81));
        assert_eq!(
            defaults.get("Diminished"),
            Some(&vec![
                (1, 1),
                (9, 8),
                (6, 5),
                (4, 3),
                (64, 45),
                (8, 5),
                (5, 3),
                (15, 8)
            ])
        );
    }

    #[test]
    fn tuneto_anchors_lattice_pitch_to_standard_midi_pitch() {
        reset_tuning_base();
        assert!((pitch_to_hz('d', 0, 4) - 293.6648).abs() < 0.0001);

        tune_to_standard_pitch(Pitch::parse("a").unwrap());
        assert!((pitch_to_hz('a', 0, 4) - 440.0).abs() < 0.0001);

        tune_to_standard_pitch(Pitch::parse("c").unwrap());
        assert!((pitch_to_hz('c', 0, 4) - 261.625_565).abs() < 0.0001);

        reset_tuning_base();
    }
}

// ── Pitch ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pitch {
    pub letter: char,
    pub accidental: i8,
    pub octave: u8,
}

impl Pitch {
    pub fn parse(s: &str) -> Option<Self> {
        let s = s.to_ascii_lowercase();
        let mut it = s.chars().peekable();
        let letter = it.next()?;
        if !"cdefgab".contains(letter) {
            return None;
        }
        let mut accidental = 0i8;
        match it.peek().copied() {
            Some('+') | Some('#') => {
                accidental = 1;
                it.next();
            }
            Some('-') => {
                accidental = -1;
                it.next();
            }
            _ => {}
        }
        let octave = match it.next() {
            Some(d) if d.is_ascii_digit() => d as u8 - b'0',
            None => 4,
            _ => return None,
        };
        Some(Pitch {
            letter,
            accidental,
            octave,
        })
    }

    pub fn to_hz(self) -> f64 {
        pitch_to_hz(self.letter, self.accidental, self.octave)
    }

    pub fn standard_midi_hz(self) -> f64 {
        let pitch_class = match self.letter.to_ascii_lowercase() {
            'c' => 0,
            'd' => 2,
            'e' => 4,
            'f' => 5,
            'g' => 7,
            'a' => 9,
            'b' => 11,
            _ => 0,
        } + self.accidental as i32;
        let midi = (self.octave as i32 + 1) * 12 + pitch_class;
        440.0 * 2f64.powf((midi as f64 - 69.0) / 12.0)
    }

    pub fn source_token(self) -> String {
        let mut s = self.letter.to_ascii_lowercase().to_string();
        match self.accidental {
            1 => s.push('+'),
            -1 => s.push('-'),
            _ => {}
        }
        if self.octave != 4 {
            s.push(char::from(b'0' + self.octave));
        }
        s
    }

    #[allow(dead_code)]
    pub fn display(self) -> String {
        let mut s = self.letter.to_ascii_uppercase().to_string();
        match self.accidental {
            1 => s.push('+'),
            -1 => s.push('-'),
            _ => {}
        }
        s
    }
}
