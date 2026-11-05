#!/usr/bin/env python3
"""
DIC Camera Calibration Script
Canon EOS 7D Mark II + Canon 100mm Macro f/2.8 L IS USM
For use with ncorr DIC software

Performs two calibrations:
  1. Lens distortion  — checkerboard method → k1 coefficient for ncorr
  2. Scale factor     — interactive click tool → mm/pixel for ncorr

Usage:
  python dic_calibration.py                   # run full calibration
  python dic_calibration.py --extract-only    # just pull frames from video
  python dic_calibration.py --distortion-only # skip scale factor step
  python dic_calibration.py --scale-only      # skip distortion step (loads existing JSON)

Dependencies:
  pip install opencv-python numpy matplotlib
"""

import cv2
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import json
import os
import glob
import argparse
from pathlib import Path
from datetime import date


# ================================================================
#  CONFIGURATION  —  edit this block before running
# ================================================================

# --- Checkerboard target ---
# Count INNER corners (not squares). A 10x7 square board has 9x6 inner corners.
CHECKERBOARD_COLS = 9        # inner corners along the long axis
CHECKERBOARD_ROWS = 6        # inner corners along the short axis
SQUARE_SIZE_MM    = 5.0      # physical size of each square in mm
                             # Print at exact scale; measure a few squares with calipers to verify.

# --- Paths ---
# Put checkerboard frames here (JPG/PNG/TIFF).
# Shoot ~20 images: vary position, tilt (±30°), and rotation across the frame.
CALIB_IMAGES_DIR  = "./calibration_images"

# Single image of a calibration target at the EXACT specimen working distance.
# Options: stage micrometer, precision-machined block, calibrated ruler, drill blank.
SCALE_IMAGE_PATH  = "./scale_target.jpg"

# Where to save / load calibration results.
OUTPUT_JSON       = "./dic_calibration.json"

# --- Camera / acquisition info (metadata only, written to JSON) ---
CAMERA_NOTES = "Canon EOS 7D Mk II | 100mm Macro f/2.8 L IS | 1/400s f/8 ISO100 | 59.94fps video"

# ================================================================


# ----------------------------------------------------------------
#  UTILITY: Frame extraction from calibration video
# ----------------------------------------------------------------

def extract_frames(video_path: str, output_dir: str, every_n: int = 15) -> int:
    """
    Pull frames from a calibration video at a fixed interval.

    For checkerboard calibration you want ~15-25 well-distributed frames,
    not consecutive ones (they're nearly identical). every_n=15 at 59.94fps
    gives one frame every ~0.25 s — enough variety without redundancy.

    Args:
        video_path:  Path to the .MOV / .MP4 calibration recording.
        output_dir:  Directory to write extracted JPEG frames.
        every_n:     Keep one frame out of every N.

    Returns:
        Number of frames written.
    """
    Path(output_dir).mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise FileNotFoundError(f"Cannot open video: {video_path}")

    total  = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps    = cap.get(cv2.CAP_PROP_FPS)
    print(f"Video: {total} frames at {fps:.2f} fps  "
          f"({total/fps:.1f} s)  →  keeping 1 of every {every_n}")

    saved = 0
    for frame_idx in range(total):
        ret, frame = cap.read()
        if not ret:
            break
        if frame_idx % every_n == 0:
            out = os.path.join(output_dir, f"calib_{saved:04d}.jpg")
            cv2.imwrite(out, frame, [cv2.IMWRITE_JPEG_QUALITY, 97])
            saved += 1

    cap.release()
    print(f"Extracted {saved} frames  →  {output_dir}")
    return saved


# ----------------------------------------------------------------
#  STEP 1: Lens distortion calibration
# ----------------------------------------------------------------

def calibrate_distortion(images_dir: str,
                          cols: int,
                          rows: int,
                          square_mm: float) -> tuple:
    """
    Solve for lens distortion coefficients using a flat checkerboard target.

    OpenCV's calibrateCamera() fits the Brown-Conrady model:
        r_corrected = r * (1 + k1*r^2 + k2*r^4 + k3*r^6)
        (plus tangential terms p1, p2)

    ncorr uses only the first radial term k1.

    Args:
        images_dir: Folder containing checkerboard images.
        cols:       Inner corner count, horizontal.
        rows:       Inner corner count, vertical.
        square_mm:  Physical square size in mm.

    Returns:
        (camera_matrix, dist_coeffs, rms_error, good_images)
        dist_coeffs = [k1, k2, p1, p2, k3]
    """
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 50, 1e-6)
    board_size = (cols, rows)

    # World coordinates for one checkerboard view (z=0 plane)
    objp = np.zeros((rows * cols, 3), np.float32)
    objp[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2) * square_mm

    obj_points = []   # Replicated per successful image
    img_points = []   # 2-D corner locations in each image
    good_images = []

    # Collect all image files
    exts = ["*.jpg", "*.jpeg", "*.png", "*.tif", "*.tiff",
            "*.JPG", "*.JPEG", "*.PNG", "*.TIF", "*.TIFF"]
    files = []
    for ext in exts:
        files.extend(glob.glob(os.path.join(images_dir, ext)))
    files = sorted(set(files))

    if not files:
        raise FileNotFoundError(
            f"No images found in '{images_dir}'.\n"
            f"Place checkerboard frames there, or run with --extract-only first."
        )

    img_shape = None
    print(f"\nSearching {len(files)} images for a {cols}×{rows} inner-corner grid …\n")

    for path in files:
        img  = cv2.imread(path)
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        img_shape = gray.shape[::-1]  # (W, H)

        # Coarse detection
        found, corners = cv2.findChessboardCorners(
            gray, board_size,
            flags=(cv2.CALIB_CB_ADAPTIVE_THRESH |
                   cv2.CALIB_CB_NORMALIZE_IMAGE  |
                   cv2.CALIB_CB_FAST_CHECK)
        )

        if found:
            # Refine to sub-pixel accuracy
            corners_refined = cv2.cornerSubPix(
                gray, corners, winSize=(11, 11), zeroZone=(-1, -1), criteria=criteria
            )
            obj_points.append(objp)
            img_points.append(corners_refined)
            good_images.append(path)
            print(f"  ✓  {os.path.basename(path)}")
        else:
            print(f"  ✗  {os.path.basename(path)}  (corners not found — "
                  f"check board size config or image quality)")

    n_good = len(good_images)
    print(f"\n{n_good} / {len(files)} images accepted for calibration.")

    if n_good < 10:
        print("  WARNING: < 10 images. Add more varied checkerboard shots for a reliable result.")
    if n_good < 3:
        raise RuntimeError("Need at least 3 successful detections. Cannot calibrate.")

    # --- Solve ---
    rms, K, dist, rvecs, tvecs = cv2.calibrateCamera(
        obj_points, img_points, img_shape, None, None,
        flags=cv2.CALIB_RATIONAL_MODEL  # fits k4,k5,k6 but we still report k1-k3
    )
    # dist layout from CALIB_RATIONAL_MODEL: [k1,k2,p1,p2,k3,k4,k5,k6]
    # Without the flag:                       [k1,k2,p1,p2,k3]
    # Either way dist[0] = k1
    d = dist.ravel()

    # --- Per-image reprojection errors (useful for spotting bad frames) ---
    per_image_errors = []
    for i, (op, ip, rv, tv) in enumerate(zip(obj_points, img_points, rvecs, tvecs)):
        projected, _ = cv2.projectPoints(op, rv, tv, K, dist)
        err = cv2.norm(ip, projected, cv2.NORM_L2) / np.sqrt(len(ip))
        per_image_errors.append((os.path.basename(good_images[i]), err))

    # --- Report ---
    print("\n" + "─"*55)
    print("  LENS DISTORTION CALIBRATION RESULTS")
    print("─"*55)
    print(f"  RMS reprojection error : {rms:.4f} px")
    print(f"    (< 0.5 px = excellent │ 0.5–1.0 = acceptable │ > 1.0 = re-shoot)")
    print()
    print(f"  Distortion coefficients (Brown-Conrady):")
    print(f"    k1  =  {d[0]:+.8f}   ← enter this into ncorr")
    print(f"    k2  =  {d[1]:+.8f}")
    print(f"    p1  =  {d[2]:+.8f}")
    print(f"    p2  =  {d[3]:+.8f}")
    if len(d) > 4:
        print(f"    k3  =  {d[4]:+.8f}")
    print()
    print(f"  Camera intrinsics:")
    print(f"    fx  =  {K[0,0]:.2f} px   fy  =  {K[1,1]:.2f} px")
    print(f"    cx  =  {K[0,2]:.2f} px   cy  =  {K[1,2]:.2f} px")
    print()
    print("  Per-image reprojection errors:")
    for fname, err in sorted(per_image_errors, key=lambda x: -x[1]):
        flag = "  ← consider removing" if err > 1.0 else ""
        print(f"    {fname:35s}  {err:.4f} px{flag}")
    print("─"*55)

    _plot_distortion_check(good_images[0], K, dist)
    _plot_reprojection_errors(per_image_errors)

    return K, dist, rms, good_images


def _plot_distortion_check(image_path: str, K, dist):
    """Side-by-side before/after undistortion. Save PNG and show."""
    img = cv2.imread(image_path)
    orig_rgb  = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    undist    = cv2.undistort(img, K, dist)
    undist_rgb = cv2.cvtColor(undist, cv2.COLOR_BGR2RGB)

    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    for ax, im, title in zip(
        axes,
        [orig_rgb, undist_rgb],
        ["Original (distorted)", "Undistorted (k1 applied)"]
    ):
        ax.imshow(im)
        ax.set_title(title, fontsize=12, fontweight='bold')
        ax.axis('off')

    fig.suptitle(
        "Distortion check — straight lines in reality should appear straight after correction\n"
        f"({os.path.basename(image_path)})",
        fontsize=11
    )
    plt.tight_layout()
    out = "distortion_check.png"
    plt.savefig(out, dpi=150, bbox_inches='tight')
    plt.show()
    print(f"  Saved: {out}")


def _plot_reprojection_errors(per_image_errors: list):
    """Bar chart of per-image reprojection errors."""
    names  = [e[0] for e in per_image_errors]
    errors = [e[1] for e in per_image_errors]
    colors = ['#d62728' if e > 1.0 else '#2ca02c' if e < 0.5 else '#ff7f0e'
              for e in errors]

    fig, ax = plt.subplots(figsize=(max(8, len(names)*0.5), 4))
    bars = ax.bar(range(len(names)), errors, color=colors, edgecolor='white', linewidth=0.5)
    ax.axhline(0.5, color='#2ca02c', linewidth=1.5, linestyle='--', label='0.5 px (excellent)')
    ax.axhline(1.0, color='#d62728', linewidth=1.5, linestyle='--', label='1.0 px (threshold)')
    ax.set_xticks(range(len(names)))
    ax.set_xticklabels(names, rotation=45, ha='right', fontsize=8)
    ax.set_ylabel("Reprojection error (px)")
    ax.set_title("Per-image reprojection errors\n(red bars > 1 px: consider excluding those frames)")
    ax.legend()
    plt.tight_layout()
    out = "reprojection_errors.png"
    plt.savefig(out, dpi=150, bbox_inches='tight')
    plt.show()
    print(f"  Saved: {out}")


# ----------------------------------------------------------------
#  STEP 2: Pixel-to-mm scale factor (interactive)
# ----------------------------------------------------------------

def calibrate_scale(image_path: str,
                    K=None,
                    dist=None) -> tuple:
    """
    Interactive scale factor calibration.

    Displays the (optionally undistorted) calibration target image.
    User clicks two endpoints of a known-length feature; the script
    asks for the physical length and computes mm/pixel.

    For best accuracy:
      - Use the actual scale target at the EXACT specimen working distance.
      - Measure the known feature with calipers before imaging.
      - Click near the center of the feature ends, not at the image edges
        (residual distortion is smallest at the principal point).

    Args:
        image_path:  Path to scale target image.
        K, dist:     Camera matrix and distortion coefficients from Step 1.
                     If provided, the image is undistorted before measurement.

    Returns:
        (mm_per_pixel, pixels_per_mm)
    """
    img = cv2.imread(image_path)
    if img is None:
        raise FileNotFoundError(f"Cannot load scale image: {image_path}")

    if K is not None and dist is not None:
        img = cv2.undistort(img, K, dist)
        distortion_note = "undistorted"
    else:
        distortion_note = "RAW — distortion not corrected"

    img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

    print(f"\nScale calibration image loaded ({distortion_note}).")
    print("Instructions:")
    print("  1. Click on one end of a feature of KNOWN physical length.")
    print("  2. Click on the other end.")
    print("  3. Close the window when prompted.")
    print("  4. Enter the known length in mm at the terminal prompt.\n")

    clicks = []

    fig, ax = plt.subplots(figsize=(13, 8))
    ax.imshow(img_rgb, cmap='gray' if img_rgb.ndim == 2 else None)
    ax.set_title(
        f"Scale calibration  [{distortion_note}]\n"
        "→  Click the two endpoints of your calibration feature",
        fontsize=11
    )

    dot_artist   = ax.scatter([], [], c='#e74c3c', s=80, zorder=6)
    line_artist, = ax.plot([], [], color='#e74c3c', linewidth=2, zorder=5)
    text_artist  = ax.text(0, 0, '', color='#e74c3c', fontsize=11,
                           ha='center', va='bottom',
                           bbox=dict(facecolor='white', alpha=0.75, boxstyle='round,pad=0.3'),
                           visible=False, zorder=7)

    def on_click(event):
        if event.inaxes != ax or event.button != 1 or len(clicks) >= 2:
            return
        x, y = event.xdata, event.ydata
        clicks.append((x, y))

        xs = [c[0] for c in clicks]
        ys = [c[1] for c in clicks]
        dot_artist.set_offsets(np.c_[xs, ys])

        if len(clicks) == 2:
            line_artist.set_data(xs, ys)
            px_dist = np.hypot(xs[1] - xs[0], ys[1] - ys[0])
            mid_x, mid_y = np.mean(xs), np.mean(ys)
            text_artist.set_position((mid_x, mid_y - 15))
            text_artist.set_text(f"{px_dist:.1f} px\n← close window and enter mm")
            text_artist.set_visible(True)
            ax.set_title("Two points selected — close this window to enter the known length",
                         fontsize=11, color='#27ae60')

        fig.canvas.draw_idle()

    fig.canvas.mpl_connect('button_press_event', on_click)
    plt.tight_layout()
    plt.show()

    if len(clicks) < 2:
        raise RuntimeError("Fewer than 2 clicks recorded. Run again and click both endpoints.")

    px_dist = np.hypot(clicks[1][0] - clicks[0][0], clicks[1][1] - clicks[0][1])
    print(f"  Measured pixel distance: {px_dist:.4f} px")

    while True:
        try:
            known_mm = float(input("  Enter the known physical length of that feature (mm): "))
            if known_mm <= 0:
                print("  Must be a positive number.")
                continue
            break
        except ValueError:
            print("  Please enter a numeric value.")

    mm_per_px  = known_mm / px_dist
    px_per_mm  = px_dist / known_mm

    print()
    print("─"*55)
    print("  SCALE FACTOR RESULTS")
    print("─"*55)
    print(f"  Pixel distance measured : {px_dist:.4f} px")
    print(f"  Known physical length   : {known_mm:.4f} mm")
    print(f"  Scale factor            : {mm_per_px:.6f} mm/pixel")
    print(f"                          : {mm_per_px*1000:.4f} µm/pixel")
    print(f"                          : {px_per_mm:.4f} pixels/mm")
    print("─"*55)

    _plot_scale_result(img_rgb, clicks, px_dist, known_mm, mm_per_px, distortion_note)

    return mm_per_px, px_per_mm


def _plot_scale_result(img_rgb, clicks, px_dist, known_mm, mm_per_px, note):
    """Annotated image showing the measured feature."""
    fig, ax = plt.subplots(figsize=(13, 8))
    ax.imshow(img_rgb)
    xs = [clicks[0][0], clicks[1][0]]
    ys = [clicks[0][1], clicks[1][1]]
    ax.plot(xs, ys, color='#e74c3c', linewidth=2.5, zorder=5)
    ax.scatter(xs, ys, color='#e74c3c', s=80, zorder=6)
    mid_x, mid_y = np.mean(xs), np.mean(ys)
    ax.annotate(
        f"{known_mm:.4f} mm\n({px_dist:.1f} px)\n→ {mm_per_px:.5f} mm/px",
        xy=(mid_x, mid_y), xytext=(mid_x + 20, mid_y - 40),
        fontsize=11, color='#e74c3c',
        arrowprops=dict(arrowstyle='->', color='#e74c3c'),
        bbox=dict(facecolor='white', alpha=0.8, boxstyle='round,pad=0.4')
    )
    ax.set_title(f"Scale calibration result  [{note}]", fontsize=12)
    ax.axis('off')
    plt.tight_layout()
    out = "scale_calibration_result.png"
    plt.savefig(out, dpi=150, bbox_inches='tight')
    plt.show()
    print(f"  Saved: {out}")


# ----------------------------------------------------------------
#  Save / load calibration JSON
# ----------------------------------------------------------------

def save_calibration(json_path: str, K, dist, rms, mm_per_px, px_per_mm, notes: str = ""):
    """Persist all calibration results to a JSON file."""
    d = dist.ravel()

    payload = {
        "metadata": {
            "camera": "Canon EOS 7D Mark II",
            "lens":   "Canon EF 100mm f/2.8L Macro IS USM",
            "date":   str(date.today()),
            "notes":  notes
        },
        "lens_distortion": {
            "rms_reprojection_error_px": float(rms),
            "k1": float(d[0]),
            "k2": float(d[1]),
            "p1": float(d[2]),
            "p2": float(d[3]),
            "k3": float(d[4]) if len(d) > 4 else 0.0,
            "camera_matrix_3x3": K.tolist()
        },
        "scale_factor": {
            "mm_per_pixel": float(mm_per_px),
            "pixels_per_mm": float(px_per_mm),
            "um_per_pixel":  float(mm_per_px * 1000)
        },
        "ncorr_inputs": {
            "distortion_coefficient_k1": float(d[0]),
            "scale_mm_per_pixel": float(mm_per_px),
            "note": (
                "Enter k1 in ncorr's distortion field. "
                "Multiply pixel displacements by scale_mm_per_pixel to get mm. "
                "Strain values from ncorr are already dimensionless (mm/mm)."
            )
        }
    }

    with open(json_path, 'w') as f:
        json.dump(payload, f, indent=2)
    print(f"\n  Calibration saved  →  {json_path}")
    return payload


def load_calibration(json_path: str):
    """Load a previously saved calibration JSON."""
    with open(json_path) as f:
        d = json.load(f)

    dist_data = d["lens_distortion"]
    K = np.array(dist_data["camera_matrix_3x3"], dtype=np.float64)
    dist = np.array([
        dist_data["k1"], dist_data["k2"],
        dist_data["p1"], dist_data["p2"],
        dist_data["k3"]
    ], dtype=np.float64)
    rms        = dist_data["rms_reprojection_error_px"]
    mm_per_px  = d["scale_factor"]["mm_per_pixel"]
    px_per_mm  = d["scale_factor"]["pixels_per_mm"]

    print(f"  Loaded calibration from {json_path}  (RMS = {rms:.4f} px)")
    return K, dist, rms, mm_per_px, px_per_mm


# ----------------------------------------------------------------
#  Final summary for ncorr
# ----------------------------------------------------------------

def print_ncorr_summary(dist, mm_per_px):
    """Print the two values to copy directly into ncorr."""
    k1 = dist.ravel()[0]

    print()
    print("╔" + "═"*51 + "╗")
    print("║          NCORR INPUT SUMMARY                      ║")
    print("╠" + "═"*51 + "╣")
    print(f"║  Distortion coeff. (k1):  {k1:+.8f}            ║")
    print(f"║  Scale factor:            {mm_per_px:.8f} mm/pixel  ║")
    print(f"║                           {mm_per_px*1000:.6f} µm/pixel  ║")
    print("╠" + "═"*51 + "╣")
    print("║  Strain output from ncorr is already in mm/mm.   ║")
    print("║  Multiply pixel displacements by scale factor     ║")
    print("║  to convert to physical units.                   ║")
    print("╚" + "═"*51 + "╝")
    print()


# ----------------------------------------------------------------
#  MAIN
# ----------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description="DIC Camera Calibration")
    p.add_argument("--extract-only",    action="store_true",
                   help="Extract frames from video and exit")
    p.add_argument("--distortion-only", action="store_true",
                   help="Run only lens distortion calibration")
    p.add_argument("--scale-only",      action="store_true",
                   help="Run only scale factor calibration (loads existing JSON for undistortion)")
    p.add_argument("--video",           type=str, default=None,
                   help="Path to calibration video for frame extraction")
    p.add_argument("--every-n",         type=int, default=15,
                   help="Keep 1 of every N frames during extraction (default: 15)")
    return p.parse_args()


def main():
    args = parse_args()

    print("=" * 57)
    print("  DIC Camera Calibration")
    print("  Canon EOS 7D Mk II + 100mm Macro")
    print("=" * 57)

    # ── 0. Frame extraction (optional) ──────────────────────────
    if args.extract_only or args.video:
        video = args.video
        if video is None:
            video = input("Path to calibration video: ").strip()
        n = extract_frames(video, CALIB_IMAGES_DIR, every_n=args.every_n)
        print(f"\nDone. {n} frames in '{CALIB_IMAGES_DIR}'.")
        print("Re-run without --extract-only to continue with calibration.")
        if args.extract_only:
            return

    K         = None
    dist      = None
    rms       = None
    mm_per_px = None
    px_per_mm = None

    # ── 1. Lens distortion calibration ──────────────────────────
    if not args.scale_only:
        print("\n[1/2] Lens distortion calibration …")
        K, dist, rms, _ = calibrate_distortion(
            images_dir=CALIB_IMAGES_DIR,
            cols=CHECKERBOARD_COLS,
            rows=CHECKERBOARD_ROWS,
            square_mm=SQUARE_SIZE_MM
        )
    else:
        # Load existing results for undistortion during scale step
        if os.path.exists(OUTPUT_JSON):
            K, dist, rms, mm_per_px, px_per_mm = load_calibration(OUTPUT_JSON)
            print_ncorr_summary(dist, mm_per_px)
            return  # already have everything
        else:
            print("  No existing calibration JSON found; scale image will not be undistorted.")

    if args.distortion_only:
        # Save partial results with placeholder scale factor
        if K is not None:
            payload = {
                "metadata": {"date": str(date.today()), "notes": CAMERA_NOTES},
                "lens_distortion": {
                    "rms_reprojection_error_px": float(rms),
                    "k1": float(dist.ravel()[0]),
                    "k2": float(dist.ravel()[1]),
                    "p1": float(dist.ravel()[2]),
                    "p2": float(dist.ravel()[3]),
                    "k3": float(dist.ravel()[4]) if len(dist.ravel()) > 4 else 0.0,
                    "camera_matrix_3x3": K.tolist()
                },
                "scale_factor": {"mm_per_pixel": None, "pixels_per_mm": None,
                                 "um_per_pixel": None},
                "ncorr_inputs": {"distortion_coefficient_k1": float(dist.ravel()[0]),
                                 "scale_mm_per_pixel": "RUN SCALE CALIBRATION"}
            }
            with open(OUTPUT_JSON, 'w') as f:
                json.dump(payload, f, indent=2)
            print(f"\n  Partial results saved to {OUTPUT_JSON}")
            print(f"  k1 for ncorr: {dist.ravel()[0]:+.8f}")
        return

    # ── 2. Scale factor calibration ──────────────────────────────
    print("\n[2/2] Scale factor calibration …")
    mm_per_px, px_per_mm = calibrate_scale(
        image_path=SCALE_IMAGE_PATH,
        K=K,
        dist=dist
    )

    # ── 3. Save & summarise ──────────────────────────────────────
    save_calibration(
        json_path=OUTPUT_JSON,
        K=K,
        dist=dist,
        rms=rms,
        mm_per_px=mm_per_px,
        px_per_mm=px_per_mm,
        notes=CAMERA_NOTES
    )

    print_ncorr_summary(dist, mm_per_px)


if __name__ == "__main__":
    main()