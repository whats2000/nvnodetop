# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/whats2000/nvnodetop/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/whats2000/nvnodetop/releases/tag/v0.1.0
