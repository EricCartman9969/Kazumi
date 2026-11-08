"""Compare the Metal Anime4K kernels with the numpy reference.

usage: python3 anime4k_compare.py <anime4k-metal-check binary> <kernels.metal>
Exits non-zero when any chain differs by more than fp16 rounding allows.
"""
import os
import subprocess
import sys
import tempfile

import numpy as np

import anime4k_reference as ref

HERE = os.path.dirname(os.path.abspath(__file__))
SHADER_DIR = os.path.join(HERE, "../../assets/shaders")
CHAINS = ["upscale_s", "restore_s", "restore_m,upscale_m", "restore_vl,upscale_vl"]


def test_image(w=80, h=48):
    """Line-art-like test card: gradients, hard edges, thin lines, noise."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    img = np.zeros((h, w, 4), np.float32)
    img[..., 0] = x / w
    img[..., 1] = y / h
    img[..., 2] = 0.5 + 0.5 * np.sin(x * 0.3) * np.cos(y * 0.2)
    circle = (x - w * 0.6) ** 2 + (y - h * 0.5) ** 2 < (h * 0.3) ** 2
    img[circle, :3] = [0.95, 0.85, 0.7]
    img[(np.abs(x - y * 1.3 - 5) < 0.8), :3] = 0.05
    img[:, 10:12, :3] = 0.1
    rng = np.random.default_rng(1)
    img[..., :3] += rng.normal(0, 0.02, (h, w, 3)).astype(np.float32)
    img[..., 3] = 1.0
    return np.clip(img, 0, 1)


def main():
    binary, kernels = sys.argv[1:3]
    img = test_image()
    h, w = img.shape[:2]
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "in.f32")
        img.astype(np.float32).tofile(src)
        for chain in CHAINS:
            dst = os.path.join(tmp, "out.f32")
            run = subprocess.run([binary, kernels, chain, src, str(w), str(h), dst], capture_output=True, text=True)
            print(run.stdout.strip())
            if run.returncode != 0:
                print(run.stderr)
                sys.exit(run.returncode)
            if "SKIP" in run.stdout:
                return
            expected = ref.run_preset(chain, img, SHADER_DIR)
            got = np.fromfile(dst, np.float32).reshape(expected.shape)
            err = np.abs(got[..., :3] - expected[..., :3])
            ok = err.max() < 0.02 and err.mean() < 0.002
            failed |= not ok
            print(f"{chain:24s} max {err.max():.5f} mean {err.mean():.6f} {'OK' if ok else 'FAIL'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
