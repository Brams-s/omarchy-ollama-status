# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.3.1] — 2026-09-02

### Fixed
- Kept exact canonical model identities for copy and unload actions separate from safe display labels; unsafe or overlong identities are non-actionable.
- Preserved global loaded-model count and aggregate VRAM independently of the rendered-model limit.
- Classified curl oversized-response exit status correctly instead of reporting it as a transport failure.
- Bounded and hardened clipboard writes with timeout and explicit plain-text MIME handling.

## [1.3.0] — 2026-09-02

### Added
- A copy-model-name action for the selected loaded model and an aggregate VRAM summary.
- A root-level panel preview and deterministic version, changelog, and preview release checks.

### Changed
- Reproducible strict QML CI now resolves the pinned Quickshell and Omarchy import environment.
- Removal documentation now uses Omarchy’s canonical plugin removal command.

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
