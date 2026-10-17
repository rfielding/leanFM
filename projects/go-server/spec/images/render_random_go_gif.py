from __future__ import annotations

import random
import sys
from collections import deque
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

N = 9
EMPTY, BLACK, WHITE, RED = range(4)
COLORS = {BLACK: "#151515", WHITE: "#f5f5f2", RED: "#c62828"}
NAMES = {BLACK: "Black", WHITE: "White", RED: "Red"}
RNG = random.Random(20261017)


def neighbors(row: int, col: int):
    for dr, dc in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        rr, cc = row + dr, col + dc
        if 0 <= rr < N and 0 <= cc < N:
            yield rr, cc


def group(board, row: int, col: int):
    color = board[row][col]
    found, pending = set(), deque([(row, col)])
    while pending:
        point = pending.pop()
        if point in found:
            continue
        found.add(point)
        for rr, cc in neighbors(*point):
            if board[rr][cc] == color and (rr, cc) not in found:
                pending.append((rr, cc))
    return found


def liberties(board, stones):
    return {(rr, cc) for row, col in stones for rr, cc in neighbors(row, col) if board[rr][cc] == EMPTY}


def place(board, row: int, col: int, color: int):
    if board[row][col] != EMPTY:
        return None, 0
    trial = [line[:] for line in board]
    trial[row][col] = color
    captured = 0
    checked = set()
    for rr, cc in neighbors(row, col):
        if trial[rr][cc] in (EMPTY, color) or (rr, cc) in checked:
            continue
        stones = group(trial, rr, cc)
        checked |= stones
        if not liberties(trial, stones):
            captured += len(stones)
            for sr, sc in stones:
                trial[sr][sc] = EMPTY
    if not liberties(trial, group(trial, row, col)):
        return None, 0
    return trial, captured


def draw_frame(board, move: int, message: str):
    image = Image.new("RGB", (420, 480), "#0b1821")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((18, 58, 402, 442), radius=10, fill="#ddb77f", outline="#efd09d", width=2)
    start, step = 50, 40
    for index in range(N):
        point = start + index * step
        draw.line((start, point + 40, start + step * (N - 1), point + 40), fill="#59452f", width=2)
        draw.line((point, start + 40, point, start + 40 + step * (N - 1)), fill="#59452f", width=2)
    for row in range(N):
        for col in range(N):
            color = board[row][col]
            if color == EMPTY:
                continue
            x, y, radius = start + col * step, start + 40 + row * step, 18
            draw.ellipse((x - radius + 2, y - radius + 4, x + radius + 2, y + radius + 4), fill="#00000055")
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=COLORS[color], outline="#343434", width=2)
    draw.text((20, 14), "Random three-player Go · 8 moves/second", fill="#eef7fc")
    draw.text((20, 34), f"Move {move}: {message}", fill="#9fd5f5")
    return image


def main(output: Path):
    board = [[EMPTY] * N for _ in range(N)]
    frames = [draw_frame(board, 0, "empty board")]
    player = BLACK
    move = 0
    for _ in range(112):
        candidates = [(row, col) for row in range(N) for col in range(N) if board[row][col] == EMPTY]
        RNG.shuffle(candidates)
        chosen = None
        for row, col in candidates:
            trial, captured = place(board, row, col, player)
            if trial is not None:
                chosen = row, col, trial, captured
                break
        if chosen is None:
            player = player % 3 + 1
            continue
        row, col, board, captured = chosen
        move += 1
        note = f"{NAMES[player]} at ({col + 1},{row + 1})"
        if captured:
            note += f" · captured {captured}"
        frames.append(draw_frame(board, move, note))
        player = player % 3 + 1

    # Finish the requested loop on a visibly cleared board. Captured groups disappear
    # first; any survivors are removed in randomized groups as the demonstration ends.
    while any(EMPTY != value for line in board for value in line):
        occupied = [(row, col) for row in range(N) for col in range(N) if board[row][col] != EMPTY]
        row, col = RNG.choice(occupied)
        stones = group(board, row, col)
        for rr, cc in stones:
            board[rr][cc] = EMPTY
        move += 1
        frames.append(draw_frame(board, move, f"clearing {len(stones)} {NAMES.get(player, 'surviving')} stone(s)"))

    frames.extend([draw_frame(board, move, "board clear — restarting")] * 8)
    output.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(output, save_all=True, append_images=frames[1:], duration=125, loop=0, optimize=True, disposal=2)


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "random-play-8x.gif"))
