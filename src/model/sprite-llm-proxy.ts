/**
 * The on-sprite LLM proxy for sprites.dev, installed and started by the
 * bootstrap when a gateway model is chosen.
 *
 * sprites.dev's LLM gateway is the OpenRouter connector, reached at
 * `https://api.sprites.dev/v1/gateway/openrouter/<connection_id>/…` — an OpenAI
 * Chat Completions API, callable only from inside a sprite, with a per-org
 * `connection_id` discovered at runtime. That's not something the harnesses can
 * be pointed at directly: Claude Code speaks the Anthropic Messages API, and
 * the URL isn't known at VM-create time. So a small Python proxy runs on the
 * sprite, listens on localhost, discovers the connector's `gateway_base_url`,
 * translates Anthropic Messages ↔ OpenAI Chat Completions for Claude Code, and
 * passes OpenAI requests through for Codex and pi.
 */

import { encodeBase64 } from "@std/encoding/base64";

/** The port the proxy listens on, and the base URL the harnesses point at. */
export const PROXY_PORT = 8787;
export const PROXY_BASE_URL = `http://127.0.0.1:${PROXY_PORT}`;

export const PROXY_SCRIPT_NAME = ".sprite-llm-proxy.py";
export const PROXY_LOG_NAME = ".sprite-llm-proxy.log";

/**
 * Emitted in the bootstrap's harness `setup` fragment: writes the script and
 * starts it in the background, then waits for it to listen so the harnesses
 * find it when they start. Re-runnable on reconnect: an existing instance is
 * killed first.
 */
export function proxyInstallFragment(): string {
  const encoded = encodeBase64(new TextEncoder().encode(proxyScript()));
  return `
mkdir -p "$HOME"
printf %s '${encoded}' | base64 -d > "$HOME/${PROXY_SCRIPT_NAME}"
pkill -f "$HOME/${PROXY_SCRIPT_NAME}" 2>/dev/null || true
nohup python3 "$HOME/${PROXY_SCRIPT_NAME}" >> "$HOME/${PROXY_LOG_NAME}" 2>&1 &
for _i in $(seq 1 30); do
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 1 ${PROXY_BASE_URL}/health >/dev/null 2>&1; then break; fi
  sleep 0.2
done

`;
}

/**
 * The proxy itself. stdlib only (no pip), since the sprite may not have
 * anything installable offline. Translation covers text, tool use, and
 * streaming — the shapes Claude Code relies on.
 */
export function proxyScript(): string {
  return `#!/usr/bin/env python3
# An LLM proxy for sprites.dev: exposes the Anthropic Messages API and the
# OpenAI Chat Completions API on localhost, forwarding through the OpenRouter
# connector gateway (discovered via the gateway list endpoint). Anthropic
# Messages requests are translated to OpenAI Chat Completions; OpenAI requests
# pass through. Streaming is translated too.
#
# Authentication is implicit: the gateway identifies the calling sprite from
# the request signature, so no token is needed inside the VM.

import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = ${PROXY_PORT}
LIST_URL = "https://api.sprites.dev/v1/gateway/list"
GATEWAY_CACHE_PATH = os.path.expanduser("~/.sprite-llm-proxy-gateway")

# Discovered once at startup, refreshed if a request fails with auth.
gateway_base_url = None


def discover_gateway():
    # The list endpoint returns the connectors this sprite can reach; the
    # OpenRouter one's gateway_base_url is what we forward to.
    req = urllib.request.Request(LIST_URL, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        payload = json.loads(resp.read())
    for connector in payload.get("connectors", []) or []:
        base = connector.get("gateway_base_url") or ""
        provider = (connector.get("provider") or "").lower()
        if provider == "openrouter" or "/openrouter/" in base:
            return base.rstrip("/")
    # Some responses nest connectors under "available"/"connected".
    for key in ("available", "connected"):
        for connector in payload.get(key, []) or []:
            base = connector.get("gateway_base_url") or ""
            provider = (connector.get("provider") or "").lower()
            if provider == "openrouter" or "/openrouter/" in base:
                return base.rstrip("/")
    return None


def ensure_gateway():
    global gateway_base_url
    if gateway_base_url:
        return gateway_base_url
    gateway_base_url = discover_gateway()
    if gateway_base_url:
        try:
            with open(GATEWAY_CACHE_PATH, "w") as f:
                f.write(gateway_base_url)
        except OSError:
            pass
    return gateway_base_url


# Anthropic Messages -> OpenAI Chat Completions

def anthropic_content_to_openai(content):
    # Anthropic content is a string or a list of typed blocks; OpenAI wants a
    # string or a list of {type, ...} parts.
    if isinstance(content, str):
        return content
    parts = []
    for block in content:
        kind = block.get("type")
        if kind == "text":
            parts.append({"type": "text", "text": block.get("text", "")})
        elif kind == "image":
            src = block.get("source") or {}
            if src.get("type") == "base64":
                url = "data:%s;base64,%s" % (
                    src.get("media_type", "image/png"), src.get("data", ""))
                parts.append({"type": "image_url", "image_url": {"url": url}})
    return parts or ""


def anthropic_to_openai(body):
    messages = []
    system = body.get("system")
    if system:
        if isinstance(system, list):
            system = "\\n\\n".join(
                b.get("text", "") for b in system if b.get("type") == "text")
        messages.append({"role": "system", "content": system})

    for msg in body.get("messages", []):
        role = msg.get("role")
        content = msg.get("content")
        if isinstance(content, list):
            # Split out tool_result blocks: OpenAI carries each as a separate
            # tool message; text/image become one user message.
            tool_results = [b for b in content if b.get("type") == "tool_result"]
            other = [b for b in content if b.get("type") != "tool_result"]
            for tr in tool_results:
                tc = tr.get("content")
                if isinstance(tc, list):
                    tc = "\\n\\n".join(
                        b.get("text", "") for b in tc if b.get("type") == "text")
                messages.append({
                    "role": "tool",
                    "tool_call_id": tr.get("tool_use_id", ""),
                    "content": tc if isinstance(tc, str) else json.dumps(tc or ""),
                })
            if other:
                messages.append({"role": role, "content": anthropic_content_to_openai(other)})
        else:
            messages.append({"role": role, "content": anthropic_content_to_openai(content)})

    out = {"model": body.get("model"), "messages": messages, "stream": bool(body.get("stream"))}
    if "max_tokens" in body:
        out["max_tokens"] = body["max_tokens"]
    for key in ("temperature", "top_p", "stop", "user"):
        if key in body:
            out[key] = body[key]
    if "stop_sequences" in body:
        out["stop"] = body["stop_sequences"]
    tools = body.get("tools")
    if tools:
        out["tools"] = [{
            "type": "function",
            "function": {
                "name": t.get("name"),
                "description": t.get("description", ""),
                "parameters": t.get("input_schema", {"type": "object", "properties": {}}),
            },
        } for t in tools]
    if "tool_choice" in body:
        tc = body["tool_choice"]
        if isinstance(tc, dict) and tc.get("type") == "auto":
            out["tool_choice"] = "auto"
        elif isinstance(tc, dict) and tc.get("type") == "any":
            out["tool_choice"] = "required"
        elif isinstance(tc, dict) and tc.get("type") == "tool":
            out["tool_choice"] = {"type": "function", "function": {"name": tc.get("name")}}
        else:
            out["tool_choice"] = tc
    return out


def openai_finish_to_anthropic_stop(reason):
    return {
        "stop": "end_turn",
        "length": "max_tokens",
        "tool_calls": "tool_use",
        "function_call": "tool_use",
    }.get(reason, "end_turn")


def openai_response_to_anthropic(body, model):
    choice = (body.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    blocks = []
    if msg.get("content"):
        blocks.append({"type": "text", "text": msg["content"]})
    for call in msg.get("tool_calls") or []:
        fn = call.get("function") or {}
        try:
            arguments = json.loads(fn.get("arguments") or "{}")
        except Exception:
            arguments = {}
        blocks.append({
            "type": "tool_use",
            "id": call.get("id", ""),
            "name": fn.get("name", ""),
            "input": arguments,
        })
    usage = body.get("usage") or {}
    return {
        "id": body.get("id", "msg_proxy"),
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": blocks,
        "stop_reason": openai_finish_to_anthropic_stop(choice.get("finish_reason")),
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }


# Streaming translation (OpenAI SSE -> Anthropic SSE)

def anthropic_stream_events(openai_iter, model, input_tokens):
    # message_start: the message shell, with no content yet.
    msg_id = "msg_proxy"
    yield _event("message_start", {
        "type": "message_start",
        "message": {
            "id": msg_id, "type": "message", "role": "assistant",
            "model": model, "content": [], "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": input_tokens, "output_tokens": 0},
        },
    })

    # OpenAI streams text and tool_call fragments interleaved; Anthropic wants
    # one content block per block index. Track open blocks.
    blocks = {}
    next_index = 0
    text_index = None
    output_tokens = 0
    stop_reason = "end_turn"

    for chunk in openai_iter:
        if not chunk or chunk == "[DONE]":
            break
        try:
            data = json.loads(chunk)
        except Exception:
            continue
        if "usage" in data and data["usage"].get("completion_tokens") is not None:
            output_tokens = data["usage"].get("completion_tokens", output_tokens)
        choice = (data.get("choices") or [{}])[0]
        delta = choice.get("delta") or {}
        finish = choice.get("finish_reason")
        if finish:
            stop_reason = openai_finish_to_anthropic_stop(finish)

        if delta.get("content"):
            if text_index is None:
                text_index = next_index
                next_index += 1
                yield _event("content_block_start", {
                    "type": "content_block_start", "index": text_index,
                    "content_block": {"type": "text", "text": ""},
                })
            yield _event("content_block_delta", {
                "type": "content_block_delta", "index": text_index,
                "delta": {"type": "text_delta", "text": delta["content"]},
            })

        for call in delta.get("tool_calls") or []:
            idx = call.get("index", 0)
            if idx not in blocks:
                blocks[idx] = {
                    "block_index": next_index,
                    "id": call.get("id", ""),
                    "name": (call.get("function") or {}).get("name", ""),
                }
                next_index += 1
                yield _event("content_block_start", {
                    "type": "content_block_start", "index": blocks[idx]["block_index"],
                    "content_block": {
                        "type": "tool_use", "id": blocks[idx]["id"],
                        "name": blocks[idx]["name"], "input": {},
                    },
                })
            fn = call.get("function") or {}
            if fn.get("arguments"):
                yield _event("content_block_delta", {
                    "type": "content_block_delta", "index": blocks[idx]["block_index"],
                    "delta": {"type": "input_json_delta", "partial_json": fn["arguments"]},
                })

    # Close every block we opened, in order.
    for i in range(next_index):
        yield _event("content_block_stop", {"type": "content_block_stop", "index": i})

    yield _event("message_delta", {
        "type": "message_delta",
        "delta": {"stop_reason": stop_reason, "stop_sequence": None},
        "usage": {"output_tokens": output_tokens},
    })
    yield _event("message_stop", {"type": "message_stop"})


def _event(name, data):
    return "event: %s\\ndata: %s\\n\\n" % (name, json.dumps(data))


# Forwarding

def forward(openai_body, stream):
    base = ensure_gateway()
    if not base:
        raise RuntimeError("no OpenRouter connector found via " + LIST_URL)
    url = base + "/v1/chat/completions"
    req = urllib.request.Request(
        url, data=json.dumps(openai_body).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream" if stream else "application/json",
        },
        method="POST")
    return urllib.request.urlopen(req, timeout=300)


def read_sse_lines(resp):
    # urllib's HTTPResponse is iterable by line; SSE frames are blank-line
    # separated, so yield the data payload of each frame.
    for raw in resp:
        line = raw.decode("utf-8", "replace").rstrip("\\n")
        if line.startswith("data:"):
            yield line[len("data:"):].strip()


# HTTP server

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep the log file to errors only

    def _send(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, b"ok", "text/plain")
        else:
            self._send(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            self._send(400, b'{"error":"invalid json"}')
            return

        if self.path == "/v1/chat/completions":
            # Pass through to the gateway unchanged.
            self._passthrough(body)
        elif self.path == "/v1/messages":
            # Translate Anthropic Messages -> OpenAI Chat Completions.
            self._messages(body)
        else:
            self._send(404)

    def _passthrough(self, body):
        try:
            resp = forward(body, stream=bool(body.get("stream")))
        except urllib.error.HTTPError as e:
            self._send(e.code, e.read())
            return
        except Exception as e:
            self._send(502, json.dumps({"error": str(e)}).encode())
            return
        if body.get("stream"):
            self._stream_openai_passthrough(resp)
        else:
            self._relay(resp)

    def _messages(self, body):
        model = body.get("model", "")
        stream = bool(body.get("stream"))
        openai_body = anthropic_to_openai(body)
        try:
            resp = forward(openai_body, stream=stream)
        except urllib.error.HTTPError as e:
            # Surface the gateway's error as an Anthropic-shaped error so Claude
            # Code can show it rather than a raw HTTP code.
            err = json.dumps({
                "type": "error",
                "error": {"type": "api_error", "message": e.read().decode("utf-8", "replace")},
            }).encode()
            self._send(e.code, err)
            return
        except Exception as e:
            err = json.dumps({
                "type": "error",
                "error": {"type": "api_error", "message": str(e)},
            }).encode()
            self._send(502, err)
            return

        if stream:
            self._stream_messages(resp, model)
        else:
            try:
                payload = json.loads(resp.read())
            except Exception as e:
                self._send(502, json.dumps({
                    "type": "error",
                    "error": {"type": "api_error", "message": str(e)},
                }).encode())
                return
            self._send(200, json.dumps(openai_response_to_anthropic(payload, model)).encode())

    def _relay(self, resp):
        # Non-streaming pass-through: copy the gateway's JSON body.
        data = resp.read()
        self._send(200, data)

    def _stream_openai_passthrough(self, resp):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            for line in read_sse_lines(resp):
                self.wfile.write(("data: %s\\n\\n" % line).encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\\n\\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _stream_messages(self, resp, model):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            input_tokens = 0
            for event in anthropic_stream_events(read_sse_lines(resp), model, input_tokens):
                self.wfile.write(event.encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    try:
        ensure_gateway()
    except Exception as e:
        # Don't fatal-exit: the gateway may not be provisioned yet, and a later
        # request will retry discovery. Log and continue.
        sys.stderr.write("gateway discovery failed: %r\\n" % (e,))
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
`;
}
