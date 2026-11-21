use crossbeam_channel::{bounded, Receiver, Sender};
use std::fs::File;
use std::io::{BufWriter, Seek, SeekFrom, Write};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn start(
    sample_rate: u32,
) -> Result<(Sender<[f32; 2]>, Receiver<Result<String, String>>, String), String> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs();
    let path = format!("maqam-take-{stamp}.wav");
    let file = File::create(&path).map_err(|e| format!("could not create {path}: {e}"))?;
    let (sample_tx, sample_rx) = bounded::<[f32; 2]>(sample_rate as usize * 4);
    let (result_tx, result_rx) = bounded(1);
    let result_path = path.clone();
    std::thread::spawn(move || {
        let result = write_take(file, sample_rate, sample_rx).map(|()| result_path);
        let _ = result_tx.send(result);
    });
    Ok((sample_tx, result_rx, path))
}

fn write_take(file: File, sample_rate: u32, rx: Receiver<[f32; 2]>) -> Result<(), String> {
    let mut out = BufWriter::new(file);
    write_header(&mut out, sample_rate, 0).map_err(|e| e.to_string())?;
    let mut frames = 0u32;
    while let Ok(frame) = rx.recv() {
        for sample in frame {
            let value = (sample.clamp(-1.0, 1.0) * 8_388_607.0).round() as i32;
            let bytes = value.to_le_bytes();
            out.write_all(&bytes[..3]).map_err(|e| e.to_string())?;
        }
        frames = frames.saturating_add(1);
    }
    let data_bytes = frames.saturating_mul(6);
    out.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    write_header(&mut out, sample_rate, data_bytes).map_err(|e| e.to_string())?;
    out.flush().map_err(|e| e.to_string())
}

fn write_header(out: &mut impl Write, sample_rate: u32, data_bytes: u32) -> std::io::Result<()> {
    out.write_all(b"RIFF")?;
    out.write_all(&data_bytes.saturating_add(36).to_le_bytes())?;
    out.write_all(b"WAVEfmt ")?;
    out.write_all(&16u32.to_le_bytes())?;
    out.write_all(&1u16.to_le_bytes())?;
    out.write_all(&2u16.to_le_bytes())?;
    out.write_all(&sample_rate.to_le_bytes())?;
    out.write_all(&sample_rate.saturating_mul(6).to_le_bytes())?;
    out.write_all(&6u16.to_le_bytes())?;
    out.write_all(&24u16.to_le_bytes())?;
    out.write_all(b"data")?;
    out.write_all(&data_bytes.to_le_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_header_describes_stereo_24_bit_pcm() {
        let mut bytes = Vec::new();
        write_header(&mut bytes, 48_000, 600).unwrap();
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(u16::from_le_bytes([bytes[22], bytes[23]]), 2);
        assert_eq!(u16::from_le_bytes([bytes[34], bytes[35]]), 24);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 600);
    }
}
