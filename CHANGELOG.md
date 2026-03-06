# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] — 2026-03-06

### Fixed

- **Overview column misalignment**: the column header used hardcoded widths
  (`%-6s` for GPUs, `%6d/%-6d` for MiB, `%3d/%-3dW` for watts) that did not
  match actual data widths on larger clusters. The overview renderer now uses a
  two-pass approach — pass 1 scans all cached nodes to find the maximum GPU
  count, VRAM total, and power limit; pass 2 renders header and data rows with
  digit-widths derived from those maximums so all columns are always perfectly
  aligned regardless of cluster size.
- **Overview mode flicker/blink on view switch**: the previous fix used
  `tput clear` when switching between node-detail and overview views, causing a
  visible full-screen blank. Replaced with `\033[K` (erase-to-end-of-line)
  appended to every rendered line via `sed`, so stale right-edge characters are
  cleared inline each frame without blanking the screen.

## [0.1.3] — 2026-03-06

### Added

- **Cluster overview page**: press `o` / `O` (or `Tab`) to switch between the
  per-node detail view and a new full-cluster summary table
- Overview table shows one row per node with average GPU utilisation bar,
  total VRAM used/total bar, and total power draw for that node
- **CLUSTER SUM** row at the bottom aggregates every GPU across all nodes in
  the current SLURM job (avg util, total VRAM, total power)
- Stale or not-yet-loaded nodes are listed as `Waiting for data…` so they are
  never silently dropped from the count
- Sparkline history is now updated for **all** nodes in the job each refresh
  cycle (not only the currently displayed node)
- `o overview` keybinding hint added to the node-detail status bar

## [0.1.2] — 2026-02-27

### Fixed

- Replace `get_bar_width` with unified `get_layout` returning `bw`, `spark_len`, and `cols`;
  correct fixed-overhead constant to 80 chars (was 74/77)
- Hide the **Util History** column entirely when `spark_len < 6` (terminal too narrow)
- Widen memory format from `%5d/%-5d` to `%6d/%-6d` to accommodate 6-digit MiB values
  (e.g. NVIDIA H200 143 771 MiB); update "Used/Tot MiB" header padding to `%-13s`
- Correct **Power** header width `%-9s` → `%-8s` and **SM/MemMHz** header width
  `%-10s` → `%-9s` to match actual data column widths
- Pad `render_sparkline` output to the full `spark_len` with spaces so the **Flags**
  column always aligns even before the history buffer is full
- Guard **Flags** header against terminal-width overflow; only print it when ≥ 7
  spare columns remain after the fixed layout
- All separator lines (`─`, `╌`, `·`) now scale to actual terminal width instead of
  the hardcoded 78-character value
- Handle terminal resize (`SIGWINCH`): set a flag that triggers `tput clear` at the
  start of the next render cycle to eliminate stale content from old dimensions

## [0.1.0] — 2026-02-25

### Added

- Initial release of `nvnodetop`
- Real-time GPU monitoring across multiple SLURM job nodes via SSH
- Per-GPU metrics: utilisation, memory, temperature, power draw, SM/memory clocks
- Colour-coded utilisation bars (green / yellow / red thresholds)
- Rolling sparkline utilisation history (last 20 samples per GPU)
- Alert flags for thermal throttle (`!THERM`), power brake (`!PWR`), and ECC errors
- Per-process table (PID, username, command, GPU memory) — toggle with `p`
- Asynchronous per-node SSH polling with atomic cache file updates
- Responsive layout adapting bar widths to terminal width
- Graceful cleanup of pollers and temp files on exit
- Python package wrapper for `pip install nvnodetop` distribution
- GitHub Actions CI/CD pipeline for automated PyPI publishing

[Unreleased]: https://github.com/whats2000/nvnodetop/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/whats2000/nvnodetop/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/whats2000/nvnodetop/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/whats2000/nvnodetop/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/whats2000/nvnodetop/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/whats2000/nvnodetop/releases/tag/v0.1.0
