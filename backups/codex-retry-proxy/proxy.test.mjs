import assert from "node:assert/strict";
import { once } from "node:events";
import http from "node:http";
import test from "node:test";

import { createRetryProxy } from "./proxy.mjs";

async function listen(server, port = 0) {
  server.listen(port, "127.0.0.1");
  await once(server, "listening");
  return server.address().port;
}

async function close(server) {
  if (!server.listening) {
    return;
  }
  server.close();
  await once(server, "close");
}

function request({ port, path = "/responses", method = "POST", headers = {}, body = "", timeoutMs = 1_000 }) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: "127.0.0.1", port, path, method, headers },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            body: Buffer.concat(chunks).toString(),
          });
        });
      },
    );
    req.on("error", reject);
    req.setTimeout(timeoutMs, () => req.destroy(new Error("request timed out")));
    req.end(body);
  });
}

function sseEvent(type, payload) {
  return `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
}

async function unusedPort() {
  const server = http.createServer();
  const port = await listen(server);
  await close(server);
  return port;
}

test("health endpoint responds locally without contacting upstream", async (t) => {
  const upstreamPort = await unusedPort();
  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs: 10,
    logger: () => {},
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  const response = await request({
    port: proxyPort,
    path: "/_codex_retry_proxy/health",
    method: "GET",
  });

  assert.equal(response.statusCode, 200);
  assert.deepEqual(JSON.parse(response.body), {
    status: "ok",
    upstream: `http://127.0.0.1:${upstreamPort}`,
  });
});

test("retries HTTP 429 and 5xx after a fixed delay and preserves the request", async (t) => {
  const attempts = [];
  const upstream = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      attempts.push({
        time: Date.now(),
        method: req.method,
        url: req.url,
        authorization: req.headers.authorization,
        body: Buffer.concat(chunks).toString(),
      });
      const failureStatuses = [502, 503, 429];
      if (attempts.length <= failureStatuses.length) {
        res.writeHead(failureStatuses[attempts.length - 1]).end("retryable error");
      } else {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.end("data: complete\n\n");
      }
    });
  });
  const upstreamPort = await listen(upstream);
  t.after(() => close(upstream));

  const retryDelayMs = 40;
  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs,
    logger: () => {},
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  const response = await request({
    port: proxyPort,
    path: "/responses?trace=1",
    headers: {
      authorization: "Bearer secret",
      "content-type": "application/json",
    },
    body: '{"model":"test"}',
  });

  assert.equal(response.statusCode, 200);
  assert.equal(response.headers["content-type"], "text/event-stream");
  assert.equal(response.body, "data: complete\n\n");
  assert.equal(attempts.length, 4);
  assert.ok(attempts[1].time - attempts[0].time >= retryDelayMs - 5);
  assert.ok(attempts[2].time - attempts[1].time >= retryDelayMs - 5);
  assert.ok(attempts[3].time - attempts[2].time >= retryDelayMs - 5);
  for (const attempt of attempts) {
    assert.equal(attempt.method, "POST");
    assert.equal(attempt.url, "/responses?trace=1");
    assert.equal(attempt.authorization, "Bearer secret");
    assert.equal(attempt.body, '{"model":"test"}');
  }
});

test("retries an HTTP 200 SSE capacity failure before output", async (t) => {
  const attempts = [];
  const upstream = http.createServer((_req, res) => {
    attempts.push(Date.now());
    res.writeHead(200, { "content-type": "text/event-stream" });
    if (attempts.length === 1) {
      res.write(
        sseEvent("response.created", {
          type: "response.created",
          response: { status: "in_progress" },
        }),
      );
      setTimeout(() => {
        res.end(
          sseEvent("response.failed", {
            type: "response.failed",
            response: {
              status: "failed",
              error: {
                code: "server_error",
                message: "Selected model is at capacity. Please try a different model.",
              },
            },
          }),
        );
      }, 5);
      return;
    }
    res.end(
      sseEvent("response.output_text.delta", {
        type: "response.output_text.delta",
        delta: "available",
      }),
    );
  });
  const upstreamPort = await listen(upstream);
  t.after(() => close(upstream));

  const retryDelayMs = 30;
  const logs = [];
  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs,
    logger: (message) => logs.push(message),
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  const response = await request({ port: proxyPort });

  assert.equal(response.statusCode, 200);
  assert.equal(attempts.length, 2);
  assert.ok(attempts[1] - attempts[0] >= retryDelayMs - 5);
  assert.equal(
    response.body,
    sseEvent("response.output_text.delta", {
      type: "response.output_text.delta",
      delta: "available",
    }),
  );
  assert.equal(logs.length, 1);
  assert.match(logs[0], /SSE model at capacity/);
});

test("forwards a non-capacity HTTP 200 SSE failure without retrying", async (t) => {
  let attempts = 0;
  const failure = sseEvent("response.failed", {
    type: "response.failed",
    response: {
      status: "failed",
      error: { code: "invalid_request", message: "Invalid request." },
    },
  });
  const upstream = http.createServer((_req, res) => {
    attempts += 1;
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.end(failure);
  });
  const upstreamPort = await listen(upstream);
  t.after(() => close(upstream));

  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs: 10,
    logger: () => {},
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  const response = await request({ port: proxyPort });

  assert.equal(attempts, 1);
  assert.equal(response.statusCode, 200);
  assert.equal(response.body, failure);
});

test("does not retry an SSE capacity failure after output begins", async (t) => {
  let attempts = 0;
  const output = sseEvent("response.output_text.delta", {
    type: "response.output_text.delta",
    delta: "started",
  });
  const failure = sseEvent("response.failed", {
    type: "response.failed",
    response: {
      status: "failed",
      error: { code: "model_at_capacity", message: "Selected model is at capacity." },
    },
  });
  const upstream = http.createServer((_req, res) => {
    attempts += 1;
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.end(output + failure);
  });
  const upstreamPort = await listen(upstream);
  t.after(() => close(upstream));

  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs: 10,
    logger: () => {},
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  const response = await request({ port: proxyPort });

  assert.equal(attempts, 1);
  assert.equal(response.statusCode, 200);
  assert.equal(response.body, output + failure);
});

test("forwards HTTP 400, 401, and 403 without retrying", async (t) => {
  const attempts = new Map();
  const upstream = http.createServer((req, res) => {
    const status = Number(new URL(req.url, "http://upstream.invalid").searchParams.get("status"));
    attempts.set(status, (attempts.get(status) || 0) + 1);
    res.writeHead(status, { "x-upstream-status": String(status) });
    res.end(`upstream ${status}`);
  });
  const upstreamPort = await listen(upstream);
  t.after(() => close(upstream));

  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs: 10,
    logger: () => {},
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  for (const status of [400, 401, 403]) {
    const response = await request({ port: proxyPort, path: `/responses?status=${status}` });
    assert.equal(response.statusCode, status);
    assert.equal(response.headers["x-upstream-status"], String(status));
    assert.equal(response.body, `upstream ${status}`);
    assert.equal(attempts.get(status), 1);
  }
});

test("retries network failures until the upstream becomes available", async (t) => {
  const upstreamPort = await unusedPort();
  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs: 20,
    logger: () => {},
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  const responsePromise = request({ port: proxyPort, method: "GET" });
  await new Promise((resolve) => setTimeout(resolve, 55));

  const upstream = http.createServer((_req, res) => res.end("online"));
  await listen(upstream, upstreamPort);
  t.after(() => close(upstream));

  const response = await responsePromise;
  assert.equal(response.statusCode, 200);
  assert.equal(response.body, "online");
});

test("streams a successful upstream response without buffering it", async (t) => {
  let upstreamFinished = false;
  const firstEvent = sseEvent("response.output_text.delta", {
    type: "response.output_text.delta",
    delta: "first",
  });
  const upstream = http.createServer((_req, res) => {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(firstEvent);
    setTimeout(() => {
      upstreamFinished = true;
      res.end(
        sseEvent("response.output_text.delta", {
          type: "response.output_text.delta",
          delta: "second",
        }),
      );
    }, 80);
  });
  const upstreamPort = await listen(upstream);
  t.after(() => close(upstream));

  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs: 10,
    logger: () => {},
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  const firstChunk = await new Promise((resolve, reject) => {
    const req = http.get(`http://127.0.0.1:${proxyPort}/responses`, (res) => {
      res.once("data", (chunk) => resolve(chunk.toString()));
    });
    req.on("error", reject);
  });

  assert.equal(firstChunk, firstEvent);
  assert.equal(upstreamFinished, false);
});

test("stops retrying when the downstream client disconnects", async (t) => {
  let attempts = 0;
  let firstAttempt;
  const firstAttemptSeen = new Promise((resolve) => {
    firstAttempt = resolve;
  });
  const upstream = http.createServer((_req, res) => {
    attempts += 1;
    res.writeHead(503).end();
    firstAttempt();
  });
  const upstreamPort = await listen(upstream);
  t.after(() => close(upstream));

  const proxy = createRetryProxy({
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    retryDelayMs: 20,
    logger: () => {},
  });
  const proxyPort = await listen(proxy);
  t.after(() => close(proxy));

  const downstream = http.get(`http://127.0.0.1:${proxyPort}/responses`);
  downstream.on("error", () => {});
  await firstAttemptSeen;
  downstream.destroy();
  await new Promise((resolve) => setTimeout(resolve, 70));

  assert.equal(attempts, 1);
});
