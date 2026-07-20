#!/usr/bin/env python3
"""
Generates the two figures referenced in REPORT.md, as static SVG, directly
from the real aggregate.csv data -- no charting library dependency (matplotlib
isn't installed in this environment, and pure-stdlib SVG generation keeps this
consistent with the harness's own zero-dependency approach).

Palette: categorical slots 1/2/3 (blue/green/magenta) from the project's
validated default palette, in fixed order -- see the dataviz skill's
references/palette.md. Magenta (slot 3) has a light-surface contrast note in
that palette, mitigated here with direct end-of-line labels on every series
(the documented "relief rule"), not color alone.
"""
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CSV_PATH = os.path.join(ROOT, "data", "results", "aggregate.csv")
OUT_DIR = os.path.join(ROOT, "figures")

COLOR = {
    "g1": "#2a78d6",           # categorical slot 1 (blue)
    "zgc": "#008300",          # categorical slot 2 (green)
    "shenandoah": "#e87ba4",   # categorical slot 3 (magenta)
}
LABEL = {"g1": "G1", "zgc": "Generational ZGC", "shenandoah": "Shenandoah"}
INK_PRIMARY = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRIDLINE = "#e1e0d9"
BASELINE = "#c3c2b7"
SURFACE = "#fcfcfb"
CRITICAL = "#d03b3b"  # status color, reserved -- used only for the OOM marker, with icon+label


def load_rows():
    rows = []
    with open(CSV_PATH) as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows


def series_for(rows, heap, collector):
    """Returns sorted (concurrency, mean, min, max, reps_ok) for one (heap, collector)."""
    out = []
    for r in rows:
        if r["heap"] != heap or r["collector"] != collector:
            continue
        if not r["p50_ms_mean"]:  # fully failed cell (e.g. zgc 2g c7500, 0/3)
            out.append((int(r["concurrency"]), None, None, None, r["reps_ok"]))
            continue
        out.append((
            int(r["concurrency"]),
            float(r["gc_attrib_pct_mean"]),
            float(r["gc_attrib_pct_min"]),
            float(r["gc_attrib_pct_max"]),
            r["reps_ok"],
        ))
    out.sort(key=lambda t: t[0])
    return out


def log_scale(value, domain_min, domain_max, px_min, px_max):
    import math
    lo, hi, v = math.log10(domain_min), math.log10(domain_max), math.log10(value)
    return px_min + (v - lo) / (hi - lo) * (px_max - px_min)


def lin_scale(value, domain_min, domain_max, px_min, px_max):
    return px_min + (value - domain_min) / (domain_max - domain_min) * (px_max - px_min)


def fmt(v):
    return f"{v:.1f}"


# ---------------------------------------------------------------------------
# Figure 1: convergence-then-divergence, small multiples, one panel per heap
# ---------------------------------------------------------------------------

def build_figure_1(rows):
    heaps = [("512m", "512MB heap"), ("1g", "1GB heap"), ("2g", "2GB heap")]
    collectors = ["g1", "zgc", "shenandoah"]

    panel_w, panel_h = 300, 250
    gap = 40
    margin_l, margin_r, margin_t, margin_b = 56, 96, 84, 50
    total_w = margin_l + panel_w * 3 + gap * 2 + margin_r
    total_h = margin_t + panel_h + margin_b + 40  # + legend row

    y_max = 58  # covers up to ~50% (zgc 2g/10000 ~= 49.75) with headroom for end labels
    x_min, x_max = 100, 10000

    svg = []
    svg.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{total_w}" height="{total_h}" '
                f'viewBox="0 0 {total_w} {total_h}" font-family="system-ui, -apple-system, \'Segoe UI\', sans-serif">')
    svg.append(f'<rect x="0" y="0" width="{total_w}" height="{total_h}" fill="{SURFACE}"/>')
    svg.append(f'<text x="{margin_l}" y="24" font-size="15" font-weight="600" fill="{INK_PRIMARY}">'
                f'GC-attributable spike rate vs. concurrency, by heap size and collector</text>')
    svg.append(f'<text x="{margin_l}" y="42" font-size="11" fill="{INK_SECONDARY}">'
                f'Mean across 3 repetitions, log-scaled x axis. Collectors converge at moderate concurrency,</text>')
    svg.append(f'<text x="{margin_l}" y="57" font-size="11" fill="{INK_SECONDARY}">'
                f'diverge at the edge of each heap size’s capacity.</text>')

    for i, (heap_key, heap_label) in enumerate(heaps):
        px0 = margin_l + i * (panel_w + gap)
        py0 = margin_t
        px1 = px0 + panel_w
        py1 = py0 + panel_h

        # panel title
        svg.append(f'<text x="{px0}" y="{py0 - 12}" font-size="12" font-weight="600" fill="{INK_PRIMARY}">{heap_label}</text>')

        # gridlines (y) at 0, 10, 20, 30, 40, 50
        for gy in range(0, 51, 10):
            y = lin_scale(gy, 0, y_max, py1, py0)
            svg.append(f'<line x1="{px0}" y1="{y:.1f}" x2="{px1}" y2="{y:.1f}" stroke="{GRIDLINE}" stroke-width="1"/>')
            if i == 0:
                svg.append(f'<text x="{px0 - 8}" y="{y+3:.1f}" font-size="10" fill="{INK_MUTED}" text-anchor="end">{gy}%</text>')

        # x axis ticks
        for cx in [100, 1000, 10000]:
            x = log_scale(cx, x_min, x_max, px0, px1)
            svg.append(f'<line x1="{x:.1f}" y1="{py1}" x2="{x:.1f}" y2="{py1+4}" stroke="{BASELINE}" stroke-width="1"/>')
            label = f"{cx:,}"
            svg.append(f'<text x="{x:.1f}" y="{py1+16}" font-size="10" fill="{INK_MUTED}" text-anchor="middle">{label}</text>')

        # baseline
        svg.append(f'<line x1="{px0}" y1="{py1}" x2="{px1}" y2="{py1}" stroke="{BASELINE}" stroke-width="1"/>')

        end_points = []  # (collector, x, y) of each series' final plotted point, for label stacking

        for collector in collectors:
            pts = series_for(rows, heap_key, collector)
            # keep every level's index so we can tell an ADJACENT pair (solid line) from
            # a pair that skips a fully-failed level in between (dashed -- no real
            # continuity across a concurrency level where zero repetitions survived)
            plotted = []  # (list_index, x, y, reps_ok)
            for idx, (conc, mean, lo, hi, reps_ok) in enumerate(pts):
                if mean is None:
                    continue
                x = log_scale(conc, x_min, x_max, px0, px1)
                y = lin_scale(mean, 0, y_max, py1, py0)
                plotted.append((idx, x, y, reps_ok))

            for a, b in zip(plotted, plotted[1:]):
                (idx_a, xa, ya, _), (idx_b, xb, yb, _) = a, b
                adjacent = (idx_b - idx_a) == 1
                dash = '' if adjacent else ' stroke-dasharray="5 4"'
                svg.append(f'<path d="M {xa:.1f} {ya:.1f} L {xb:.1f} {yb:.1f}" fill="none" '
                            f'stroke="{COLOR[collector]}" stroke-width="2" stroke-linecap="round"{dash}/>')

            for _, x, y, reps_ok in plotted:
                r = 3.5
                # partial-survival points (reps_ok != "3/3") get a hollow ring to flag incompleteness
                if reps_ok == "3/3":
                    svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{COLOR[collector]}"/>')
                else:
                    svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{SURFACE}" '
                                f'stroke="{COLOR[collector]}" stroke-width="2"/>')

            if plotted:
                _, x, y, _ = plotted[-1]
                end_points.append((collector, x, y))

            # explicit OOM marker where a cell has zero surviving reps (e.g. zgc @ 2g/7500)
            for idx, (conc, mean, lo, hi, reps_ok) in enumerate(pts):
                if mean is None:
                    x = log_scale(conc, x_min, x_max, px0, px1)
                    y = py1 - 14
                    svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{CRITICAL}"/>')
                    svg.append(f'<text x="{x:.1f}" y="{y-7:.1f}" font-size="9" fill="{CRITICAL}" '
                                f'text-anchor="middle" font-weight="600">OOM</text>')

        # direct end-of-line labels (relief rule for the magenta slot), stacked to
        # avoid collisions regardless of how close the actual data points are --
        # sorted by plotted y (top to bottom), each pushed down at least 12px past
        # the previous label so nothing overlaps even when values are nearly equal
        end_points.sort(key=lambda t: t[2])
        placed_y = None
        for collector, x, y in end_points:
            label_y = y - 8
            if placed_y is not None and label_y < placed_y + 12:
                label_y = placed_y + 12
            placed_y = label_y
            svg.append(f'<text x="{px1 - 4}" y="{label_y:.1f}" font-size="9.5" fill="{COLOR[collector]}" '
                        f'text-anchor="end" font-weight="600">{LABEL[collector]}</text>')

    # legend (shared, one row under the panels)
    ly = margin_t + panel_h + 34
    lx = margin_l
    for collector in collectors:
        svg.append(f'<line x1="{lx}" y1="{ly}" x2="{lx+18}" y2="{ly}" stroke="{COLOR[collector]}" stroke-width="2" stroke-linecap="round"/>')
        svg.append(f'<text x="{lx+24}" y="{ly+4}" font-size="11" fill="{INK_SECONDARY}">{LABEL[collector]}</text>')
        lx += 24 + len(LABEL[collector]) * 6.2 + 28
    svg.append(f'<circle cx="{lx}" cy="{ly}" r="4" fill="{CRITICAL}"/>')
    svg.append(f'<text x="{lx+10}" y="{ly+4}" font-size="11" fill="{INK_SECONDARY}">OOM (zero surviving repetitions)</text>')

    svg.append('</svg>')
    return "\n".join(svg), total_w, total_h


# ---------------------------------------------------------------------------
# Figure 2: three failure modes at 2GB / 7500 concurrency
# ---------------------------------------------------------------------------

def build_figure_2(rows):
    heap, conc = "2g", "7500"
    collectors = ["g1", "zgc", "shenandoah"]
    data = {}
    for r in rows:
        if r["heap"] == heap and r["concurrency"] == conc:
            data[r["collector"]] = r

    width, height = 560, 360
    margin_l, margin_r, margin_t, margin_b = 60, 30, 68, 66
    plot_w = width - margin_l - margin_r
    plot_h = height - margin_t - margin_b
    y_max = 45

    bar_w = 90
    gap = (plot_w - bar_w * 3) / 4

    svg = []
    svg.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
                f'viewBox="0 0 {width} {height}" font-family="system-ui, -apple-system, \'Segoe UI\', sans-serif">')
    svg.append(f'<rect x="0" y="0" width="{width}" height="{height}" fill="{SURFACE}"/>')
    svg.append(f'<text x="{margin_l}" y="22" font-size="14" font-weight="600" fill="{INK_PRIMARY}">'
                f'Three failure modes at the edge of capacity</text>')
    svg.append(f'<text x="{margin_l}" y="39" font-size="11" fill="{INK_SECONDARY}">'
                f'2GB heap, 7,500 concurrent streams. Bars: mean GC-attributable spike rate.</text>')
    svg.append(f'<text x="{margin_l}" y="54" font-size="11" fill="{INK_SECONDARY}">'
                f'Whiskers: min–max across 3 repetitions.</text>')

    py1 = margin_t + plot_h
    for gy in range(0, y_max + 1, 10):
        y = lin_scale(gy, 0, y_max, py1, margin_t)
        svg.append(f'<line x1="{margin_l}" y1="{y:.1f}" x2="{margin_l+plot_w}" y2="{y:.1f}" stroke="{GRIDLINE}" stroke-width="1"/>')
        svg.append(f'<text x="{margin_l-8}" y="{y+3:.1f}" font-size="10" fill="{INK_MUTED}" text-anchor="end">{gy}%</text>')
    svg.append(f'<line x1="{margin_l}" y1="{py1}" x2="{margin_l+plot_w}" y2="{py1}" stroke="{BASELINE}" stroke-width="1"/>')

    x = margin_l + gap
    for collector in collectors:
        r = data.get(collector)
        cx = x + bar_w / 2
        if r and r["reps_ok"] == "3/3":
            mean = float(r["gc_attrib_pct_mean"])
            lo = float(r["gc_attrib_pct_min"])
            hi = float(r["gc_attrib_pct_max"])
            y_top = lin_scale(mean, 0, y_max, py1, margin_t)
            svg.append(f'<rect x="{x:.1f}" y="{y_top:.1f}" width="{bar_w}" height="{py1-y_top:.1f}" '
                        f'fill="{COLOR[collector]}" rx="3"/>')
            y_lo = lin_scale(lo, 0, y_max, py1, margin_t)
            y_hi = lin_scale(hi, 0, y_max, py1, margin_t)
            svg.append(f'<line x1="{cx:.1f}" y1="{y_hi:.1f}" x2="{cx:.1f}" y2="{y_lo:.1f}" stroke="{INK_PRIMARY}" stroke-width="1.5"/>')
            svg.append(f'<line x1="{cx-8:.1f}" y1="{y_hi:.1f}" x2="{cx+8:.1f}" y2="{y_hi:.1f}" stroke="{INK_PRIMARY}" stroke-width="1.5"/>')
            svg.append(f'<line x1="{cx-8:.1f}" y1="{y_lo:.1f}" x2="{cx+8:.1f}" y2="{y_lo:.1f}" stroke="{INK_PRIMARY}" stroke-width="1.5"/>')
            svg.append(f'<text x="{cx:.1f}" y="{y_top-8:.1f}" font-size="11" font-weight="600" fill="{INK_PRIMARY}" text-anchor="middle">{fmt(mean)}%</text>')
            status_label = "3/3 survived"
        else:
            # OOM / total failure: critical-status marker, icon + label, never color-alone
            y_zero = py1
            svg.append(f'<line x1="{x:.1f}" y1="{y_zero-2}" x2="{x+bar_w:.1f}" y2="{y_zero-2}" '
                        f'stroke="{CRITICAL}" stroke-width="4" stroke-dasharray="6 4"/>')
            svg.append(f'<circle cx="{cx:.1f}" cy="{margin_t+plot_h/2:.1f}" r="16" fill="none" stroke="{CRITICAL}" stroke-width="2.5"/>')
            svg.append(f'<text x="{cx:.1f}" y="{margin_t+plot_h/2+5:.1f}" font-size="16" fill="{CRITICAL}" text-anchor="middle" font-weight="700">!</text>')
            svg.append(f'<text x="{cx:.1f}" y="{margin_t+plot_h/2+34:.1f}" font-size="11" font-weight="600" fill="{CRITICAL}" text-anchor="middle">OOM</text>')
            status_label = "0/3 survived"

        svg.append(f'<text x="{cx:.1f}" y="{py1+20}" font-size="12" font-weight="600" fill="{INK_PRIMARY}" text-anchor="middle">{LABEL[collector]}</text>')
        svg.append(f'<text x="{cx:.1f}" y="{py1+35}" font-size="9.5" fill="{INK_SECONDARY}" text-anchor="middle">{status_label}</text>')

        x += bar_w + gap

    svg.append('</svg>')
    return "\n".join(svg), width, height


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    rows = load_rows()

    svg1, w1, h1 = build_figure_1(rows)
    path1 = os.path.join(OUT_DIR, "convergence-divergence.svg")
    with open(path1, "w") as f:
        f.write(svg1)
    print(f"wrote {path1} ({w1}x{h1})")

    svg2, w2, h2 = build_figure_2(rows)
    path2 = os.path.join(OUT_DIR, "failure-modes-7500.svg")
    with open(path2, "w") as f:
        f.write(svg2)
    print(f"wrote {path2} ({w2}x{h2})")


if __name__ == "__main__":
    main()
