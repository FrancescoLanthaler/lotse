#!/usr/bin/env python3
"""Printable tag25h9 markers as a vector PDF (one marker per page, razor-sharp at any size).

    python3 tools/make_markers.py                     # every marker in PocketBase, labelled
    python3 tools/make_markers.py 0 1 25 --paper a3   # just these IDs, unlabelled
    python3 tools/make_markers.py 0:"Bay A" 25:"Bus door 120" -o door.pdf

The tag fills the page width minus --margin-mm. Print at 100 % ("actual size", not "fit"),
on matte paper, then MEASURE the outer edge of the black square and store it with
tools/assign_marker.py --size: the distance maths is only as good as that number.

Layout is taken from NoValleyDuck/ThirdParty/apriltag/tag25h9.c and mirrors apriltag_to_image():
9 x 9 cells = 1 white ring + 1 black ring + 5 x 5 data cells (white = bit set).
"""
import argparse
import json
import os
import re
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAMILY_C = os.path.join(REPO, "NoValleyDuck", "ThirdParty", "apriltag", "tag25h9.c")
PB_URL = os.environ.get("PB_URL", "https://novalleyduck.novafox.at").rstrip("/")
PAPER_MM = {"a4": (210, 297), "a3": (297, 420), "a5": (148, 210)}
PT_PER_MM = 72 / 25.4


def load_family(path=FAMILY_C):
    src = open(path).read()
    get = lambda k: int(re.search(rf"tf->{k} = (\d+);", src).group(1))  # noqa: E731
    fam = {k: get(k) for k in ("ncodes", "nbits", "width_at_border", "total_width")}
    fam["reversed_border"] = re.search(r"tf->reversed_border = (\w+);", src).group(1) == "true"
    table = re.search(r"codedata\[\d+\] = \{(.*?)\};", src, re.S).group(1)
    fam["codes"] = [int(c, 16) for c in re.findall(r"0x[0-9a-fA-F]+", table)]
    fam["bit_x"] = [int(v) for v in re.findall(r"tf->bit_x\[\d+\] = (\d+);", src)]
    fam["bit_y"] = [int(v) for v in re.findall(r"tf->bit_y\[\d+\] = (\d+);", src)]
    assert len(fam["codes"]) == fam["ncodes"] and len(fam["bit_x"]) == fam["nbits"]
    return fam


def tag_grid(fam, idx):
    """Rows of 0 (black) / 1 (white), exactly like apriltag_to_image()."""
    n = fam["total_width"]
    im = [[0] * n for _ in range(n)]
    wbw = fam["width_at_border"] + (0 if fam["reversed_border"] else 2)
    wbs = (n - wbw) // 2
    for i in range(wbw - 1):
        im[wbs][wbs + i] = 1
        im[wbs + i][n - 1 - wbs] = 1
        im[n - 1 - wbs][wbs + i + 1] = 1
        im[wbs + 1 + i][wbs] = 1
    bs = (n - fam["width_at_border"]) // 2
    code = fam["codes"][idx]
    for i in range(fam["nbits"]):
        if code & (1 << (fam["nbits"] - i - 1)):
            im[fam["bit_y"][i] + bs][fam["bit_x"][i] + bs] = 1
    return im


def pdf_text(s):
    b = s.encode("cp1252", "replace")
    return "(" + b.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)").decode("latin-1") + ")"


def page_ops(fam, idx, title, paper, margin_mm):
    w_mm, h_mm = PAPER_MM[paper]
    W, H = w_mm * PT_PER_MM, h_mm * PT_PER_MM
    grid = tag_grid(fam, idx)
    n = len(grid)
    size = W - 2 * margin_mm * PT_PER_MM
    cell = size / n
    x0, y0 = (W - size) / 2, H - margin_mm * PT_PER_MM - size     # tag at the top of the page
    black_mm = cell * fam["width_at_border"] / PT_PER_MM
    # Explicit white page: the quiet zone must be white on screens and rasterizers too.
    ops = [f"1 g 0 0 {W:.3f} {H:.3f} re f", "0 g"]
    for r, row in enumerate(grid):
        for c, v in enumerate(row):
            if v == 0:
                ops.append(f"{x0 + c * cell:.3f} {y0 + (n - 1 - r) * cell:.3f} {cell:.3f} {cell:.3f} re")
    ops.append("f")   # one fill for all cells: no anti-aliasing seams between neighbours
    lines = [title or f"Marker {idx}",
             f"tag25h9 ID {idx}  ·  black square approx. {black_mm / 10:.1f} cm at 100 % print",
             "Measure the black square after printing and store it (tools/assign_marker.py --size)."]
    y = y0 - 20 * PT_PER_MM
    for i, text in enumerate(lines):
        fs = 28 if i == 0 else 11
        ops.append(f"BT /F1 {fs} Tf {x0:.3f} {y:.3f} Td {pdf_text(text)} Tj ET")
        y -= (fs + 8)
    return W, H, "\n".join(ops)


def write_pdf(pages, path):
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", None,
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
    kids = []
    for W, H, ops in pages:
        data = ops.encode("latin-1")
        objs.append(f"<< /Length {len(data)} >>\nstream\n{ops}\nendstream")
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {W:.2f} {H:.2f}] "
                    f"/Resources << /Font << /F1 3 0 R >> >> /Contents {len(objs)} 0 R >>")
        kids.append(f"{len(objs)} 0 R")
    objs[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {len(kids)} >>"
    out, offsets = b"%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n{o}\nendobj\n".encode("latin-1")
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    out += "".join(f"{o:010d} 00000 n \n" for o in offsets).encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    open(path, "wb").write(out)


def markers_from_pocketbase():
    q = urllib.parse.urlencode({"perPage": 500, "expand": "stop,bay", "sort": "stop,tag_id"})
    req = urllib.request.Request(f"{PB_URL}/api/collections/markers/records?{q}",
                                 headers={"User-Agent": "haltmal-tools/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        items = json.load(r)["items"]
    out = []
    for m in items:
        e = m.get("expand", {})
        if m["kind"] == "vehicle":
            title = f"Bus door · line {m['vehicle_line']} · marker {m['tag_id']}"
        else:
            bay = e.get("bay", {}).get("label", "")
            title = f"{e.get('stop', {}).get('name', '?')} · Bay {bay or '?'} · marker {m['tag_id']}"
        out.append((m["tag_id"], title))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ids", nargs="*", help='tag ids, optionally with a title: 0 or 0:"Bay A"')
    ap.add_argument("-o", "--out", default="markers.pdf")
    ap.add_argument("--paper", choices=sorted(PAPER_MM), default="a4")
    ap.add_argument("--margin-mm", type=float, default=12, help="printers can't print to the edge")
    args = ap.parse_args()

    fam = load_family()
    if args.ids:
        wanted = [(int(i.split(":", 1)[0]), i.split(":", 1)[1] if ":" in i else "") for i in args.ids]
    else:
        wanted = markers_from_pocketbase()
    for idx, _ in wanted:
        if not 0 <= idx < fam["ncodes"]:
            raise SystemExit(f"tag25h9 has IDs 0–{fam['ncodes'] - 1}, not {idx}")
    write_pdf([page_ops(fam, i, t, args.paper, args.margin_mm) for i, t in wanted], args.out)
    print(f"wrote {args.out}: {len(wanted)} page(s), {args.paper.upper()}")


if __name__ == "__main__":
    main()
