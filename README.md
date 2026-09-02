# Ollama Status

A standalone Omarchy bar widget showing the local Ollama API state and models held in memory. It uses Ollama's documented `GET /api/ps` endpoint rather than parsing command-line output.

## Preview

![Ollama Status popup showing that no model is loaded and it is ready for the next prompt](assets/ollama-status-idle.png)

## Setup

1. Install [Ollama](https://ollama.com) and start it in the way you prefer (a user service, a terminal, or another supervisor).
2. Ensure `curl` is installed. `python3` is additionally required only for the **Unload** button, so model names are encoded safely.
3. Install and enable the plugin:

   ```bash
   omarchy plugin add https://github.com/Brams-s/omarchy-ollama-status.git --enable
   ```

4. Add **Ollama Status** to a bar section if it is not placed automatically.

The default endpoint is `http://127.0.0.1:11434`. Set `OLLAMA_HOST` in Quickshell's environment to use another local endpoint (for example, `OLLAMA_HOST=127.0.0.1:11434`).

## Behaviour

- Refreshes immediately when the card opens, every 5 seconds while open, and every 15 seconds in the bar.
- Clearly reports a missing `curl`, an unreachable server, invalid API data, and failed unload requests.
- Does not start or stop a service: that policy belongs to your setup.
- **Unload** sends Ollama's documented generate request with `keep_alive: 0`. Only one unload can run at a time.

## Local checks

Run `./verify.sh` from this directory. It validates the manifest JSON, shell syntax, missing-`curl` response, and loopback-only endpoint policy without contacting Ollama.

## Removal

Disable the plugin with `omarchy plugin disable brams.ollama-status`, then remove it from your Omarchy plugins directory.
