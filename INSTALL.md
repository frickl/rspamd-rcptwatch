# Installation — Rspamd RCPTWatch

This guide installs **Rspamd RCPTWatch** on an existing Postfix/Rspamd submission server. It counts unique SMTP envelope recipients per **authenticated SASL account** and issues zero-score alerts through Rspamd's `metadata_exporter`. It does not reject or throttle mail.

> **Deployment status:** Field-tested proof of concept. Install on a private/test server first. Keep the existing rate limiter enabled. Test against your particular Rspamd version and Redis configuration before deploying more widely.

## 1. Prerequisites

- A working Rspamd installation with Lua support, `lua_redis`, `rspamd_cryptobox_hash`, and the `metadata_exporter` plugin.
- A Postfix MSA (normally port 587 or 465) already passing the authenticated SASL username to Rspamd. Rspamd's task log must show `user: <account>` for a submitted mail.
- A Redis instance accessible to Rspamd. Existing Rspamd Redis settings may be reused; no persistence is required for the default advisory mode.
- A reachable SMTP relay that accepts notification messages from Rspamd.
- Administrative access to `/etc/rspamd/` and permission to restart Rspamd.

These instructions use Debian-style paths. Adjust paths and service names for other distributions. **Back up existing configuration before editing.** Do not copy anything into `/usr/share/rspamd/`.

## 2. Get the source

```sh
git clone https://github.com/frickl/rspamd-rcptwatch.git
cd rspamd-rcptwatch
```

If you already cloned the project, work in the repository's root directory.

## 3. Install the two different Lua files

The two files run in **different interpreters**. Only one belongs in `lua.local.d`.

```sh
sudo install -d -m 0755 /etc/rspamd/lua.local.d /etc/rspamd/local.d

# Rspamd Lua module: automatically loaded by the Rspamd rule loader
sudo install -m 0644 rspamd/outbound_guard.lua \
  /etc/rspamd/lua.local.d/outbound_guard.lua

# Redis EVAL script: read by the Rspamd module, executed inside Redis
sudo install -m 0644 redis/record.lua \
  /etc/rspamd/local.d/outbound_guard_record.lua
```

**Never install `record.lua` as `/etc/rspamd/lua.local.d/outbound_guard_record.lua`.** Rspamd would execute it directly during startup and fail with `attempt to index global 'ARGV' (a nil value)`. Ensure Rspamd's service user can read both files.

## 4. Install and include the configuration

```sh
sudo install -m 0644 examples/outbound_guard.conf \
  /etc/rspamd/local.d/outbound_guard.conf
```

Edit `/etc/rspamd/local.d/outbound_guard.conf` to suit your deployment. The supplied defaults are:

```ucl
outbound_guard {
    enabled = true;
    window = 21600;          # 6 hours of inactivity
    max_recipients = 50;     # alarm when active distinct count becomes 51
    alert_cooldown = 21600;  # once per user per cooldown
    key_prefix = "outguard:v1:";
    script_path = "/etc/rspamd/local.d/outbound_guard_record.lua";
}
```

This is a **complete top-level block**, not a module snippet that Rspamd automatically discovers. Add the following line **once** to `/etc/rspamd/rspamd.conf.local` (create the file if absent):

```ucl
.include(try=true) "$LOCAL_CONFDIR/local.d/outbound_guard.conf"
```

Do not duplicate the include if the section is already included elsewhere. If `lua_redis` cannot find your shared Redis settings, configure the Redis server and credentials according to your Rspamd installation (do not publish secrets in the repository).

## 5. Set zero-score symbols

Merge the definitions in `examples/groups.conf` into your existing `/etc/rspamd/local.d/groups.conf` as appropriate. **Do not overwrite existing groups.** The symbols `OUTGUARD_OBSERVE`, `OUTGUARD_ALERT`, and `OUTGUARD_REDIS_ERROR` must remain at score `0.0`.

The module's callback is `OUTGUARD_CHECK`. Its `ignore_passthrough` flag is intentional: outbound counting must still run when a whitelist has already set a `no action` result. Its virtual symbols use the numeric parent ID returned by `register_symbol`.

## 6. Configure administrator email notification

RCPTWatch uses Rspamd's existing `metadata_exporter` plugin directly. **No extra Python mail-monitor, queue processor, multimap rule, or dependency on Spamprobe/AISSA is needed.**

**Merge**, do not replace, the `outguard_alert` selector and `outguard_smtp` rule from `examples/metadata_exporter-additions.conf` into `/etc/rspamd/local.d/metadata_exporter.conf`. In particular, preserve any other `custom_select` selectors and `rules` entries already present.

Configure the following values in `outguard_smtp`:

```ucl
smtp = "127.0.0.1";                 # your permitted SMTP relay
mail_to = "postmaster@example.org"; # administrator mailbox
mail_from = "outguard@example.org"; # permitted envelope sender
```

The example uses `backend = send_mail`, `selector = outguard_alert`, `formatter = email_alert`, and a custom email template. The selector returns `task:has_symbol('OUTGUARD_ALERT')`. The alert email includes the authenticated user, triggering queue ID, SMTP sender, and plaintext SMTP recipient list for human abuse triage. Redis does **not** store those recipient addresses in plaintext.

The exported alert is a separate message. Make sure your relay accepts it, that recipient routing works, and that the destination mailbox is appropriately restricted. If logging the selector for troubleshooting, import `rspamd_logger` explicitly within the selector; it is not automatically a global.

## 7. Validate configuration and restart

```sh
sudo rspamadm configtest
sudo rspamadm configdump outbound_guard
sudo rspamadm configdump metadata_exporter
sudo systemctl restart rspamd
```

`configtest` should report `syntax OK`, and `configdump outbound_guard` should display `enabled = true` and the expected `script_path`.

Check Rspamd's actual log destination (commonly `/var/log/rspamd/rspamd.log`):

```sh
sudo grep -Ei 'outbound_guard|outguard|lua_redis' /var/log/rspamd/rspamd.log | tail -30
```

`use default Redis settings for outbound_guard` is normal when shared Redis settings work. Errors about virtual symbols having `no parent` mean you are using an older or modified Lua module; update the symbol registration from this repository.

## 8. Verify recipient counting

Submit a test email **through authenticated MSA submission**, not an unauthenticated inbound SMTP connection. A valid Rspamd task should show a nonempty `user:`.

1. First mail to recipient A: `OUTGUARD_OBSERVE(0.00){1/50;new=1;}`.
2. Repeat to recipient A: `OUTGUARD_OBSERVE(0.00){1/50;new=0;}`.
3. Mail to recipient B: `OUTGUARD_OBSERVE(0.00){2/50;new=1;}`.
4. Test one message with To, Cc and Bcc recipients. The module counts the **SMTP RCPT TO list**, including Bcc, rather than header addresses.

For a controlled threshold test on a private system, temporarily set `max_recipients = 4`, restart Rspamd, and submit to five distinct recipients from a test account. Expect `OUTGUARD_ALERT(0.00){5/4;}` and an independent `[OUTGUARD]` admin message. Remember that an active `alert_cooldown` suppresses subsequent alerts. Restore the intended threshold afterwards.

A task can be scanned more than once during downstream reinjection. The module ignores tasks without an authenticated user; verify that only the intended MSA scan records recipients in your topology.

## 9. Inspect Redis safely

Use the same Redis host, database, and authentication as Rspamd. In `redis-cli`, a single `SCAN 0` is **not** a full enumeration: follow returned cursors until `0`, or use the CLI iterator:

```sh
redis-cli --scan --pattern 'outguard:v1:*'
redis-cli HGETALL outguard:v1:metrics
```

Key suffixes are hashed, so no plaintext account name will appear in per-user relationship keys. A sorted set tracks the most recent contact time for each relationship, and a hash tracks per-relationship processed-message counts. The `:alert` key implements cooldown. **Do not use `FLUSHDB` or unbounded `KEYS *` on shared production Redis.** Prefer a separate test prefix or dedicated test Redis.

**Window semantics:** The default six hours are measured since each recipient was *last seen*. Repeatedly contacted recipients remain active, potentially for longer than six hours. The per-recipient count accumulates until the relationship expires. This is **not an exact rolling six-hour event window**. Redis restarts or eviction can reset the advisory state without blocking delivery.

## 10. Optional Prometheus metrics

Prometheus integration is optional. The repository includes a **one-shot** Python textfile exporter, not a resident monitoring/notification daemon. It can be scheduled periodically with your own cron/systemd timer and read by Prometheus `node_exporter`'s textfile collector.

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-metrics.txt

OUTGUARD_REDIS_URL='redis://127.0.0.1:6379/0' \
  .venv/bin/python prometheus/export_textfile.py \
  --output /var/lib/node_exporter/textfile_collector/outguard.prom
```

Configure the actual Redis URL and a writable output directory; create an appropriate systemd timer/cron entry according to your environment. If Redis authentication is used, supply credentials through a **protected service environment or secret file**, not via command lines committed to Git or public logs.

Metrics: `outguard_messages_total`, `outguard_recipients_total`, `outguard_new_relationships_total`, `outguard_alerts_total`, and `outguard_redis_up`. There are **no per-user labels**. Redis counters can reset after a restart or key expiration; monitor textfile freshness separately.

## 11. Troubleshooting

| Symptom | Check |
| --- | --- |
| `Section outbound_guard NOT FOUND` | Add the top-level include in `rspamd.conf.local` (section 4). |
| `ARGV` is nil during `configtest` | Redis EVAL script is incorrectly under `lua.local.d`; move it into `local.d`. |
| No OUTGUARD symbol | Check that `outbound_guard.lua` is under `lua.local.d`, the callback runs, and `task:get_user()` is present. |
| Redis error / no keys | Check Rspamd shared Redis settings, script permissions, chosen DB and prefix. |
| `no parent` virtual symbol warning | Use numeric ID returned by `register_symbol`, as in checked-in module. |
| `OUTGUARD_OBSERVE` but no alert | Threshold is strictly greater-than, or alert cooldown is still active. |
| `OUTGUARD_ALERT` but no email | Check `metadata_exporter` rule merge, selector, SMTP relay, mail queue, and destination mailbox. |
| Selector error: `rspamd_logger` is nil | Use `local logger = require 'rspamd_logger'` inside custom selector source. |
| Repeated outbound checks seem missing | Verify `ignore_passthrough` for whitelisted submissions and distinguish reinjection scans. |

See [`docs/OPERATIONS.md`](docs/OPERATIONS.md) for more details.

## 12. Disable / uninstall

To disable monitoring without touching files:

```ucl
outbound_guard {
    enabled = false;
}
```

Set `enabled = false` **in your existing `outbound_guard.conf` block**, do not create a second block. Then run `rspamadm configtest` and restart Rspamd.

For complete removal: remove the module from `lua.local.d`, the Redis EVAL script, the local config block and its top-level include, and just the RCPTWatch selector/rule/group entries (keep other integrations intact); restart after a successful config test. Redis test-state keys may be allowed to expire naturally. Remove the optional collector/timer and `.prom` file if installed.

## Privacy and security notes

SHA-256 hashing of `(authenticated user, recipient)` is deterministic **pseudonymization, not anonymization**. Limit Redis access, set a defensible retention policy and protect admin alerts containing plaintext addresses. For stronger protections, consider a secret-keyed HMAC implementation. RCPTWatch is an advisory signal and does not replace standard outbound rate limits, content filtering, or account security controls.
