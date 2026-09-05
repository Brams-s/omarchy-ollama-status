#!/usr/bin/env python3
"""Bounded local client for Ollama's documented HTTP API."""

from __future__ import annotations

import ctypes
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

CURL_PATH = "/usr/bin/curl"
DEFAULT_HOST = "http://127.0.0.1:11434"
MAX_RESPONSE_BYTES = 65536
MAX_RESULT_BYTES = 32768
OPERATION_TIMEOUT_SECONDS = 4.0
TERM_GRACE_SECONDS = 0.25
LOOPBACK_RE = re.compile(r"^https?://(?:127(?:\.[0-9]{1,3}){3}|\[::1\])(?::[0-9]{1,5})?$")
_PR_SET_PDEATHSIG = 1
_LIBC = ctypes.CDLL(None, use_errno=True)
_ACTIVE_PROCESS: subprocess.Popen[bytes] | None = None


def result_error(operation: str, kind: str, message: str) -> dict[str, object]:
    return {"ok": False, "operation": operation, "kind": kind, "error": message}


def normalized_host(value: str) -> str:
    if not value.startswith(("http://", "https://")):
        value = "http://" + value
    return value.rstrip("/")


def process_group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
    except ProcessLookupError:
        return False
    return True


def stop_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    deadline = time.monotonic() + TERM_GRACE_SECONDS
    while process_group_exists(process.pid) and time.monotonic() < deadline:
        time.sleep(0.01)
    if process_group_exists(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def handle_shutdown(signum: int, _frame: object) -> None:
    process = _ACTIVE_PROCESS
    if process is not None:
        stop_process_group(process)
    raise SystemExit(128 + signum)


def prepare_child(parent_pid: int) -> None:
    os.setsid()
    if _LIBC.prctl(_PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0) != 0:
        os._exit(127)
    if os.getppid() != parent_pid:
        os.kill(os.getpid(), signal.SIGKILL)


def invoke_curl(command: list[str]) -> tuple[str, int, bytes]:
    global _ACTIVE_PROCESS
    parent_pid = os.getpid()
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"},
        preexec_fn=lambda: prepare_child(parent_pid),
    )
    _ACTIVE_PROCESS = process
    assert process.stdout is not None
    output = bytearray()
    deadline = time.monotonic() + OPERATION_TIMEOUT_SECONDS
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                stop_process_group(process)
                return "timeout", process.returncode or -signal.SIGKILL, b""
            chunk = os.read(process.stdout.fileno(), min(8192, MAX_RESPONSE_BYTES + 1 - len(output)))
            if not chunk:
                process.wait()
                return "complete", process.returncode, bytes(output)
            output.extend(chunk)
            if len(output) > MAX_RESPONSE_BYTES:
                stop_process_group(process)
                return "overflow", process.returncode or -signal.SIGKILL, b""
    finally:
        selector.close()
        process.stdout.close()
        if _ACTIVE_PROCESS is process:
            _ACTIVE_PROCESS = None


def status_result(response: object) -> dict[str, object]:
    if not isinstance(response, dict) or response.get("error"):
        raise ValueError("invalid API object")
    values = response.get("models")
    if not isinstance(values, list):
        raise ValueError("missing models")
    records: list[tuple[dict[str, object], str]] = []
    aggregate_vram = 0.0
    for item in values:
        if not isinstance(item, dict):
            continue
        source_name = item.get("name") if isinstance(item.get("name"), str) else item.get("model")
        if not isinstance(source_name, str) or not source_name:
            continue
        records.append((item, source_name))
        value = item.get("size_vram")
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0:
            candidate = aggregate_vram + value
            if math.isfinite(candidate):
                aggregate_vram = candidate

    models: list[dict[str, object]] = []
    for item, source_name in records[:12]:
        clean: dict[str, object] = {}
        for key in ("name", "model", "expires_at"):
            if isinstance(item.get(key), str):
                clean[key] = item[key][:512]
        if len(source_name) <= 256:
            clean["action_id"] = source_name
        for key in ("size", "size_vram", "context_length"):
            value = item.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
                clean[key] = value
        models.append(clean)
    return {
        "ok": True,
        "operation": "status",
        "data": {
            "models": models,
            "loadedModelCount": len(records),
            "aggregateVramBytes": aggregate_vram,
        },
    }


def perform(operation: str, model: str = "") -> dict[str, object]:
    if operation not in {"status", "version", "unload"}:
        return result_error("status", "invalid_request", "Unknown Ollama Status operation.")
    host = normalized_host(os.environ.get("OLLAMA_HOST", DEFAULT_HOST))
    if not LOOPBACK_RE.fullmatch(host):
        return result_error(operation, "unsafe_endpoint", "For safety, Ollama Status only permits a literal loopback endpoint (127.0.0.1 or [::1]).")
    if not Path(CURL_PATH).is_file():
        return result_error(operation, "missing_dependency", "Missing dependency: curl is required to contact the Ollama API.")

    path = "/api/version" if operation == "version" else "/api/ps"
    extra_arguments: list[str] = []
    if operation == "unload":
        if not model or len(model) > 256 or model.strip() != model or any(
            ord(character) < 32 or 127 <= ord(character) <= 159 or character in "<>"
            for character in model
        ):
            return result_error(operation, "invalid_request", "No valid model was selected to unload.")
        path = "/api/chat"
        payload = json.dumps(
            {"model": model, "messages": [], "keep_alive": 0, "stream": False},
            separators=(",", ":"),
        )
        extra_arguments = [
            "--request",
            "POST",
            "--header",
            "Content-Type: application/json",
            "--data",
            payload,
        ]
    command = [
        CURL_PATH,
        "-q",
        "--noproxy",
        "*",
        "--fail",
        "--silent",
        "--show-error",
        "--connect-timeout",
        "1",
        "--max-time",
        "3",
        "--max-filesize",
        str(MAX_RESPONSE_BYTES),
    ] + extra_arguments + [host + path]
    try:
        outcome, returncode, stdout = invoke_curl(command)
    except (OSError, subprocess.SubprocessError):
        return result_error(operation, "missing_dependency", "Missing dependency: curl could not be started.")
    if outcome == "timeout":
        return result_error(operation, "operation_timeout", "The local Ollama request timed out.")
    if outcome == "overflow" or returncode == 63:
        return result_error(operation, "response_too_large", "Ollama returned an oversized response.")
    if returncode != 0:
        return result_error(operation, "transport_error", "Cannot reach the configured Ollama endpoint. Start Ollama using your preferred setup.")
    try:
        response = json.loads(stdout)
        if operation == "status":
            return status_result(response)
        if operation == "version":
            if not isinstance(response, dict) or response.get("error"):
                raise ValueError("invalid version object")
            value = response.get("version")
            if not isinstance(value, str) or not value or len(value) > 80:
                raise ValueError("invalid version")
            return {"ok": True, "operation": "version", "data": {"version": value}}
        if not isinstance(response, dict):
            raise ValueError("invalid unload object")
        if response.get("error"):
            return result_error("unload", "api_error", "Ollama rejected the unload request.")
        if response.get("done") is not True:
            raise ValueError("missing done")
        return {"ok": True, "operation": "unload", "data": {"done": True}}
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return result_error(operation, "invalid_data", "Ollama returned an invalid API response.")
    return {"ok": True, "operation": operation, "data": response}


def encode_result(result: dict[str, object]) -> bytes:
    encoded = json.dumps(result, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    if len(encoded) <= MAX_RESULT_BYTES:
        return encoded
    operation = result.get("operation")
    if operation not in {"status", "version", "unload"}:
        operation = "status"
    return json.dumps(
        result_error(str(operation), "internal_error", "Ollama Status produced an oversized local result."),
        separators=(",", ":"),
    ).encode("utf-8")


def main(argv: list[str]) -> int:
    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)
    operation = argv[1] if len(argv) > 1 else "status"
    model = argv[2] if len(argv) > 2 else ""
    sys.stdout.buffer.write(encode_result(perform(operation, model)) + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
