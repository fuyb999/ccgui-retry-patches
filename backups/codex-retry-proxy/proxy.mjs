import http from "node:http";
import https from "node:https";
import { pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";

const HEALTH_PATH = "/_codex_retry_proxy/health";
const MAX_SSE_PROBE_BYTES = 256 * 1024;
const SSE_LIFECYCLE_EVENTS = new Set([
  "response.created",
  "response.in_progress",
  "response.queued",
]);
const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

class DownstreamClosedError extends Error {
  constructor() {
    super("downstream client disconnected");
    this.name = "DownstreamClosedError";
  }
}

function isMainModule() {
  return process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url;
}

function parsePositiveInteger(value, name, { allowZero = false } = {}) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < (allowZero ? 0 : 1)) {
    throw new Error(`${name} must be an integer >= ${allowZero ? 0 : 1}`);
  }
  return parsed;
}

function normalizeOptions({ upstreamBaseUrl, retryDelayMs = 30_000, logger = console.error }) {
  const upstream = new URL(upstreamBaseUrl);
  if (upstream.protocol !== "http:" && upstream.protocol !== "https:") {
    throw new Error("upstreamBaseUrl must use http or https");
  }
  const delay = parsePositiveInteger(retryDelayMs, "retryDelayMs", { allowZero: true });
  if (typeof logger !== "function") {
    throw new TypeError("logger must be a function");
  }
  return { upstream, retryDelayMs: delay, logger };
}

function requestPath(upstream, incomingUrl) {
  const incoming = new URL(incomingUrl, "http://codex-retry-proxy.invalid");
  const basePath = upstream.pathname.replace(/\/$/, "");
  const path = `${basePath}${incoming.pathname}` || "/";
  return `${path}${incoming.search}`;
}

function forwardRequestHeaders(incomingHeaders, bodyLength) {
  const headers = {};
  for (const [name, value] of Object.entries(incomingHeaders)) {
    if (name === "host" || HOP_BY_HOP_HEADERS.has(name)) {
      continue;
    }
    headers[name] = value;
  }
  headers["content-length"] = String(bodyLength);
  return headers;
}

function forwardResponseHeaders(incomingHeaders) {
  const headers = {};
  for (const [name, value] of Object.entries(incomingHeaders)) {
    if (HOP_BY_HOP_HEADERS.has(name)) {
      continue;
    }
    headers[name] = value;
  }
  return headers;
}

function readRequestBody(request, signal) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let settled = false;
    const finish = (error, body) => {
      if (settled) {
        return;
      }
      settled = true;
      signal.removeEventListener("abort", onAbort);
      if (error) {
        reject(error);
      } else {
        resolve(body);
      }
    };
    const onAbort = () => finish(new DownstreamClosedError());
    signal.addEventListener("abort", onAbort, { once: true });
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => finish(null, Buffer.concat(chunks)));
    request.on("error", (error) => finish(error));
    request.on("aborted", onAbort);
  });
}

function sendUpstreamAttempt({ upstream, request, headers, body, signal }) {
  return new Promise((resolve, reject) => {
    const transport = upstream.protocol === "https:" ? https : http;
    const client = transport.request(
      {
        protocol: upstream.protocol,
        hostname: upstream.hostname,
        port: upstream.port || undefined,
        method: request.method,
        path: requestPath(upstream, request.url),
        headers: { ...headers, host: upstream.host },
      },
      (response) => {
        signal.removeEventListener("abort", onAbort);
        resolve(response);
      },
    );
    const onAbort = () => {
      client.destroy();
      reject(new DownstreamClosedError());
    };
    signal.addEventListener("abort", onAbort, { once: true });
    client.on("error", (error) => {
      signal.removeEventListener("abort", onAbort);
      reject(error);
    });
    if (signal.aborted) {
      onAbort();
      return;
    }
    client.end(body);
  });
}

function drainResponse(response) {
  if (response.readableEnded || response.destroyed) {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    response.once("end", resolve);
    response.once("error", resolve);
    response.resume();
  });
}

function shouldRetryStatus(status) {
  return status === 429 || (status >= 500 && status <= 599);
}

function isEventStream(headers) {
  const value = headers["content-type"];
  const contentType = Array.isArray(value) ? value.join(",") : value || "";
  return /^text\/event-stream(?:\s*;|$)/i.test(contentType);
}

function parseSseFrame(frame) {
  const dataLines = [];
  let event = "";
  for (const line of frame.replaceAll("\r\n", "\n").split("\n")) {
    if (!line || line.startsWith(":")) {
      continue;
    }
    const separator = line.indexOf(":");
    const field = separator === -1 ? line : line.slice(0, separator);
    const rawValue = separator === -1 ? "" : line.slice(separator + 1);
    const value = rawValue.startsWith(" ") ? rawValue.slice(1) : rawValue;
    if (field === "event") {
      event = value;
    } else if (field === "data") {
      dataLines.push(value);
    }
  }

  const data = dataLines.join("\n");
  let payload;
  try {
    payload = JSON.parse(data);
  } catch {
    payload = undefined;
  }
  return { event, data, payload };
}

function classifySseFrame(frame) {
  const parsed = parseSseFrame(frame);
  const type = parsed.event || (typeof parsed.payload?.type === "string" ? parsed.payload.type : "");
  const error = parsed.payload?.error ?? parsed.payload?.response?.error;
  const isFailure = type === "error" || type.endsWith(".failed") || error != null;
  const details = JSON.stringify(error ?? (isFailure ? parsed.payload ?? parsed.data : ""));
  if (isFailure && /model(?:[_\s-]+is)?[_\s-]+at[_\s-]+capacity/i.test(details)) {
    return "retry-capacity";
  }
  if ((!type && !parsed.data) || SSE_LIFECYCLE_EVENTS.has(type)) {
    return "continue";
  }
  return "release";
}

function findSseFrameBoundary(text, start) {
  const lf = text.indexOf("\n\n", start);
  const crlf = text.indexOf("\r\n\r\n", start);
  if (lf === -1 && crlf === -1) {
    return null;
  }
  if (crlf !== -1 && (lf === -1 || crlf < lf)) {
    return { start: crlf, end: crlf + 4 };
  }
  return { start: lf, end: lf + 2 };
}

function probeSseResponse(upstreamResponse, signal) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let byteLength = 0;
    let parsedCharacters = 0;
    let settled = false;

    const cleanup = () => {
      signal.removeEventListener("abort", onAbort);
      upstreamResponse.removeListener("data", onData);
      upstreamResponse.removeListener("end", onEnd);
      upstreamResponse.removeListener("error", onError);
    };
    const finish = (error, decision = "release") => {
      if (settled) {
        return;
      }
      settled = true;
      upstreamResponse.pause();
      cleanup();
      if (error) {
        reject(error);
      } else {
        resolve({ decision, buffered: Buffer.concat(chunks, byteLength) });
      }
    };
    const onAbort = () => {
      upstreamResponse.destroy();
      finish(new DownstreamClosedError());
    };
    const onData = (chunk) => {
      chunks.push(chunk);
      byteLength += chunk.length;
      const text = Buffer.concat(chunks, byteLength).toString("utf8");
      let boundary = findSseFrameBoundary(text, parsedCharacters);
      while (boundary) {
        const decision = classifySseFrame(text.slice(parsedCharacters, boundary.start));
        parsedCharacters = boundary.end;
        if (decision !== "continue") {
          finish(null, decision);
          return;
        }
        boundary = findSseFrameBoundary(text, parsedCharacters);
      }
      if (byteLength >= MAX_SSE_PROBE_BYTES) {
        finish(null, "release");
      }
    };
    const onEnd = () => finish(null, "release");
    const onError = (error) => finish(error);

    signal.addEventListener("abort", onAbort, { once: true });
    upstreamResponse.on("data", onData);
    upstreamResponse.once("end", onEnd);
    upstreamResponse.once("error", onError);
    if (signal.aborted) {
      onAbort();
    }
  });
}

function retryLog(logger, request, attempt, details, retryDelayMs) {
  logger(
    `[codex-retry-proxy] ${request.method} ${request.url} attempt ${attempt} failed (${details}); retrying in ${retryDelayMs}ms`,
  );
}

async function handleProxyRequest({ request, response, options }) {
  const { upstream, retryDelayMs, logger } = options;
  if (request.method === "GET" && request.url === HEALTH_PATH) {
    const health = JSON.stringify({
      status: "ok",
      upstream: `${upstream.origin}${upstream.pathname.replace(/\/$/, "")}` || upstream.origin,
    });
    response.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(health) });
    response.end(health);
    return;
  }

  const abortController = new AbortController();
  const { signal } = abortController;
  const abortOnDisconnect = () => {
    if (!response.writableEnded) {
      abortController.abort();
    }
  };
  request.on("aborted", abortOnDisconnect);
  response.on("close", abortOnDisconnect);

  try {
    const body = await readRequestBody(request, signal);
    const headers = forwardRequestHeaders(request.headers, body.length);
    let attempt = 0;
    while (!signal.aborted) {
      attempt += 1;
      try {
        const upstreamResponse = await sendUpstreamAttempt({
          upstream,
          request,
          headers,
          body,
          signal,
        });
        if (shouldRetryStatus(upstreamResponse.statusCode)) {
          const status = upstreamResponse.statusCode;
          await drainResponse(upstreamResponse);
          retryLog(logger, request, attempt, `HTTP ${status}`, retryDelayMs);
          await sleep(retryDelayMs, undefined, { signal });
          continue;
        }

        let buffered = Buffer.alloc(0);
        if (upstreamResponse.statusCode === 200 && isEventStream(upstreamResponse.headers)) {
          const probe = await probeSseResponse(upstreamResponse, signal);
          if (probe.decision === "retry-capacity") {
            upstreamResponse.destroy();
            retryLog(logger, request, attempt, "SSE model at capacity", retryDelayMs);
            await sleep(retryDelayMs, undefined, { signal });
            continue;
          }
          buffered = probe.buffered;
        }

        response.writeHead(upstreamResponse.statusCode, forwardResponseHeaders(upstreamResponse.headers));
        if (buffered.length > 0) {
          response.write(buffered);
        }
        if (upstreamResponse.readableEnded) {
          response.end();
          return;
        }
        upstreamResponse.on("error", (error) => response.destroy(error));
        upstreamResponse.pipe(response);
        return;
      } catch (error) {
        if (signal.aborted) {
          return;
        }
        retryLog(logger, request, attempt, error.code || error.message || error.name, retryDelayMs);
        await sleep(retryDelayMs, undefined, { signal });
      }
    }
  } catch (error) {
    if (!signal.aborted && !response.headersSent) {
      response.writeHead(502, { "content-type": "text/plain" });
      response.end(error.message);
    }
  } finally {
    request.removeListener("aborted", abortOnDisconnect);
    response.removeListener("close", abortOnDisconnect);
  }
}

export function createRetryProxy(options) {
  const normalized = normalizeOptions(options);
  const server = http.createServer((request, response) => {
    handleProxyRequest({ request, response, options: normalized }).catch((error) => {
      if (!response.headersSent && !response.writableEnded) {
        response.writeHead(502, { "content-type": "text/plain" });
        response.end(error.message);
      } else if (!response.writableEnded) {
        response.destroy(error);
      }
    });
  });
  server.requestTimeout = 0;
  server.headersTimeout = 0;
  server.shutdown = () => {
    server.close();
  };
  return server;
}

export function startFromEnvironment(env = process.env) {
  const server = createRetryProxy({
    upstreamBaseUrl: env.CODEX_RETRY_UPSTREAM_URL || "https://ai.input.im",
    retryDelayMs: env.CODEX_RETRY_DELAY_MS || "30000",
    logger: (message) => console.error(message),
  });
  const host = env.CODEX_RETRY_LISTEN_HOST || "127.0.0.1";
  const port = parsePositiveInteger(env.CODEX_RETRY_LISTEN_PORT || "18765", "listen port");
  server.listen(port, host, () => {
    console.error(`[codex-retry-proxy] listening on http://${host}:${port}`);
  });
  const shutdown = () => {
    server.shutdown();
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
  return server;
}

if (isMainModule()) {
  startFromEnvironment();
}
