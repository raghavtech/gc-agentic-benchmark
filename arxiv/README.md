# arXiv submission package

`main.tex` + `figures/` — the LaTeX translation of `../REPORT.md`, prepared for arXiv submission.

## Before you submit

1. **Compile it yourself once before trusting it.** I verified this as thoroughly as possible
   without a working local LaTeX toolchain (both `pdflatex` install and a Docker-based check were
   blocked on this machine — see below) — braces and environments are balanced, every `\cite`
   resolves to a `\bibitem`, every `\ref` resolves to a `\label`, both figure files exist at their
   referenced paths, and only standard, ubiquitous packages are used (`geometry`, `graphicx`,
   `booktabs`, `array`, `longtable`, `enumitem`, `hyperref`, `xcolor`, `amsmath`). That's static
   verification, not a compile. **The fastest real check: upload this folder to
   [Overleaf](https://www.overleaf.com) (free) and hit Recompile** — no local install needed, and
   it'll surface anything I couldn't catch by inspection.
2. **Verify the two bibliography entries without a URL** (`evans-2020`, the Ben Evans "Understanding
   Classic Java Garbage Collection" InfoQ piece, and `marques-2025`, the Hugo Marques Netflix
   talk). I only had these secondhand from earlier research in this project, not independently
   fetched and confirmed by me in this session the way the Java Trends Report citation was.
   Confirm the exact title/date/URL before submitting.
3. **Fill in the repo/DOI reference** once GitHub + Zenodo are set up (still a placeholder step in
   the overall project plan) — the Reproducibility Appendix currently points to the local
   directory structure, which should become a public URL.
4. **Pick an arXiv category.** Given the content (empirical JVM/GC performance measurement), the
   natural primary category is `cs.PF` (Performance), with `cs.DC` (Distributed, Parallel, and
   Cluster Computing) as a reasonable secondary. Not something I can set in the file itself — it's
   chosen during arXiv's submission flow.

## Why local verification stopped short

Two independent attempts to get a real compiler running on this machine hit the same underlying
issue that shaped a lot of this project: architecture mismatches on Apple Silicon.
`brew install --cask basictex` needs an interactive sudo password this environment can't supply.
Docker (via colima) is installed but its `limactl` binary is itself an x86_64 build refusing to
run under Rosetta 2, the same class of problem documented at length in `../STATUS.md` for the
JDK itself. Neither was worth a longer detour to fix just for this one verification step — hence
the recommendation to use Overleaf instead, which sidesteps both problems entirely.

## Regenerating the figures

The PNGs in `figures/` are rendered from the SVGs in `../figures/` (via headless Chrome, at 2x
scale for print resolution). If `../figures/*.svg` are regenerated (e.g., after re-running
`../scripts/generate_charts.py` on updated data), re-render them:

```
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless --disable-gpu --screenshot=figures/convergence-divergence.png \
  --window-size=1132,424 --force-device-scale-factor=2 "file://$(pwd)/../figures/convergence-divergence.svg"
"$CHROME" --headless --disable-gpu --screenshot=figures/failure-modes-7500.png \
  --window-size=560,360 --force-device-scale-factor=2 "file://$(pwd)/../figures/failure-modes-7500.svg"
```
