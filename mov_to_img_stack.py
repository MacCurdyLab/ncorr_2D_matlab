"""
mov_to_image_stack.py

Converts a video file (.mov or similar) to a stack of images
for use with DIC software (e.g., nCorr). Extracts frames at a
user-specified sampling rate and saves them to a subfolder.

Requirements:
    pip install opencv-python
"""

import cv2
import os
import sys
import tkinter as tk
from tkinter import filedialog, simpledialog, messagebox


def get_user_inputs():
    root = tk.Tk()
    root.withdraw()  # Hide the root window

    # --- Select video file ---
    video_path = filedialog.askopenfilename(
        title="Select video file",
        filetypes=[
            ("Video files", "*.mov *.mp4 *.avi *.mkv"),
            ("All files", "*.*"),
        ],
    )
    if not video_path:
        messagebox.showerror("No file selected", "No video file was selected. Exiting.")
        sys.exit(0)

    # --- Sampling rate ---
    sampling_rate = simpledialog.askfloat(
        "Sampling Rate",
        "Output sampling rate (images per second):\n"
        "(Must be ≤ video frame rate)",
        minvalue=0.001,
    )
    if sampling_rate is None:
        messagebox.showerror("No input", "No sampling rate entered. Exiting.")
        sys.exit(0)

    # --- File prefix ---
    prefix = simpledialog.askstring(
        "File Prefix",
        "Enter image file prefix:\n"
        "Files will be saved as [prefix]_001.tiff, [prefix]_002.tiff, …",
        initialvalue="frame",
    )
    if not prefix:
        messagebox.showerror("No input", "No file prefix entered. Exiting.")
        sys.exit(0)

    root.destroy()
    return video_path, sampling_rate, prefix.strip()


def extract_frames(video_path, sampling_rate, prefix):
    # Open the video
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"ERROR: Could not open video file: {video_path}")
        sys.exit(1)

    native_fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    duration_s = total_frames / native_fps if native_fps > 0 else 0

    if sampling_rate > native_fps:
        print(
            f"WARNING: Requested sampling rate ({sampling_rate:.3f} fps) exceeds "
            f"video frame rate ({native_fps:.3f} fps). "
            f"Clamping to video frame rate."
        )
        sampling_rate = native_fps

    # Interval between extracted frames (in original frame indices)
    frame_interval = native_fps / sampling_rate  # e.g. 30 fps / 5 fps = every 6th frame

    # Build output directory: [video_dir]/[video_stem]-image_stack
    video_dir = os.path.dirname(os.path.abspath(video_path))
    video_stem = os.path.splitext(os.path.basename(video_path))[0]
    out_dir = os.path.join(video_dir, f"{video_stem}-image_stack")
    os.makedirs(out_dir, exist_ok=True)

    print(f"\nVideo:          {os.path.basename(video_path)}")
    print(f"Native FPS:     {native_fps:.3f}")
    print(f"Total frames:   {total_frames}")
    print(f"Duration:       {duration_s:.2f} s")
    print(f"Output rate:    {sampling_rate:.3f} fps  (1 frame every {frame_interval:.2f} source frames)")
    print(f"Output folder:  {out_dir}\n")

    saved_count = 0
    next_target = 0.0  # Next source frame index to capture

    for frame_idx in range(total_frames):
        ret, frame = cap.read()
        if not ret:
            break

        if frame_idx >= next_target:
            saved_count += 1
            # Zero-pad to fit all expected images; minimum 3 digits
            digits = max(3, len(str(int(total_frames / frame_interval) + 1)))
            filename = f"{prefix}_{saved_count:0{digits}d}.tiff"
            out_path = os.path.join(out_dir, filename)
            cv2.imwrite(out_path, frame)

            if saved_count <= 5 or saved_count % 10 == 0:
                print(f"  Saved frame {frame_idx:>6d}  →  {filename}")

            next_target += frame_interval

    cap.release()
    print(f"\nDone. {saved_count} images saved to:\n  {out_dir}")
    return saved_count, out_dir


def main():
    video_path, sampling_rate, prefix = get_user_inputs()
    extract_frames(video_path, sampling_rate, prefix)


if __name__ == "__main__":
    main()