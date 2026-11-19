# Installation and operations

Examples below assume Debian-style Rspamd paths and commands run from the cloned repository root.

## 1. Install files

```sh
git clone https://github.com/frickl/rspamd-rcptwatch.git
cd rspamd-rcptwatch
sudo install -d /etc/rspamd/lua.local.d /etc/rspamd/local.d
sudo install -m 0644 rspamd/outbound_guard.lua /etc/rspamd/lua.local.d/outbound_guard.lua
sudo install -m 0644 redis/record.lua /etc/rspamd/local.d/outbound_guard_record.lua
sudo install -m 0644 examples/outbound_guard.conf /etc/rspamd/local.d/outbound_guard.conf
```

**Important:** `redis/record.lua` is a Redis EVAL script, **not** an Rspamd plugin. Never place it in `lua.local.d/` or `/etc/redis/`.

Add **once** to `/etc/rspamd/rspamd.conf.local`:

```ucl
.include(try=true) "$LOCAL_CONFDIR/local.d/outbound_guard.conf"
```

The example configuration contains the complete `outbound_guard { ... }` section; it is **not** automatically loaded from `local.d/`.

## 2. Configure

Edit `/etc/rspamd/local.d/outbound_guard.conf`:

```ucl
outbound_guard {
  enabled = true;
  window = 21600;                 # seconds since last contact (inactivity)
  max_recipients = 50;            # alert at 51 distinct active recipients
  alert_cooldown = 21600;         # per-account alert suppression
  attach_trigger_message = false; # optional original .eml in alert
  max_attachment_bytes = 2097152; # size cap (fallback: plain alert)
  key_prefix = "outguard:v1:";
  script_path = "/etc/rspamd/local.d/outbound_guard_record.lua";
}
```

RCPTWatch normally reuses existing Rspamd Redis settings. All MSA scanners in a cluster must use the **same Redis database and key prefix** to share counters and alarm cooldowns. Ensure submitted mail has a nonempty authenticated `user` in Rspamd task logs.

Merge `examples/groups.conf` into `/etc/rspamd/local.d/groups.conf` without overwriting existing groups. The three `OUTGUARD_*` result symbols have score zero.

## 3. Enable alert mail

Merge `custom_select` entries and `rules` from `examples/metadata_exporter-additions.conf` into the **existing** `/etc/rspamd/local.d/metadata_exporter.conf`. Do not replace other rules. Set `smtp`, `mail_to`, and `mail_from` **in both `outguard_smtp` and `outguard_smtp_eml`**.

The two selectors are intentional: Rspamd's `email_parts` configuration is static. Depending on `attach_trigger_message` and the attachment size limit, **one** rule sends a plain alert or an alert with the triggering message as `.eml`. The feature needs a compatible Rspamd version (the supplied example specifies >= 4.2.2).

The template's `$rcpt` shows **only SMTP recipients of the triggering message**, not the cumulative Redis recipient set. Remove `SMTP recipients: $rcpt` from **both** templates to omit that cleartext list. If enabled, the original `.eml` may still reveal addresses in its headers.

Choose an SMTP path that accepts abuse notifications even when the attached original message is classified as spam; avoid a public blanket bypass where possible. An unreachable SMTP relay can delay processing and a cooldown-set alert is not automatically retried.

## 4. Check installation and logging

```sh
rspamadm configtest
rspamadm configdump outbound_guard
rspamadm configdump metadata_exporter
sudo systemctl restart rspamd
journalctl -u rspamd -f | grep --line-buffered -E 'OUTGUARD_|EXPORT_METADATA_outguard|outbound_guard'
```

If Rspamd uses file logging instead of journald, use the configured log file, often `/var/log/rspamd/rspamd.log`:

```sh
grep -E 'OUTGUARD_|EXPORT_METADATA_outguard|outbound_guard' /var/log/rspamd/rspamd.log
```

Example symbols:

```text
OUTGUARD_OBSERVE(0.00){35/50;new=1}
OUTGUARD_OBSERVE(0.00){35/50;new=0}
OUTGUARD_ALERT(0.00){51/50}
OUTGUARD_REDIS_ERROR(0.00)
```

`OUTGUARD_OBSERVE` reports **active distinct recipients / limit** and **new distinct recipients from this scan**. It does not mean the message was ultimately delivered. `OUTGUARD_ALERT` appears only when the limit is exceeded and no cooldown is active. `OUTGUARD_REDIS_ERROR` requires investigation; counting fails open. `EXPORT_METADATA_outguard_smtp` / `..._eml` indicates exporter execution, **not proof of notification delivery**: verify Postfix logs and the mailbox. Slow `EXPORT_METADATA` events may indicate SMTP relay latency.

If the symbols are missing, verify that the scan is authenticated (`user` in the task), the top-level config was included, and the script path is readable. The callback uses `ignore_passthrough` to keep counting after ordinary whitelist passthrough decisions.

## 5. Redis inspection

Use the same Redis database/credentials as Rspamd; add your `redis-cli` authentication options as needed:

```sh
redis-cli HGETALL outguard:v1:metrics
redis-cli --scan --pattern 'outguard:v1:*'
```

Per-user keys are hashed: `<prefix><sha256(username)>:z` holds recipient relationship hashes and last-seen timestamps; `:h` holds per-relationship scan counts; `:alert` is the cooldown key. Do not use `KEYS *` on a busy Redis or clear unrelated Redis data. Metrics are short-lived aggregates (`window + 3600` TTL, refreshed on traffic) and may reset.

## 6. Optional Prometheus monitoring

No persistent Python process is needed. `prometheus/export_textfile.py` reads the Redis metrics and atomically writes a `.prom` file for node_exporter. Install `redis-py` in a virtual environment if necessary:

```sh
python3 -m venv /opt/rcptwatch-venv
/opt/rcptwatch-venv/bin/pip install -r requirements-metrics.txt
sudo install -d /var/lib/node_exporter/textfile_collector
/opt/rcptwatch-venv/bin/python prometheus/export_textfile.py \
  --redis-url redis://127.0.0.1:6379/0 \
  --prefix outguard:v1: \
  --output /var/lib/node_exporter/textfile_collector/rcptwatch.prom
```

Run this command periodically via cron or a systemd timer **on the machine with Redis access**, and configure node_exporter with `--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`. Secure Redis credentials (for example, use `OUTGUARD_REDIS_URL` from a protected environment file, not a plaintext password in a public cron line). The `.prom` output must be readable by node_exporter.

Emitted metrics:

| Metric | Meaning |
| --- | --- |
| `outguard_messages_total` | processed authenticated scans |
| `outguard_recipients_total` | envelope recipient entries processed |
| `outguard_new_relationships_total` | newly observed recipient relationships |
| `outguard_alerts_total` | alarm events generated |
| `outguard_redis_up` | collector's last Redis connection succeeded (1/0) |

The `*_total` values are stored in Redis, **not durable monotonic counters**. They may reset on Redis expiry/restart; monitoring and alert rules must tolerate this. `outguard_redis_up` checks the collector connection, not the health of each individual Rspamd request. When running several Rspamd instances with shared Redis, scrape **one** metrics-exporter instance for the shared aggregate to avoid duplicating series.

## Disable / rollback

Set `enabled = false` in `/etc/rspamd/local.d/outbound_guard.conf`, validate and restart Rspamd. This stops the rule; existing Redis keys expire naturally. No SMTP-blocking behavior is installed by RCPTWatch.
