# Rspamd RCPTWatch

**Recipient-diversity monitoring for authenticated SMTP submission using Rspamd Lua and Redis.**

Rspamd RCPTWatch watches how many *distinct SMTP envelope recipients* an authenticated submission account has contacted recently. Repeated forwarding to the same destination counts as one active recipient relationship, regardless of message volume. When an account exceeds a configured diversity threshold, Rspamd emits a zero-score alert and can send an administrator email using its existing `metadata_exporter` plugin.

The project is intended for mail administrators running Postfix + Rspamd. It is **observe-and-notify only**: no SMTP rejection, account locking or password resets. Its purpose is to complement conventional outgoing-message rate limits, not replace them for all abuse cases.

> **Status: field-tested proof of concept, not hardened production software.** Core behavior (authenticated user detection, To/Cc/Bcc envelope recipient accounting, repeat recipient handling, Redis counters, threshold and cooldown, `OUTGUARD_ALERT`, and an SMTP admin alert through `metadata_exporter`) was tested on a private Rspamd/Postfix setup in October 2026. Exact versions and Redis test automation are not independently verified in this repository. Evaluate on a private mail server before wider deployment.

## Motivation

A conventional `max_email_sent` limit penalizes a legitimate account forwarding thousands of incoming messages to the same personal mailbox. A compromised account, however, often emits messages to many unrelated recipients. A useful additional signal is therefore:

**Distinct active recipient relationships per authenticated SMTP account, rather than raw message count.**

| Scenario | Messages | Distinct active envelope recipients | Signal |
| --- | ---: | ---: | --- |
| Forwarding to one personal mailbox | 5,000 | 1 | Not unusual by diversity alone |
| Normal correspondence | 30 | 12 | Below a sample limit of 50 |
| One message to 80 contacts | 1 | 80 | Over the sample limit |
| Compromised submission account | 150 | 145 | Suspicious diversity |
| 500 messages to three addresses | 500 | 3 | Requires other abuse controls |

This is one signal, **not proof of spam**. Mailing lists, customer support systems, role accounts and new users can legitimately contact many recipients. Single-destination flooding is not caught by diversity monitoring.

## Architecture

```text
Postfix MSA (465/587, SASL authenticated)
  -> Rspamd scan / OUTGUARD_CHECK
     -> Redis EVAL (atomic cleanup, last_seen, counters, threshold, cooldown)
     <- active_count, new_count, alarm
  -> OUTGUARD_OBSERVE (score 0)
  -> OUTGUARD_ALERT (score 0, only new alarms)
     -> Rspamd metadata_exporter outguard_smtp
        -> SMTP -> administrator mailbox

Redis metrics hash -> optional one-shot textfile collector -> Prometheus node_exporter
```

There is **no Python mail-monitor daemon** and no Redis alarm queue in this version. Admin emails go directly through Rspamd's existing `metadata_exporter` SMTP backend. The optional Python script is only a periodic metrics bridge for operators who use Prometheus node_exporter's textfile collector.

## Semantics

- Identity: authenticated SASL username from `task:get_user()`, **not** the arbitrary envelope MAIL FROM sender.
- Recipient input: `task:get_recipients('smtp')`, which includes To, Cc and Bcc SMTP `RCPT TO` addresses; the visible headers are not the source of truth.
- Pair key: `SHA256(lowercase(auth_user) || NUL || lowercase(envelope_recipient))`. The separator avoids ambiguous concatenation. The Redis user-key suffix is separately SHA256-hashed.
- Scope: `(auth_user, recipient pair hash)` with per-user isolation. Each recipient is deduplicated within an individual scan.
- Per recipient: ZSET score is Unix `last_seen`; HASH value is the number of processed messages addressed to that recipient *since the relationship was last expired*.
- Expiration: on each scan for that account, entries not contacted within the configured inactivity period are removed. An active relationship may persist indefinitely if it is continually contacted. This is **not** a strict six-hour event-time sliding-window count.
- Threshold: alarm when active distinct recipient count is **greater than** `max_recipients` (50 -> 51st).
- Cooldown: `SET ... NX EX` limits fresh alarm events per user. After cooldown expires, a further submitted message can generate another alert if the count remains above threshold, even without a new recipient.
- Multiple messages or same recipient: increment per-recipient count; do not increment distinct count.
- Redis outage: fail open and report `OUTGUARD_REDIS_ERROR`; statistics may reset after restart/eviction. Redis persistence is not required for the intended short-lived monitoring.
- Counter interpretation: counts represent scans, not guaranteed completed Postfix deliveries. Retry/reinject behavior must be assessed; the callback skips tasks without an authenticated user.

Redis keys (`outguard:v1:` by default):

| Key | Type | Contents |
| --- | --- | --- |
| `<prefix><sha256(user)>:z` | Sorted set | Pair hash -> last_seen timestamp |
| `<prefix><sha256(user)>:h` | Hash | Pair hash -> message count |
| `<prefix><sha256(user)>:alert` | String + TTL | Alert cooldown |
| `<prefix>metrics` | Hash + TTL | messages, recipients, new_relationships, alerts |

Note: `metrics` is a **short-lived, resetting aggregate** (TTL `window + 3600`, refreshed by traffic). Exposing these Redis values as Prometheus `_total` counters is convenient for a PoC, but a Redis restart/expiry can reset them. Prometheus should tolerate resets; do not assume accounting-grade continuity. The exporter reports Redis availability but not Redis command failures inside an individual Rspamd scan.

## Repository layout

```text
rspamd/outbound_guard.lua               Rspamd callback and virtual symbols
redis/record.lua                        Atomic Redis script, EVAL via Rspamd
examples/outbound_guard.conf            Main settings, example local include
examples/metadata_exporter-additions.conf  Standalone Rspamd RCPTWatch selector/rule
examples/groups.conf                    Zero-score symbol definitions
prometheus/export_textfile.py           Optional one-shot metrics exporter
requirements-metrics.txt                Optional redis-py dependency
tests/                                  Automated Redis and exporter tests
docs/OPERATIONS.md                      Troubleshooting and runbook
LICENSE                                 MIT
```

## Requirements

- Postfix (or another MSA) passing SASL authentication identity to Rspamd.
- Rspamd with Lua rule loading, `rspamd_cryptobox_hash`, `lua_redis` and `metadata_exporter`.
- Redis reachable using Rspamd's configured Redis credentials; no persistence requirement for initial experiments.
- An SMTP relay that accepts the `metadata_exporter` notification.
- Optional: Python 3, `redis-py`, Prometheus node_exporter textfile collector.

The callback's `rspamd_cryptobox_hash` and `lua_redis` interfaces should be verified against your installed Rspamd release. The tested private deployment ran Rspamd with a shared Redis configuration and existing outbound filtering; this repository is not packaged as an official Rspamd plugin.

## Installation (safe local-only paths)

All custom Rspamd files reside under `/etc/rspamd`, not distribution-managed `/usr/share/rspamd/` paths.

1. Install the **Rspamd module**:

   ```sh
   install -m 0644 rspamd/outbound_guard.lua /etc/rspamd/lua.local.d/outbound_guard.lua
   ```

   Rspamd automatically loads `lua.local.d/*.lua`.

2. Install the **Redis Lua EVAL script** (as a data file):

   ```sh
   install -m 0644 redis/record.lua /etc/rspamd/local.d/outbound_guard_record.lua
   ```

   **Never put `record.lua` in `lua.local.d/`**. Redis has `ARGV` and `KEYS`; Rspamd's Lua runtime does not. Misplacing it prevents Rspamd configuration from loading.

3. Install configuration:

   ```sh
   install -m 0644 examples/outbound_guard.conf /etc/rspamd/local.d/outbound_guard.conf
   ```

   Rspamd does not automatically include arbitrary `local.d/` files. Because this file contains the complete `outbound_guard { ... }` block, add a top-level include in `/etc/rspamd/rspamd.conf.local`:

   ```ucl
   .include(try=true) "$LOCAL_CONFDIR/local.d/outbound_guard.conf"
   ```

   If your environment includes the section another way, do not duplicate it.

4. **Merge** `examples/groups.conf` with your existing `/etc/rspamd/local.d/groups.conf` (do not overwrite other groups). All Rspamd RCPTWatch symbols remain score `0.0`.

5. **Merge** the `outguard_alert` selector and `outguard_smtp` rule from `examples/metadata_exporter-additions.conf` into your current `/etc/rspamd/local.d/metadata_exporter.conf`. Preserve unrelated selectors and rules (such as `spamprobe_smtp`). Configure your own `smtp`, `mail_to`, and `mail_from` values. No external map or `multimap` rule is required: `OUTGUARD_ALERT` is emitted directly by this module, and the exporter uses `task:has_symbol('OUTGUARD_ALERT')`.

6. Verify and restart:

   ```sh
   rspamadm configtest
   rspamadm configdump outbound_guard
   rspamadm configdump metadata_exporter
   systemctl restart rspamd
   ```

7. Send a test message via authenticated submission. Expect `OUTGUARD_OBSERVE(0.00){1/50;new=1;}`. Send again to same recipient, expect `new=0`. Send to a new recipient, expect `2/50;new=1`. Test To/Cc/Bcc; count actual `RCPT TO` recipients.

8. In a **dedicated test environment**, temporarily lower `max_recipients` to 4, restart Rspamd, and send to five distinct recipients. Expect `OUTGUARD_ALERT(0.00){5/4;}`, followed by a separate `[OUTGUARD]` notification in the administrator mailbox. Allow for cooldown before another alarm. **Restore the intended threshold** (e.g. 50) after testing.

You can inspect the Redis metric hash using authenticated `redis-cli`:

```sh
redis-cli --scan --pattern 'outguard:v1:*'  # supply credentials/DB securely
redis-cli HGETALL outguard:v1:metrics
```

Be aware that an interactive Redis `SCAN 0` response may have an empty batch with a nonzero cursor; keep advancing the cursor to 0. The command-line `--scan` option handles this automatically.

## Metadata exporter email

A successful alert message was observed with:

```text
Subject: [OUTGUARD] Recipient limit exceeded

Outbound recipient limit exceeded.
Authenticated user: <SASL user>
Queue ID: <Postfix queue ID>
SMTP sender: <MAIL FROM>
SMTP recipients: <RCPT TO list>
Rspamd symbols:
  OUTGUARD_ALERT(0.00) [5/4]
  OUTGUARD_OBSERVE(0.00) [5/4, new=5]
```

The recipient list is **intentionally present only in the alert email** so an abuse operator can recognize patterns (many unrelated domains, suspicious TLD distributions, etc.). The main Redis relationship store contains hashes, not addresses. Treat alert emails as sensitive operational records: limit recipients, retention and mailbox access. The mail transport may pass through normal Rspamd/Postfix signing and delivery checks.

The direct mailer is non-durable: a failed SMTP transaction may lose a notification. This is appropriate for the initial advisory PoC, not a guaranteed-delivery alert bus. If you need durable alerts, integrate with your existing logging/alert infrastructure instead of silently adding a resident polling daemon.

## Prometheus without a monitor daemon

Rspamd RCPTWatch increments aggregate counters in Redis as part of its atomic script. For environments with an existing exporter, integrate these four fields into it instead of running extra infrastructure. If Prometheus node_exporter's **textfile collector** is enabled, use the optional one-shot script on a timer or cron:

```sh
python3 -m venv /opt/rspamd-rcptwatch-venv
/opt/rspamd-rcptwatch-venv/bin/pip install -r requirements-metrics.txt
OUTGUARD_REDIS_URL='redis://127.0.0.1:6379/0' \
  /opt/rspamd-rcptwatch-venv/bin/python prometheus/export_textfile.py \
  --output /var/lib/node_exporter/textfile_collector/outguard.prom
```

Use secure credential delivery (environment file permissions, not command-line passwords). Schedule every 1-5 minutes with existing cron/systemd timer; **no long-running monitoring or mail sender** is needed. The script atomically replaces the `.prom` file. Ensure the node_exporter user can read the destination.

Exported metrics (no usernames, recipient addresses, hashes or high-cardinality labels):

| Metric | Type | Description |
| --- | --- | --- |
| `outguard_messages_total` | Counter | Processed messages with >=1 recipient |
| `outguard_recipients_total` | Counter | Deduplicated SMTP recipients processed |
| `outguard_new_relationships_total` | Counter | Newly observed active recipient relationships |
| `outguard_alerts_total` | Counter | New alerts after cooldown |
| `outguard_redis_up` | Gauge | Redis reachable during most recent scrape |

**Important:** Resetting Redis or letting the metrics key expire resets cumulative values; dashboards should apply normal counter-reset handling. A stale textfile (if the timer fails) is not itself detected by `outguard_redis_up`; monitor textfile mtime separately if needed. See `docs/OPERATIONS.md`.

## Security and privacy

- Only authenticated outbound submission scans are counted (`task:get_user()`). Do not infer legitimacy from `MAIL FROM` alone.
- Redis stores hashes of `(user, recipient)`, hashed user keys, timestamps and numeric counters. No plaintext recipient is stored in the relationship table.
- **SHA-256 here is deterministic pseudonymization, not anonymization.** Someone with a small list of probable user/recipient addresses could attempt offline guesses. Production deployments with stronger requirements should add a server-secret keyed HMAC and rotate/migrate keys deliberately. Do not claim GDPR compliance based on hashing alone.
- The alert email contains the plaintext recipient list by design, because it is useful for human abuse triage. Follow your applicable retention, access control and legal basis requirements.
- Key expiry is inactivity-based. Frequent contacts can persist indefinitely until inactive for `window` seconds. A complete account-erasure feature is not implemented; Redis keys can be purged by hashed user ID with authorized procedures.
- Redis eviction/restart loses state. For this short-term advisory detector, that is expected. Do not use as a sole enforcement control.
- Restrict Redis network access; share Redis with Rspamd only if capacity and eviction policy permit it. Avoid collecting recipient hashes in Prometheus labels or logs.
- A compromised sender may evade this technique by distributing across accounts, sending slowly, or attacking a small number of recipients. Combine with existing volume, reputation and content signals.

## Limitations and future directions

- The six-hour figure is a **last-seen inactivity window**, not an exact tally of all unique destinations reached at any time during the preceding six hours.
- `count` per relationship is the lifetime (until expiry) message count, not a strict rolling-hour counter. It is stored but not currently displayed in the admin email.
- No built-in metrics for Redis operation failures are persisted when Redis itself is unreachable. The Rspamd result `OUTGUARD_REDIS_ERROR` is emitted where possible.
- Different normalization rules, mail aliases and SMTPUTF8 addresses may need a policy decision. Current implementation uses ASCII-oriented `string.lower` and the addresses supplied by Rspamd.
- Alert threshold and cooldown are global configuration values; per-user policy overrides are not implemented.
- For large installations, Elastic/central log aggregation may be preferable: emit structured submission events and build alerts asynchronously, decoupled from the mail delivery latency. Elasticsearch is **not** implemented by this repository.
- No automatic blocking is implemented. A future enforcement feature should be fail-safe, auditable and separately configurable.

## Tests

The Redis script has integration tests. **Never run against your normal production Redis.** Use a temporary dedicated Redis container/database or test instance:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-metrics.txt
OUTGUARD_TEST_REDIS_URL='redis://127.0.0.1:6380/15' \
  .venv/bin/python -m unittest discover -s tests -v
```

The test suite does not launch Redis automatically. Without a configured Redis URL, Redis integration tests skip rather than pretending success. The Prometheus textfile formatter has a local unit test. The end-to-end SMTP path must be checked on your own Postfix/Rspamd deployment. See the operations guide for common loader and exporter failures.

## License

MIT. Contributions, issue reports and production feedback welcome. This is a separate project from AI spam classifiers such as AISSA; no dependency on AISSA or Spamprobe is required.
