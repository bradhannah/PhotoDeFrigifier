"""Find visually similar image pairs with 64-bit pHash + dHash (read-only on the images).

  uv run --with pillow --with imagehash --with numpy python phash_pairs.py A_DIR [B_DIR] [--out pairs.csv]

With one folder it compares every image against every other. With two folders it compares only across them
(A against B), for example "Amazon thumbnails" against "Apple previews". Hash small JPEG thumbnails (<= 512 px)
rather than originals; it's much faster and also covers HEIC and video once they're converted:
  sips -s format jpeg -Z 512 in.heic --out thumbs/in.jpg      qlmanage -t -s 512 -o thumbs/ clip.mov

Grades (Hamming distance out of 64):
  strong    phash <= 4 and dhash <= 6 and same aspect ratio (within 0.02, either orientation)
  possible  phash <= 10 and dhash <= 12
Near-blank images (grayscale stddev < 8) are skipped, because they match everything.
Writes a CSV: a, b, phash_d, dhash_d, aspect_a, aspect_b, grade. Sorted strongest first.
"""
import argparse
import csv
import os
import sys
from concurrent.futures import ProcessPoolExecutor

import imagehash
import numpy as np
from PIL import Image, ImageOps, ImageStat

EXTS = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic"}


def files_in(root):
    for d, _, names in os.walk(root):
        for n in names:
            if not n.startswith(".") and os.path.splitext(n)[1].lower() in EXTS:
                yield os.path.join(d, n)


def hash_one(path):
    try:
        with Image.open(path) as im:
            im = ImageOps.exif_transpose(im).convert("RGB")
            w, h = im.size
            std = ImageStat.Stat(im.convert("L").resize((64, 64))).stddev[0]
            return path, int(str(imagehash.phash(im)), 16), int(str(imagehash.dhash(im)), 16), w / h, std
    except Exception as e:  # unreadable or unsupported: report and skip
        return path, None, None, None, str(e)


def popcount(x):
    if hasattr(np, "bitwise_count"):
        return np.bitwise_count(x)
    return np.unpackbits(x.view(np.uint8).reshape(*x.shape, 8), axis=-1).sum(axis=-1)


def same_aspect(a, b):
    return abs(a - b) <= 0.02 or abs(a - 1 / b) <= 0.02


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a_dir")
    ap.add_argument("b_dir", nargs="?")
    ap.add_argument("--out", default="pairs.csv")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    groups = [list(files_in(args.a_dir))] + ([list(files_in(args.b_dir))] if args.b_dir else [])
    hashed = []
    with ProcessPoolExecutor(args.workers) as pool:
        for files in groups:
            rows = [r for r in pool.map(hash_one, files, chunksize=32)]
            bad = [r for r in rows if r[1] is None]
            for r in bad:
                print(f"skip (unreadable): {r[0]}: {r[4]}", file=sys.stderr)
            blank = [r for r in rows if r[1] is not None and r[4] < 8]
            print(f"{len(rows)} files, {len(bad)} unreadable, {len(blank)} near-blank skipped", file=sys.stderr)
            hashed.append([r for r in rows if r[1] is not None and r[4] >= 8])

    A = hashed[0]
    B = hashed[1] if len(hashed) > 1 else hashed[0]
    pa = np.array([r[1] for r in A], dtype=np.uint64)
    da = np.array([r[2] for r in A], dtype=np.uint64)
    pb = np.array([r[1] for r in B], dtype=np.uint64)
    db = np.array([r[2] for r in B], dtype=np.uint64)
    out = []
    for start in range(0, len(A), 400):
        P = popcount(pa[start:start + 400, None] ^ pb[None, :])
        D = popcount(da[start:start + 400, None] ^ db[None, :])
        ii, jj = np.nonzero((P <= 10) & (D <= 12))
        for i, j in zip(ii, jj):
            gi = start + i
            if len(hashed) == 1 and j <= gi:  # one folder: each pair once, never self
                continue
            a, b = A[gi], B[j]
            p, d = int(P[i, j]), int(D[i, j])
            grade = "strong" if p <= 4 and d <= 6 and same_aspect(a[3], b[3]) else "possible"
            out.append((a[0], b[0], p, d, round(a[3], 3), round(b[3], 3), grade))
    out.sort(key=lambda r: (r[6] != "strong", r[2] + r[3]))
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["a", "b", "phash_d", "dhash_d", "aspect_a", "aspect_b", "grade"])
        w.writerows(out)
    print(f"{sum(r[6] == 'strong' for r in out)} strong, {sum(r[6] == 'possible' for r in out)} possible -> {args.out}")


if __name__ == "__main__":
    main()
