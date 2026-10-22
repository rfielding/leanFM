package server

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/gif"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"leanfm/goserver/game"
)

// Requirement ref: R5. Export takes actions, never trusted board screenshots.
// Every frame is independently produced by replaying the Go rules engine.
type ExportRequest struct {
	Size     int           `json:"size"`
	Players  int           `json:"players"`
	MaxTurns int           `json:"max_turns"`
	Actions  []game.Action `json:"actions"`
}

func ReplayExport(request ExportRequest) ([]game.Position, error) {
	if len(request.Actions) > 200 {
		return nil, fmt.Errorf("GIF export is bounded to 200 moves")
	}
	state, err := game.New(request.Size, request.Players, request.MaxTurns)
	if err != nil {
		return nil, err
	}
	frames := []game.Position{state}
	for i, action := range request.Actions {
		state, err = game.Apply(state, action)
		if err != nil {
			return nil, fmt.Errorf("export move %d: %w", i+1, err)
		}
		frames = append(frames, state)
	}
	return frames, nil
}

var palette = color.Palette{color.RGBA{17, 24, 39, 255}, color.RGBA{221, 182, 118, 255}, color.RGBA{30, 30, 30, 255}, color.RGBA{248, 248, 248, 255}, color.RGBA{205, 57, 67, 255}, color.RGBA{45, 118, 215, 255}, color.RGBA{34, 151, 98, 255}, color.RGBA{234, 181, 27, 255}, color.RGBA{113, 128, 150, 255}}
var digits = []string{"111101101101111", "010110010010111", "111001111100111", "111001111001111", "101101111001001", "111100111001111", "111100111101111", "111001001001001", "111101111101111", "111101111001111"}

func number(img *image.Paletted, x, y, value int) {
	if value < 0 {
		draw.Draw(img, image.Rect(x, y+6, x+6, y+8), image.NewUniform(palette[3]), image.Point{}, draw.Src)
		x += 9
		value = -value
	}
	for _, d := range fmt.Sprint(value) {
		for i, pixel := range digits[int(d-'0')] {
			if pixel == '1' {
				draw.Draw(img, image.Rect(x+(i%3)*3, y+(i/3)*3, x+(i%3)*3+3, y+(i/3)*3+3), image.NewUniform(palette[3]), image.Point{}, draw.Src)
			}
		}
		x += 12
	}
}
func circle(img *image.Paletted, x, y, r int, c uint8) {
	for dy := -r; dy <= r; dy++ {
		for dx := -r; dx <= r; dx++ {
			if dx*dx+dy*dy <= r*r {
				img.SetColorIndex(x+dx, y+dy, c)
			}
		}
	}
}
func RenderFrame(s game.Position) *image.Paletted {
	img := image.NewPaletted(image.Rect(0, 0, 512, 610), palette)
	draw.Draw(img, image.Rect(12, 12, 500, 500), image.NewUniform(palette[8]), image.Point{}, draw.Src)
	draw.Draw(img, image.Rect(20, 20, 492, 492), image.NewUniform(palette[1]), image.Point{}, draw.Src)
	step := 432 / (s.Size - 1)
	for i := 0; i < s.Size; i++ {
		p := 40 + i*step
		draw.Draw(img, image.Rect(40, p, 40+(s.Size-1)*step+1, p+1), image.NewUniform(palette[2]), image.Point{}, draw.Src)
		draw.Draw(img, image.Rect(p, 40, p+1, 40+(s.Size-1)*step+1), image.NewUniform(palette[2]), image.Point{}, draw.Src)
	}
	for point, stone := range s.Board {
		if stone == 0 {
			continue
		}
		x, y := 40+(point%s.Size)*step, 40+(point/s.Size)*step
		circle(img, x, y, step*2/5, uint8(stone+1))
		if point == s.Last {
			c := uint8(3)
			if stone == 2 || stone == 6 {
				c = 2
			}
			circle(img, x, y, 3, c)
		}
	}
	number(img, 24, 512, s.Ply)
	number(img, 100, 512, s.Turn+1)
	scores := game.Score(s)
	for p := 0; p < s.Players; p++ {
		x := 24 + (p%3)*165
		y := 550 + (p/3)*30
		circle(img, x, y+6, 8, uint8(p+2))
		number(img, x+15, y, s.Losses[p])
		number(img, x+70, y, scores.Total[p])
	}
	return img
}

func EncodeGIF(frames []game.Position) ([]byte, error) {
	animation := &gif.GIF{LoopCount: 0}
	for i, frame := range frames {
		animation.Image = append(animation.Image, RenderFrame(frame))
		delay := 30
		if i == len(frames)-1 {
			delay = 150
		}
		animation.Delay = append(animation.Delay, delay)
	}
	var buffer bytes.Buffer
	err := gif.EncodeAll(&buffer, animation)
	return buffer.Bytes(), err
}

func (s *Server) export(w http.ResponseWriter, r *http.Request) {
	// Serialize exports as well as game mutations to bound concurrent image memory.
	s.mu.Lock()
	defer s.mu.Unlock()
	start := Event{ID: nonce(), PriorIDs: []string{}, Session: "local-export", Task: "export_gif", Src: "Client", Dst: "GoServer", Message: "ExportGIF", TimeMS: s.Now().UnixMilli()}
	trace := func(name string) {
		end := Event{ID: nonce(), CauseID: start.ID, PriorIDs: []string{start.ID}, Session: start.Session, Task: start.Task, Src: "GoServer", Dst: "Client", Message: name, TimeMS: s.Now().UnixMilli()}
		body, _ := json.Marshal([]Event{start, end})
		w.Header().Set("X-GoServer-Trace", base64.StdEncoding.EncodeToString(body))
	}
	fail := func(status int, message string) { trace("ErrorEvent"); http.Error(w, message, status) }
	failed := func(operation string, err error) {
		log.Printf("request_id=%s task=export_gif operation=%q error=%q", start.ID, operation, err.Error())
		fail(500, operation+" failed; no artifact was claimed. Diagnostic request_id="+start.ID)
	}
	files, err := os.ReadDir(s.root)
	if err != nil {
		failed("export directory read", err)
		return
	}
	count := 0
	for _, file := range files {
		if filepath.Ext(file.Name()) == ".gif" {
			count++
		}
	}
	if count >= 64 {
		fail(429, "64-export storage bound reached")
		return
	}
	var request ExportRequest
	if err := decode(w, r, &request); err != nil {
		fail(400, err.Error())
		return
	}
	frames, err := ReplayExport(request)
	if err != nil {
		fail(422, err.Error())
		return
	}
	body, err := EncodeGIF(frames)
	if err != nil {
		failed("GIF encoding", err)
		return
	}
	name := "export-" + nonce() + ".gif"
	if err = os.WriteFile(filepath.Join(s.root, name), body, 0600); err != nil {
		failed("GIF persistence", err)
		return
	}
	w.Header().Set("Content-Type", "image/gif")
	w.Header().Set("Content-Disposition", `attachment; filename="goserver-selected-path.gif"`)
	w.Header().Set("X-GoServer-Artifact", filepath.Base(s.root)+"/"+name)
	w.Header().Set("X-GoServer-Final-Ply", fmt.Sprint(frames[len(frames)-1].Ply))
	trace("GIFCreated")
	w.Write(body)
}
