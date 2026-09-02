# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.2.0] — 2026-09-02

### Added
- A kept-loaded shared service with bounded polling, diagnostics, and per-widget settings.
- Standard Omarchy panel lifecycle, keyboard navigation, and accessible unload confirmation.
- Deterministic verification and optional CI checks.

### Changed
- Hardened the local-only Ollama client against proxy/config redirection and untrusted API data.
- Python 3 is now required for all local API response validation, not only unload requests.
- Model unloads now use Ollama's non-streaming `/api/chat` endpoint with an empty message list and `keep_alive: 0`.

## [1.1.1] — 2026-09-02

### Added
- Initial public release with local Ollama API status, loaded-model details, and an unload action.
- A safe loopback-only Ollama endpoint policy.
- Documentation and a screenshot.

### Fixed
- Runtime QML compatibility for script URLs and valid nested QML syntax.
