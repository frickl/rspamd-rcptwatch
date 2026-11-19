  # Rspamd RCPTWatch

**Track unique SMTP recipients per authenticated sender using Rspamd and Redis.** RCPTWatch detects unusual recipient diversity on submission (465/587) and optionally sends an abuse notification. It **does not reject, rate-limit or suspend** accounts.

A user forwarding 5,000 messages to one address counts as **one** active recipient; a user addressing 80 different mailboxes counts as **80**. The threshold is an investigation signal, not proof of abuse.

## How it works

- Identity: SASL username (`task:get_user()`), not the envelope MAIL FROM.
- Recipients: SMTP envelope `RCPT TO` (`task:get_recipients('smtp')`), including Bcc.
- Redis stores SHA-256 hashes of normalized *user + NUL + recipient*, never plaintext recipient addresses. Usernames in Redis key names are hashed separately.
- A relationship expires after `window` seconds **without contact**. This is not a strict rolling time window.
- `max_recipients = 50` alerts on the **51st** active distinct recipient.
- A shared Redis coordinates multiple Rspamd instances. `alert_cooldown` limits alerts to one per user per cooldown period, using an atomic Redis operation.
- Only authenticated scans are counted. Scans/reinjection can affect message counters but repeated recipients do not increase the distinct-recipient count.
- Redis errors are fail-open: mail delivery is not blocked.

## Install

See **[INSTALL.md](INSTALL.md)** for exact paths, configuration, logging and Prometheus monitoring. Uses existing Rspamd Redis settings and the built-in `metadata_exporter`; there is no separate notification daemon.

## Operational signals

| Symbol (score 0) | Meaning |
| --- | --- |
| `OUTGUARD_OBSERVE(0.00){35/50;new=2}` | 35 active recipients, 2 new in this scan |
| `OUTGUARD_ALERT(0.00){51/50}` | Threshold exceeded, new alarm permitted by cooldown |
| `OUTGUARD_REDIS_ERROR` | Redis request failed; counting unavailable |

Alerts use the Rspamd `metadata_exporter` SMTP backend. The alert body may contain **plaintext recipients of the triggering message** via `$rcpt`; the optional `.eml` attachment contains the original message. Neither is recovered from Redis. Remove `$rcpt` from the template if unwanted.

## Monitoring

Redis aggregate metrics at `outguard:v1:metrics`: `messages`, `recipients`, `new_relationships`, `alerts`. Optional exporter: `prometheus/export_textfile.py`, to node_exporter's textfile collector. Values reset on Redis loss/expiry: **not durable accounting counters**. See INSTALL.md.

## Limitations

Recipient diversity is an additional abuse signal, not a substitute for account compromise detection or volume rate limits. A single-recipient flood is not detected. Redis alert cooldown prevents duplicate generation but **does not guarantee SMTP delivery**. Configuration and runtime compatibility should be verified on your Rspamd version.

MIT License.
