#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const CLIENT_INFO = {
  name: 'ccgui_retry_fork_verifier',
  title: 'CC GUI Retry Fork Verifier',
  version: '0.5.2-retry.7',
};

function parseArgs(argv) {
  const options = { codex: 'codex', threadId: null, lastTurnId: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--codex') options.codex = argv[++index];
    else if (argument === '--thread-id') options.threadId = argv[++index];
    else if (argument === '--last-turn-id') options.lastTurnId = argv[++index];
    else throw new Error('invalid_arguments');
  }
  if (!options.codex) throw new Error('invalid_arguments');
  return options;
}

function createConnection(executablePath) {
  const child = spawn(executablePath, ['app-server', '--stdio'], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const pending = new Map();
  let nextId = 0;
  let fatalError = null;
  let stderrSeen = false;

  const fail = (error) => {
    if (!fatalError) fatalError = error;
    const waiters = [...pending.values()];
    pending.clear();
    for (const waiter of waiters) waiter.reject(fatalError);
  };

  lines.on('line', (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      fail(new Error('malformed_app_server_output'));
      return;
    }
    if (!Object.hasOwn(message, 'id')) return;
    const waiter = pending.get(message.id);
    if (!waiter) {
      fail(new Error('unexpected_app_server_response'));
      return;
    }
    pending.delete(message.id);
    if (message.error) {
      const error = new Error('app_server_rpc_error');
      error.rpcCode = message.error.code;
      waiter.reject(error);
      return;
    }
    waiter.resolve(message.result);
  });
  child.stderr.on('data', () => {
    stderrSeen = true;
  });
  child.once('error', () => fail(new Error('app_server_spawn_error')));
  child.once('close', () => {
    if (pending.size > 0) fail(new Error('app_server_closed_early'));
  });

  const send = (message) => {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  };
  const request = (method, params) => {
    if (fatalError) return Promise.reject(fatalError);
    const id = nextId++;
    const response = new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
    });
    send({ method, id, params });
    return response;
  };

  return {
    request,
    notify(method, params) {
      send({ method, params });
    },
    get stderrSeen() {
      return stderrSeen;
    },
    async close() {
      lines.close();
      try {
        child.stdin.end();
      } catch {
        // Process termination remains authoritative.
      }
      if (!child.killed) child.kill('SIGTERM');
      await new Promise((resolve) => {
        if (child.exitCode !== null || child.signalCode !== null) resolve();
        else child.once('close', resolve);
      });
    },
  };
}

function completedTurns(thread) {
  return Array.isArray(thread?.turns)
    ? thread.turns.filter((turn) => turn?.status === 'completed' && typeof turn.id === 'string')
    : [];
}

async function selectSource(connection, requestedThreadId) {
  if (requestedThreadId) {
    const result = await connection.request('thread/read', {
      threadId: requestedThreadId,
      includeTurns: true,
    });
    return result.thread;
  }

  let cursor = null;
  for (let page = 0; page < 10; page += 1) {
    const result = await connection.request('thread/list', {
      cursor,
      limit: 100,
      sortKey: 'updated_at',
      sortDirection: 'desc',
    });
    for (const summary of result?.data ?? []) {
      if (typeof summary?.id !== 'string') continue;
      try {
        const read = await connection.request('thread/read', {
          threadId: summary.id,
          includeTurns: true,
        });
        if (completedTurns(read.thread).length >= 2) return read.thread;
      } catch {
        // A concurrently active or removed thread is not a suitable fixture.
      }
    }
    cursor = result?.nextCursor ?? null;
    if (!cursor) break;
  }
  throw new Error('no_completed_source_thread');
}

function selectBoundary(source, requestedTurnId) {
  const turns = Array.isArray(source?.turns) ? source.turns : [];
  if (requestedTurnId) {
    const index = turns.findIndex((turn) => turn?.id === requestedTurnId);
    if (index < 0 || turns[index]?.status !== 'completed') {
      throw new Error('invalid_completed_boundary');
    }
    return { id: requestedTurnId, index };
  }
  const index = turns.findIndex((turn) => turn?.status === 'completed');
  if (index < 0) throw new Error('no_completed_boundary');
  return { id: turns[index].id, index };
}

function threadFingerprint(thread) {
  return (thread?.turns ?? []).map((turn) => `${turn.id}:${turn.status}`);
}

async function verify(options) {
  const connection = createConnection(options.codex);
  let childId = null;
  let childDeleted = false;
  try {
    await connection.request('initialize', { clientInfo: CLIENT_INFO });
    connection.notify('initialized', {});

    const source = await selectSource(connection, options.threadId);
    const sourceBefore = threadFingerprint(source);
    const boundary = selectBoundary(source, options.lastTurnId);
    const fork = await connection.request('thread/fork', {
      threadId: source.id,
      lastTurnId: boundary.id,
    });
    childId = fork?.thread?.id ?? null;
    if (!childId || childId === source.id) throw new Error('invalid_child_thread');

    const childRead = await connection.request('thread/read', {
      threadId: childId,
      includeTurns: true,
    });
    const childFingerprint = threadFingerprint(childRead.thread);
    const expectedPrefix = sourceBefore.slice(0, boundary.index + 1);
    if (JSON.stringify(childFingerprint) !== JSON.stringify(expectedPrefix)) {
      throw new Error('fork_prefix_mismatch');
    }

    const sourceAfterRead = await connection.request('thread/read', {
      threadId: source.id,
      includeTurns: true,
    });
    const sourceAfter = threadFingerprint(sourceAfterRead.thread);
    if (JSON.stringify(sourceAfter) !== JSON.stringify(sourceBefore)) {
      throw new Error('source_changed_during_fork');
    }

    await connection.request('thread/delete', { threadId: childId });
    childDeleted = true;
    try {
      await connection.request('thread/read', {
        threadId: childId,
        includeTurns: false,
      });
      throw new Error('deleted_child_still_readable');
    } catch (error) {
      if (error.message === 'deleted_child_still_readable') throw error;
    }

    return {
      sourceIdMatches: sourceAfterRead.thread.id === source.id,
      sourceTurnCountBefore: sourceBefore.length,
      boundaryIndex: boundary.index,
      childIdDiffers: childId !== source.id,
      childTurnCount: childFingerprint.length,
      childIsExactPrefix: true,
      sourceTurnCountAfter: sourceAfter.length,
      sourceUnchanged: true,
      childDeleted,
      stderrSeen: connection.stderrSeen,
    };
  } finally {
    if (childId && !childDeleted) {
      try {
        await connection.request('thread/delete', { threadId: childId });
      } catch {
        // The verification error remains primary; no IDs or content are logged.
      }
    }
    await connection.close();
  }
}

try {
  const result = await verify(parseArgs(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} catch (error) {
  process.stderr.write(`Codex fork verification failed: ${error?.message || 'unknown_error'}\n`);
  process.exitCode = 1;
}
