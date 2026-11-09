"""
mov_to_img_stack.py

Converts a video file (.mov or similar) to a TIFF image stack for DIC
software (e.g., ncorr).  Extracts frames at a user-specified sampling rate,
outputs grayscale 16-bit TIFFs, and writes a timestamps.csv alongside them
so that ncorr_batch_run can use real frame times.

Requirements:
    ffmpeg   (installed system-wide; preferred — fast, seeks natively)
    OR
    pip install opencv-python   (fallback if ffmpeg is not found)

Usage (interactive — GUI dialogs):
    python mov_to_img_stack.py

Usage (command-line — no GUI):
    python mov_to_img_stack.py --video path/to/video.mov \
                               --fps 5 \
                               --prefix frame \
                               [--grayscale]  [--max-frames N]
"""

import cv2
import os
import sys
import subprocess
import shutil
import argparse
import csv

# GUI imports (guarded so the script can run headlessly)
try:
    import tkinter as tk
    from tkinter import filedialog, simpledialog, messagebox
    _HAS_TK = True
except ImportError:
    _HAS_TK = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _has_ffmpeg():
    return shutil.which('ffmpeg') is not None


def _probe_video(video_path):
    """Return (native_fps, total_frames, width, height) using OpenCV."""
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")
    fps    = cap.get(cv2.CAP_PROP_FPS)
    frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    w      = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h      = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    return fps, frames, w, h


def _extract_ffmpeg(video_path, out_dir, prefix, sampling_rate, grayscale=True):
    """
    Extract frames using ffmpeg.  Much faster than OpenCV for sub-sampled
    output because ffmpeg can skip frames natively.

    Outputs:
        16-bit grayscale TIFFs  (if grayscale=True, recommended for DIC)
        OR 8-bit BGR TIFFs      (if grayscale=False)
    """
    pix_fmt = 'gray16le' if grayscale else 'bgr24'
    out_pattern = os.path.join(out_dir, f'{prefix}_%04d.tiff')

    cmd = [
        'ffmpeg', '-y',
        '-i', video_path,
        '-vf', f'fps={sampling_rate}',
        '-pix_fmt', pix_fmt,
        out_pattern
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f'ffmpeg failed:\n{result.stderr[-2000:]}')

    # Count output files
    tiffs = sorted(f for f in os.listdir(out_dir) if f.endswith('.tiff'))
    return len(tiffs)


def _extract_opencv(video_path, out_dir, prefix, sampling_rate, grayscale=True, max_frames=None):
    """
    Extract frames using OpenCV.  Reads every source frame, saves at the
    requested output rate.  Slower than ffmpeg but requires no external tools.
    """
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    native_fps   = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    frame_interval = native_fps / sampling_rate
    expected_out   = int(total_frames / frame_interval) + 1
    digits         = max(4, len(str(expected_out)))

    saved_count = 0
    next_target = 0.0
    for frame_idx in range(total_frames):
        ret, frame = cap.read()
        if not ret:
            break
        if frame_idx >= next_target:
            saved_count += 1
            if grayscale:
                frame = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                frame = frame.astype('uint16') * 257  # stretch 8-bit to 16-bit range
            filename = f'{prefix}_{saved_count:0{digits}d}.tiff'
            cv2.imwrite(os.path.join(out_dir, filename), frame)
            next_target += frame_interval
            if max_frames and saved_count >= max_frames:
                break
            if saved_count <= 5 or saved_count % 25 == 0:
                print(f'  frame {frame_idx:>6d}  ->  {filename}')
    cap.release()
    return saved_count


def _write_timestamps_csv(out_dir, prefix, n_frames, sampling_rate):
    """
    Write timestamps.csv alongside the TIFF stack.
    Each row: frame_index (0-based), time_s
    """
    csv_path = os.path.join(out_dir, 'timestamps.csv')
    with open(csv_path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['frame_index', 'time_s'])
        for i in range(n_frames):
            writer.writerow([i, i / sampling_rate])
    return csv_path


# ---------------------------------------------------------------------------
# Main extraction logic
# ---------------------------------------------------------------------------

def extract_frames(video_path, sampling_rate, prefix, grayscale=True, max_frames=None):
    """
    Extract frames from video_path at sampling_rate fps, saving TIFFs with
    the given prefix.  Returns (n_saved, out_dir).
    """
    native_fps, total_frames, w, h = _probe_video(video_path)

    if sampling_rate > native_fps:
        print(f"WARNING: Requested {sampling_rate:.3f} fps > video {native_fps:.3f} fps. "
              f"Clamping.")
        sampling_rate = native_fps

    video_dir  = os.path.dirname(os.path.abspath(video_path))
    video_stem = os.path.splitext(os.path.basename(video_path))[0]
    out_dir    = os.path.join(video_dir, f'{video_stem}-image_stack')
    os.makedirs(out_dir, exist_ok=True)

    duration_s = total_frames / native_fps if native_fps > 0 else 0
    expected   = int(duration_s * sampling_rate)

    print(f'\nVideo:          {os.path.basename(video_path)}')
    print(f'Native FPS:     {native_fps:.3f}')
    print(f'Total frames:   {total_frames}')
    print(f'Duration:       {duration_s:.2f} s')
    print(f'Resolution:     {w}x{h}')
    print(f'Output rate:    {sampling_rate:.3f} fps  (~{expected} output frames)')
    print(f'Grayscale 16b:  {grayscale}')
    print(f'Output folder:  {out_dir}\n')

    if _has_ffmpeg():
        print('Using ffmpeg for extraction...')
        saved_count = _extract_ffmpeg(video_path, out_dir, prefix, sampling_rate, grayscale)
    else:
        print('ffmpeg not found — falling back to OpenCV (slower)...')
        saved_count = _extract_opencv(video_path, out_dir, prefix, sampling_rate, grayscale, max_frames)

    # Write timestamps.csv
    ts_path = _write_timestamps_csv(out_dir, prefix, saved_count, sampling_rate)
    print(f'\nDone. {saved_count} images saved to:\n  {out_dir}')
    print(f'Timestamps:  {ts_path}')
    return saved_count, out_dir


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

def _get_user_inputs_gui():
    """Collect inputs via Tkinter dialogs."""
    root = tk.Tk()
    root.withdraw()

    video_path = filedialog.askopenfilename(
        title='Select video file',
        filetypes=[('Video files', '*.mov *.mp4 *.avi *.mkv'), ('All files', '*.*')]
    )
    if not video_path:
        messagebox.showerror('No file selected', 'No video file selected. Exiting.')
        sys.exit(0)

    sampling_rate = simpledialog.askfloat(
        'Sampling Rate',
        'Output sampling rate (images per second):\n(Must be <= video frame rate)',
        minvalue=0.001,
        initialvalue=5.0
    )
    if sampling_rate is None:
        messagebox.showerror('No input', 'No sampling rate entered. Exiting.')
        sys.exit(0)

    prefix = simpledialog.askstring(
        'File Prefix',
        'Enter image file prefix:\n'
        'Files will be saved as [prefix]_0001.tiff, [prefix]_0002.tiff, ...',
        initialvalue='frame'
    )
    if not prefix:
        messagebox.showerror('No input', 'No file prefix entered. Exiting.')
        sys.exit(0)

    root.destroy()
    return video_path, sampling_rate, prefix.strip()


def main():
    parser = argparse.ArgumentParser(
        description='Extract TIFF frames from a video for DIC analysis.',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument('--video',  '-v', help='Path to input video file.')
    parser.add_argument('--fps',    '-f', type=float, help='Output sampling rate (fps).')
    parser.add_argument('--prefix', '-p', default='frame', help='Output filename prefix.')
    parser.add_argument('--grayscale', action='store_true', default=True,
                        help='Output 16-bit grayscale TIFFs (recommended for DIC).')
    parser.add_argument('--color', action='store_false', dest='grayscale',
                        help='Output color TIFFs instead of grayscale.')
    parser.add_argument('--max-frames', type=int, default=None,
                        help='(OpenCV fallback only) Stop after N output frames.')
    args = parser.parse_args()

    if args.video and args.fps:
        video_path    = args.video
        sampling_rate = args.fps
        prefix        = args.prefix
        grayscale     = args.grayscale
    elif _HAS_TK:
        video_path, sampling_rate, prefix = _get_user_inputs_gui()
        grayscale = True
    else:
        parser.print_help()
        sys.exit(1)

    extract_frames(video_path, sampling_rate, prefix,
                   grayscale=grayscale, max_frames=args.max_frames)


if __name__ == '__main__':
    main()
