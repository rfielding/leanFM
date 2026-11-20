pub fn soft_clip(sample: f32) -> f32 {
    // A gentle console-style curve: unity-ish around quiet signals, then
    // progressively bends peaks instead of flattening them at +/-1.
    let driven = sample * 0.85;
    (driven + 0.2 * driven.powi(3)).tanh()
}

pub fn soft_clip_stereo(left: f32, right: f32) -> (f32, f32) {
    (soft_clip(left), soft_clip(right))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn soft_clip_preserves_quiet_signal_and_bounds_hot_signal() {
        assert!((soft_clip(0.1) - 0.085).abs() < 0.002);
        assert!(soft_clip(2.0) > 0.9);
        assert!(soft_clip(2.0) < 1.0);
        assert!(soft_clip(-2.0) < -0.9);
        assert!(soft_clip(-2.0) > -1.0);
    }
}
