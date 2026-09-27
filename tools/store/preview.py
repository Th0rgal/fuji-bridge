"""App Preview: the three recorded segments crossfaded, 30 fps H.264, with the silent stereo track Apple wants.

    python3 tools/store/preview.py PLATFORM WIDTH HEIGHT [pad]

iPhone 886 × 1920 (fills and crops), iPad 1200 × 1600, Mac 1920 × 1080 with `pad`: the 16:10 window is
letterboxed on the app's dark (#16120E) instead of cropping its title bar. Output: build/store/final/.
"""
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
VIDEO, FINAL = REPO / "build/store/video", REPO / "build/store/final"
p, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
pad = len(sys.argv) > 4


def duration(f):
    return float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(f)]))


segments = [VIDEO / f"{p}-{n}.mp4" for n in ("import", "card", "viewer")]
d = [duration(s) for s in segments]
if pad:
    f = f"fps=30,scale=-2:{H},pad={W}:{H}:(ow-iw)/2:0:color=0x16120e,setsar=1,format=yuv420p"
else:
    f = f"fps=30,scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},setsar=1,format=yuv420p"
graph = (f"[0:v]{f}[a];[1:v]{f}[b];[2:v]{f}[c];"
         f"[a][b]xfade=transition=fade:duration=0.5:offset={d[0] - 0.5:.2f}[ab];"
         f"[ab][c]xfade=transition=fade:duration=0.5:offset={d[0] + d[1] - 1.0:.2f}[v]")
out = FINAL / f"{p}-preview.mp4"
FINAL.mkdir(parents=True, exist_ok=True)
subprocess.check_call(["ffmpeg", "-loglevel", "error", "-y"] + sum([["-i", str(s)] for s in segments], []) + [
    "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
    "-filter_complex", graph, "-map", "[v]", "-map", "3:a", "-shortest",
    "-c:v", "libx264", "-profile:v", "high", "-level", "4.2", "-pix_fmt", "yuv420p", "-b:v", "10M", "-r", "30",
    "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", str(out)])
print(out.relative_to(REPO), f"{sum(d) - 1:.1f} s")  # Apple accepts 15 to 30 s
