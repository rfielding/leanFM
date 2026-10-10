# LeanFM overview video

`leanfm-overview.mp4` is a silent, dark-mode Manim overview of LeanFM Software
Engineering, with its main emphasis on applying CTL to event-stream futures.

The scene data and provenance live in `overview.json`.  Before rendering,
`scripts/validate_video_overview.py` checks the CTL vocabulary, dualities, and
the accepted `book.overview_video` requirement against the Lean sources.

Render the video from the project root with:

```sh
make video
```

Render local Piper narration and mux it into the video with:

```sh
make video-narrated
```

The scene-local narration source is `narration.json`; the generated voice is explicitly a
synthetic narrator. Piper's voice model is downloaded into the project-local,
ignored video environment and does not use an API key or metered service.

The default renderer is the project-local `video/.conda/bin/python`.  Override
`VIDEO_PYTHON` when Manim is installed elsewhere.
