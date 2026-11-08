"""numpy reference implementation of the Anime4K CNN passes described by
anime4k_ir. Mirrors mpv's hook semantics: same-size passes sample texel
centres (exact reads, edges clamped); depth-to-space adds MAIN sampled
bilinearly at the 2x position. Used to check the Metal kernels in CI.

usage: python3 anime4k_reference.py <preset> <in.png> <out.npy> [shader_dir]
presets: e.g. "upscale_s" or "restore_m,upscale_m"
"""
import os
import sys
import numpy as np

import anime4k_ir as ir


def shift(img, dx, dy):
    """img[y+dy, x+dx] with edge clamping."""
    h, w = img.shape[:2]
    ys = np.clip(np.arange(h) + dy, 0, h - 1)
    xs = np.clip(np.arange(w) + dx, 0, w - 1)
    return img[ys][:, xs]


def bilinear_2x(img):
    """Sample img (h, w, 4) at the pixel centres of a (2h, 2w) grid, clamped."""
    h, w = img.shape[:2]
    def coords(n):
        c = (np.arange(2 * n) + 0.5) / 2 - 0.5
        c0 = np.floor(c).astype(int)
        f = c - c0
        return np.clip(c0, 0, n - 1), np.clip(c0 + 1, 0, n - 1), f
    y0, y1, fy = coords(h)
    x0, x1, fx = coords(w)
    fx = fx[None, :, None]
    fy = fy[:, None, None]
    top = img[y0][:, x0] * (1 - fx) + img[y0][:, x1] * fx
    bot = img[y1][:, x0] * (1 - fx) + img[y1][:, x1] * fx
    return top * (1 - fy) + bot * fy


def run_shader(passes, main):
    tex = {"MAIN": main}
    for p in passes:
        if p.kind == "depth_to_space":
            h, w = tex[p.size_of].shape[:2]
            out = np.zeros((2 * h, 2 * w, 4), np.float32)
            for c in range(4):
                src = tex[p.d2s[c]]
                # sub-pixel (x%2, y%2) takes channel (y%2)*2 + x%2
                for sy in range(2):
                    for sx in range(2):
                        out[sy::2, sx::2, c] = src[:, :, sy * 2 + sx]
            out += bilinear_2x(tex["MAIN"])
        else:
            h, w = tex[p.size_of].shape[:2]
            out = np.tile(np.array(p.bias, np.float32), (h, w, 1))
            cache = {}
            for t in p.terms:
                key = (t.tex, t.sign, t.dx, t.dy)
                if key not in cache:
                    s = shift(tex[t.tex], t.dx, t.dy)
                    if t.sign == "pos":
                        s = np.maximum(s, 0)
                    elif t.sign == "neg":
                        s = np.maximum(-s, 0)
                    cache[key] = s
                m = np.array(t.matrix, np.float32).reshape(4, 4)  # rows = GLSL columns
                # GLSL mat4 * vec4 with column-major data: out_i = sum_j col_j[i] * v_j
                out += cache[key] @ m
            if p.kind == "conv_add_main":
                out += tex["MAIN"]
        tex[p.save] = out.astype(np.float32)
    return tex["MAIN"]


def run_preset(preset, img, shader_dir):
    main = img
    for sid in preset.split(","):
        passes = ir.parse(open(os.path.join(shader_dir, ir.SHADERS[sid])).read())
        main = run_shader(passes, main)
    return main


if __name__ == "__main__":
    from PIL import Image
    preset, src, dst = sys.argv[1:4]
    shader_dir = sys.argv[4] if len(sys.argv) > 4 else os.path.join(os.path.dirname(__file__), "../../assets/shaders")
    img = np.asarray(Image.open(src).convert("RGBA"), np.float32) / 255.0
    out = run_preset(preset, img, shader_dir)
    np.save(dst, out)
    print(dst, out.shape)
