# Codex Retry Proxy Backup

This directory is a snapshot of the local HTTP retry proxy that was installed
on 2026-08-11 before the CC GUI source patch was tested.

The proxy service is currently stopped and disabled. These files are retained
only so the previous setup can be inspected or restored later.

## Files

- `proxy.mjs`: proxy implementation previously installed at
  `~/.local/share/codex-retry-proxy/proxy.mjs`.
- `proxy.test.mjs`: nine integration tests for retry and streaming behavior.
- `systemd/codex-retry-proxy.service`: the user systemd unit previously
  installed at `~/.config/systemd/user/codex-retry-proxy.service`.
- `SHA256SUMS`: hashes of the three original snapshot files.

No Codex authentication file, API key, session log, or user configuration is
included. `Bearer secret` in the test file is a fixed test value.

## Verify The Snapshot

```bash
rtk sha256sum -c backups/codex-retry-proxy/SHA256SUMS
rtk node --test backups/codex-retry-proxy/proxy.test.mjs
```

The tests bind temporary loopback ports. Run them outside a network-restricted
sandbox.

## Restore

The archived systemd unit contains the original absolute paths for user
`develop`. Adjust them first when restoring under another account or location.

```bash
rtk install -Dm644 backups/codex-retry-proxy/proxy.mjs \
  /home/develop/.local/share/codex-retry-proxy/proxy.mjs
rtk install -Dm644 backups/codex-retry-proxy/proxy.test.mjs \
  /home/develop/.local/share/codex-retry-proxy/proxy.test.mjs
rtk install -Dm644 backups/codex-retry-proxy/systemd/codex-retry-proxy.service \
  /home/develop/.config/systemd/user/codex-retry-proxy.service
rtk systemctl --user daemon-reload
rtk systemctl --user enable --now codex-retry-proxy.service
```

Enabling the service only starts the listener. A client uses it only when its
base URL is explicitly set to `http://127.0.0.1:18765`.

## Stop Again

```bash
rtk systemctl --user disable --now codex-retry-proxy.service
```
