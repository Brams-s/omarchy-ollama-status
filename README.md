# Ollama Status

A standalone Omarchy bar widget showing the local Ollama API state and models held in memory. It uses Ollama's documented `GET /api/ps` endpoint rather than parsing command-line output.

## Compatibility

Built for Omarchy's Quattro/Quickshell bar plugin host, using its shared third-party service and standard panel lifecycle APIs.

## Preview

![Ollama Status panel showing a loaded model, refresh control, and local API diagnostics](preview.png)

## Setup

1. Install [Ollama](https://ollama.com) and start it in the way you prefer (a user service, a terminal, or another supervisor).
2. Ensure `curl` and `python3` are installed. Responses are validated locally before the widget uses them.
3. Install and enable the plugin:

   ```bash
   omarchy plugin add https://github.com/Brams-s/omarchy-ollama-status.git --enable
   ```

4. Add **Ollama Status** to a bar section if it is not placed automatically.

The default endpoint is `http://127.0.0.1:11434`. `OLLAMA_HOST` may only be a literal loopback endpoint (`127.x.x.x` or `[::1]`, with an optional port); hostnames and remote addresses are rejected. Requests ignore curl configuration and proxies.

## Behaviour and controls

- One shared service refreshes at startup, when any card opens, and every 15 seconds by default; unavailable endpoints use a bounded backoff.
- Clearly reports a missing `curl`, an unreachable server, invalid API data, and failed unload requests.
- Does not start or stop a service: that policy belongs to your setup.
- **Unload** sends Ollama's documented non-streaming chat request with `messages: []` and `keep_alive: 0`. Only one unload can run at a time.
- Open the widget to refresh. In the panel, use **R** to refresh, **Esc** to close, arrow keys to select a loaded model, and **Enter** twice (or click twice) to confirm unloading it. These controls follow the standard Omarchy panel lifecycle and keyboard navigation behavior.

## Configuration

Configure each bar-widget entry with **Refresh interval (seconds)** (5–300, default 15), **Maximum displayed models** (1–12, default 12), and **Compact mode** (default off). Compact mode shortens the horizontal bar label while retaining the model or availability state; vertical bars remain icon-first. The kept-loaded service validates these bounds and uses one stable effective configuration across monitor instances.

## Local checks

Run `./verify.sh` from this directory. It validates the manifest and release metadata, preview asset reference, helper sanitization, shell syntax, loopback-only endpoint policy, curl isolation, bounded response handling, and unload request behavior without contacting Ollama. Runtime QML behavior is verified locally in an Omarchy/Quattro session; CI runs `qmllint` only when it is already available and never installs QML dependencies.

## Removal

Disable and remove the plugin with:

```bash
omarchy plugin disable brams.ollama-status
rm -rf ~/.config/omarchy/plugins/brams.ollama-status
```
