"""Parse Anime4K v3.2 CNN shaders (mpv user-shader GLSL) into a small IR.

Only the CNN Restore/Upscale shaders are supported. Every pass in them is a
3x3 (or 1x1) convolution over CReLU-activated inputs, followed by either a
residual add of MAIN (Restore) or a depth-to-space step plus a bilinear MAIN
add (Upscale). The IR is consumed by anime4k_to_metal.py (Metal kernels for
the tvOS app) and anime4k_reference.py (numpy reference used in CI).
"""
import re
from dataclasses import dataclass, field

NUM = r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"


@dataclass
class Term:
    matrix: list          # 16 floats, column-major like GLSL mat4
    tex: str              # bound texture name
    sign: str             # 'id' | 'pos' (max(x,0)) | 'neg' (max(-x,0))
    dx: int
    dy: int


@dataclass
class Pass:
    desc: str
    binds: list
    save: str
    size_of: str          # texture whose size this pass's output takes
    scale: int            # 1 or 2
    kind: str             # 'conv' | 'conv_add_main' | 'depth_to_space'
    terms: list = field(default_factory=list)
    bias: list = field(default_factory=lambda: [0.0, 0.0, 0.0, 0.0])
    d2s: list = field(default_factory=list)   # [(tex)] per output channel 0..3


def parse(text):
    chunks = re.split(r"(?=^//!DESC)", text, flags=re.M)
    passes = []
    for chunk in chunks:
        if not chunk.startswith("//!DESC"):
            continue
        hdr = {}
        binds = []
        for line in chunk.splitlines():
            if line.startswith("//!"):
                key, _, val = line[3:].partition(" ")
                if key == "BIND":
                    binds.append(val.strip())
                else:
                    hdr[key] = val.strip()
        w = hdr["WIDTH"].split()
        size_of = w[0].rsplit(".", 1)[0]
        scale = int(w[1]) if len(w) > 1 else 1
        if len(w) > 1:
            assert w[2] == "*", hdr["WIDTH"]
        macros = {}
        for m in re.finditer(r"^#define (go?_\d+)(\(x_off, y_off\))? \((.*)\)$", chunk, re.M):
            name, offset, body = m.group(1), m.group(2), m.group(3)
            mm = re.fullmatch(r"max\((-?)\((\w+)_tex(?:Off\(vec2\(x_off, y_off\)\)|\(\w+_pos\))\), 0\.0\)", body)
            if mm:
                macros[name] = (mm.group(2), "neg" if mm.group(1) == "-" else "pos", bool(offset))
                continue
            mm = re.fullmatch(r"(\w+)_texOff\(vec2\(x_off, y_off\)\)", body)
            if mm:
                macros[name] = (mm.group(1), "id", True)
                continue
            raise ValueError(f"unsupported macro: {m.group(0)}")
        p = Pass(desc=hdr["DESC"], binds=binds, save=hdr["SAVE"], size_of=size_of, scale=scale, kind="conv")
        body = chunk[chunk.index("vec4 hook()"):]
        for m in re.finditer(r"result \+?= mat4\(([^)]*)\) \* (go?_\d+)(?:\((" + NUM + r"), (" + NUM + r")\))?;", body):
            mat = [float(x) for x in m.group(1).split(",")]
            assert len(mat) == 16
            tex, sign, has_off = macros[m.group(2)]
            dx = int(float(m.group(3))) if m.group(3) else 0
            dy = int(float(m.group(4))) if m.group(4) else 0
            assert has_off == (m.group(3) is not None)
            p.terms.append(Term(mat, tex, sign, dx, dy))
        b = re.search(r"result \+= vec4\(([^)]*)\);", body)
        if b:
            p.bias = [float(x) for x in b.group(1).split(",")]
        if "return result + MAIN_tex(MAIN_pos);" in body:
            p.kind = "conv_add_main"
        elif "Depth-to-Space" in p.desc:
            p.kind = "depth_to_space"
            chans = {}
            for m in re.finditer(r"float c(\d) = (\w+)_tex\(", body):
                chans[int(m.group(1))] = m.group(2)
            for m in re.finditer(r"float c(\d) = c(\d);", body):
                chans[int(m.group(1))] = chans[int(m.group(2))]
            p.d2s = [chans[i] for i in range(4)]
            assert "+ MAIN_tex(MAIN_pos)" in body
        else:
            assert "return result;" in body, p.desc
            assert p.terms, p.desc
        passes.append(p)
    return passes


SHADERS = {
    # id: file name in assets/shaders
    "restore_s": "Anime4K_Restore_CNN_S.glsl",
    "restore_m": "Anime4K_Restore_CNN_M.glsl",
    "restore_vl": "Anime4K_Restore_CNN_VL.glsl",
    "upscale_s": "Anime4K_Upscale_CNN_x2_S.glsl",
    "upscale_m": "Anime4K_Upscale_CNN_x2_M.glsl",
    "upscale_vl": "Anime4K_Upscale_CNN_x2_VL.glsl",
}
