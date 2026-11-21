use std::fs::File;
#[cfg(not(test))]
use std::io::Read;
use std::io::Write;
use std::process::Command;
#[cfg(not(test))]
use std::process::Stdio;
use std::sync::{Arc, Mutex, RwLock};

pub const WIDTH: usize = 320;
pub const HEIGHT: usize = 240;
pub const FPS: usize = 12;

pub struct Camera {
    frame: Arc<RwLock<Option<Vec<u8>>>>,
    status: Arc<RwLock<String>>,
    take_file: Arc<Mutex<Option<File>>>,
    raw_path: Arc<Mutex<Option<String>>>,
}

impl Camera {
    #[cfg(test)]
    pub fn start() -> Option<Self> {
        None
    }

    #[cfg(not(test))]
    pub fn start() -> Option<Self> {
        let device = first_video_device()?;
        let mut child = Command::new("ffmpeg")
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "avfoundation",
                "-framerate",
                &FPS.to_string(),
                "-i",
                &format!("{device}:none"),
                "-vf",
                &format!("scale={WIDTH}:{HEIGHT}"),
                "-pix_fmt",
                "rgb24",
                "-f",
                "rawvideo",
                "pipe:1",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .ok()?;
        let mut stdout = child.stdout.take()?;
        let mut stderr = child.stderr.take();
        let frame = Arc::new(RwLock::new(None));
        let status = Arc::new(RwLock::new("starting…".into()));
        let take_file = Arc::new(Mutex::new(None::<File>));
        let raw_path = Arc::new(Mutex::new(None));
        let thread_frame = Arc::clone(&frame);
        let thread_status = Arc::clone(&status);
        let thread_file = Arc::clone(&take_file);
        std::thread::spawn(move || {
            let mut pixels = vec![0u8; WIDTH * HEIGHT * 3];
            while stdout.read_exact(&mut pixels).is_ok() {
                if let Ok(mut status) = thread_status.write() {
                    *status = "live".into();
                }
                if crate::TAKE_RECORDING.load(std::sync::atomic::Ordering::Relaxed) {
                    if let Ok(mut file) = thread_file.lock() {
                        if let Some(file) = file.as_mut() {
                            let _ = file.write_all(&pixels);
                        }
                    }
                }
                if let Ok(mut latest) = thread_frame.write() {
                    *latest = Some(pixels.clone());
                }
            }
            let mut detail = String::new();
            if let Some(stderr) = stderr.as_mut() {
                let _ = stderr.read_to_string(&mut detail);
            }
            let _ = child.wait();
            let detail = detail
                .lines()
                .last()
                .filter(|line| !line.trim().is_empty())
                .unwrap_or("camera stopped producing frames");
            if let Ok(mut status) = thread_status.write() {
                *status = format!("unavailable: {detail}");
            }
        });
        Some(Self {
            frame,
            status,
            take_file,
            raw_path,
        })
    }

    pub fn frame(&self) -> Option<Vec<u8>> {
        self.frame.read().ok()?.clone()
    }

    pub fn status(&self) -> String {
        self.status
            .read()
            .map(|status| status.clone())
            .unwrap_or_else(|_| "unavailable".into())
    }

    pub fn arm_take(&self, stem: &str) -> Result<(), String> {
        let path = format!("{stem}.rgb");
        let file = File::create(&path).map_err(|e| format!("could not create {path}: {e}"))?;
        *self
            .take_file
            .lock()
            .map_err(|_| "camera recorder lock failed")? = Some(file);
        *self
            .raw_path
            .lock()
            .map_err(|_| "camera recorder lock failed")? = Some(path);
        Ok(())
    }

    pub fn finish_take(
        &self,
        wav_path: String,
        phrases: Vec<crate::sequencer::Phrase>,
        bpm: f64,
        sustain: f64,
        vcf: crate::vcf::VcfBank,
        fx: crate::fx::FxSettings,
    ) -> Option<crossbeam_channel::Receiver<Result<String, String>>> {
        let mut file = self.take_file.lock().ok()?.take()?;
        let _ = file.flush();
        drop(file);
        let raw_path = self.raw_path.lock().ok()?.take()?;
        let frame_bytes = (WIDTH * HEIGHT * 3) as u64;
        let raw_bytes = std::fs::metadata(&raw_path).ok()?.len();
        if raw_bytes < frame_bytes {
            let _ = std::fs::remove_file(raw_path);
            return Some(finish_take_video(
                wav_path, phrases, bpm, sustain, vcf, fx, None,
            ));
        }
        Some(finish_take_video(
            wav_path,
            phrases,
            bpm,
            sustain,
            vcf,
            fx,
            Some(raw_path),
        ))
    }
}

pub fn finish_take_without_camera(
    wav_path: String,
    phrases: Vec<crate::sequencer::Phrase>,
    bpm: f64,
    sustain: f64,
    vcf: crate::vcf::VcfBank,
    fx: crate::fx::FxSettings,
) -> crossbeam_channel::Receiver<Result<String, String>> {
    finish_take_video(wav_path, phrases, bpm, sustain, vcf, fx, None)
}

fn finish_take_video(
    wav_path: String,
    phrases: Vec<crate::sequencer::Phrase>,
    bpm: f64,
    sustain: f64,
    vcf: crate::vcf::VcfBank,
    fx: crate::fx::FxSettings,
    raw_path: Option<String>,
) -> crossbeam_channel::Receiver<Result<String, String>> {
    let output_path = wav_path.trim_end_matches(".wav").to_string() + ".mp4";
    let carpet_path = wav_path.trim_end_matches(".wav").to_string() + ".carpet.ppm";
    let (tx, rx) = crossbeam_channel::bounded(1);
    std::thread::spawn(move || {
        let highlights = crate::record::take_carpet_highlights(&phrases, bpm, sustain, vcf, fx);
        let encode_result = crate::carpet::write_take_carpet_background(&carpet_path, &phrases)
                .map_err(|e| format!("could not draw take carpet: {e}"))
                .and_then(|_| {
                    let mut command = Command::new("ffmpeg");
                    command.args(["-y", "-hide_banner", "-loglevel", "error", "-loop", "1", "-framerate", "30", "-i", &carpet_path]);
                    if let Some(raw) = &raw_path {
                        let filter = format!("[0:v]{highlights},scale=960:720[carpet];[1:v]scale=320:240,tpad=stop_mode=clone,pad=320:720:0:240:black[camera];[carpet][camera]hstack=inputs=2[v]");
                        command.args(["-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", &format!("{WIDTH}x{HEIGHT}"), "-framerate", &FPS.to_string(), "-i", raw, "-i", &wav_path, "-filter_complex", &filter, "-map", "[v]", "-map", "2:a"]);
                    } else {
                        let filter = format!("{highlights},scale=1280:720");
                        command.args(["-i", &wav_path, "-vf", &filter, "-map", "0:v", "-map", "1:a"]);
                    }
                    command.args(["-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-c:a", "aac", "-b:a", "320k", "-shortest", &output_path]);
                    command
                        .status()
                        .map_err(|e| format!("could not run ffmpeg: {e}"))
                })
                .and_then(|status| {
                    status
                        .success()
                        .then_some(())
                        .ok_or_else(|| "ffmpeg could not create the audiovisual take".into())
                });
        let result = encode_result.and_then(|()| {
            let size = std::fs::metadata(&output_path)
                .map_err(|e| format!("could not inspect audiovisual take: {e}"))?
                .len();
            if size <= 1024 {
                let _ = std::fs::remove_file(&output_path);
                Err(format!(
                    "camera produced an empty MP4; audio take kept → {wav_path}"
                ))
            } else {
                Ok(output_path)
            }
        });
        if let Some(raw_path) = raw_path {
            let _ = std::fs::remove_file(raw_path);
        }
        let _ = std::fs::remove_file(carpet_path);
        if result.is_ok() {
            let _ = std::fs::remove_file(wav_path);
        }
        let _ = tx.send(result);
    });
    rx
}

#[cfg(not(test))]
fn first_video_device() -> Option<String> {
    let output = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-f",
            "avfoundation",
            "-list_devices",
            "true",
            "-i",
            "",
        ])
        .output()
        .ok()?;
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut in_video = false;
    for line in stderr.lines() {
        if line.contains("AVFoundation video devices") {
            in_video = true;
            continue;
        }
        if line.contains("AVFoundation audio devices") {
            break;
        }
        if in_video {
            if let Some(index) = line
                .rsplit_once('[')
                .and_then(|(_, tail)| tail.split_once(']'))
            {
                if index.0.chars().all(|c| c.is_ascii_digit()) {
                    return Some(index.0.to_string());
                }
            }
        }
    }
    None
}
