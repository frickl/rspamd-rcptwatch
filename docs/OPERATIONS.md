# Operations and troubleshooting

## Expected behavior

An authenticated MSA scan inserts `OUTGUARD_OBSERVE(0.00){1/50;new=1;}` for one new envelope recipient. Repeat sends yield `new=0`. A new recipient increments distinct count; CC and BCC are counted via SMTP RCPT TO, not visible To/Cc headers. On the transition to over-limit without a running cooldown: `OUTGUARD_ALERT(0.00){51/50;}`. Metadata exporter `outguard_smtp` sends an independent email. The notification keeps the triggering authenticated username, queue ID, sender and recipient list; Redis stores no recipient plaintext.

## Load / config issues

`rspamadm configtest` should say `syntax OK`. `rspamadm configdump outbound_guard` must show the section. Since Rspamd does not load arbitrary `local.d/*.conf`, include the complete `outbound_guard {}` configuration in `rspamd.conf.local` with `.include(try=true) "$LOCAL_CONFDIR/local.d/outbound_guard.conf"`.

Only `outbound_guard.lua` belongs in `lua.local.d/`. **Do not** put Redis `record.lua` there: that causes `attempt to index global 'ARGV' (a nil value)` on Rspamd start. Redis code is loaded as text by the Rspamd module and executed through `EVAL`.

`trying to add virtual symbol ... as real (no parent)` means the child symbol's `parent` was not the numeric return value from `register_symbol`. The checked-in code uses that ID.

`lua_redis.lua: use default Redis settings for outbound_guard` is expected when global Redis configuration is used. For authenticated submission, `rspamd_task_write_log` should contain a nonempty `user:`; absent `user` means no tracking.

`FROM_WHITE` multimap can set a passthrough (`no action`), which ordinarily prevents callbacks; Outbound Guard uses `ignore_passthrough`. Rspamd `settings_id: white` with a fully skipped task may be a different scan of a reinjected mail, not submission. Check the MSA scan, not transit/reinjection scans.

## Redis checks

Use the same Redis DB and credentials as Rspamd. `SCAN` must advance with the returned cursor; alternatively `redis-cli --scan --pattern 'outguard:v1:*'`. Never issue `KEYS *` on a production Redis. `HGETALL outguard:v1:metrics` shows global metrics; `TYPE`, `ZCARD`, `ZRANGE ... WITHSCORES`, `HGETALL` inspect individual user keys. Redis keys are hashed; do not expect plaintext usernames. `:alert` TTL is the per-user cooldown; **do not delete all database keys** to reset a test. For controlled tests, use a separate prefix or Redis DB.

## Metadata exporter

The `custom_select` selector tests `task:has_symbol('OUTGUARD_ALERT')`. The exporter callback `EXPORT_METADATA_outguard_smtp` is registered automatically when its rule is loaded. No multimap rule is required. Keep existing metadata exporter `custom_select` and `rules` sections: *merge*, don't replace.

Avoid globals inside the custom selector: `rspamd_logger` may be nil. For temporary logging, start selector source with `local logger = require 'rspamd_logger'`, then call `logger.warnx(task, ...)`. Remove verbose debug logs after testing. A recipient already beyond threshold yields only `OUTGUARD_OBSERVE` while cooldown is active; `OUTGUARD_ALERT` appears only on the fresh alarm.

Check SMTP delivery by matching queue IDs in Postfix logs. The alert may be successfully delivered to Dovecot yet hidden by threading/filtering; inspect its Subject, Message-ID and mailbox with doveadm. In actual tests, a separate `[OUTGUARD] Recipient limit exceeded` notification was delivered.

## Safety and rollback

The symbols are score zero: accounting/notification only, no blocking. Under Redis errors the policy is fail-open (deliver mail; emit `OUTGUARD_REDIS_ERROR` where possible). To disable: `enabled = false` and restart Rspamd. Do not use this for automatic account suspension without additional corroborating signals, capacity planning and tests.
