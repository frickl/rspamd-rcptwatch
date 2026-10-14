-- Outbound Guard: local Rspamd Lua rule; Rspamd 3.x/4.x deployment should be tested.
local lua_redis = require 'lua_redis'
local logger = require 'rspamd_logger'
local cryptobox = require 'rspamd_cryptobox_hash'
local N = 'outbound_guard'
local cfg = rspamd_config:get_all_opt(N) or {}
if cfg.enabled == false then return end

local window = tonumber(cfg.window) or 21600
local limit = tonumber(cfg.max_recipients) or 50
local cooldown = tonumber(cfg.alert_cooldown) or 21600
local prefix = cfg.key_prefix or 'outguard:v1:'
if window < 1 or limit < 1 or cooldown < 1 then
  logger.errx(rspamd_config, '%s: invalid window, max_recipients or alert_cooldown', N)
  return
end
local redis_params = lua_redis.parse_redis_server(N, cfg)
if not redis_params then
  logger.errx(rspamd_config, '%s: no Redis configuration; disabled', N)
  return
end
local script_path = cfg.script_path or '/etc/rspamd/local.d/outbound_guard_record.lua'
local file, open_err = io.open(script_path, 'rb')
if not file then
  logger.errx(rspamd_config, '%s: cannot read Redis script %s: %s', N, script_path, tostring(open_err))
  return
end
local script_body = file:read('*a')
file:close()
if not script_body or script_body == '' then
  logger.errx(rspamd_config, '%s: Redis script is empty', N)
  return
end

local function digest(text)
  return cryptobox.create_specific('sha256', text):hex()
end

local function check(task)
  local user = task:get_user()
  if not user or user == '' then return end
  local recipients = task:get_recipients('smtp') or {}
  local seen, hashes = {}, {}
  local normalized_user = string.lower(user)
  for _, rcpt in ipairs(recipients) do
    local address = rcpt.addr and string.lower(rcpt.addr)
    if address and address ~= '' then
      local hash = digest(normalized_user .. '\0' .. address)
      if not seen[hash] then
        seen[hash] = true
        hashes[#hashes + 1] = hash
      end
    end
  end
  if #hashes == 0 then return end

  -- Hash the user in Redis key names. Plain user only exists in task/mail alert.
  local base = prefix .. digest(normalized_user)
  local args = {
    script_body, '4', base .. ':z', base .. ':h', base .. ':alert', prefix .. 'metrics',
    tostring(window), tostring(limit), tostring(cooldown)
  }
  for _, hash in ipairs(hashes) do args[#args + 1] = hash end

  local function on_redis_result(err, data)
    if err or type(data) ~= 'table' then
      logger.errx(task, '%s: Redis request failed: %s', N, tostring(err or data))
      task:insert_result('OUTGUARD_REDIS_ERROR', 1)
      return
    end
    local active = tonumber(data[1]) or 0
    local new = tonumber(data[2]) or 0
    local alarm = tonumber(data[3]) or 0
    task:insert_result('OUTGUARD_OBSERVE', 1,
        tostring(active) .. '/' .. tostring(limit), 'new=' .. tostring(new))
    if alarm == 1 then
      task:insert_result('OUTGUARD_ALERT', 1, tostring(active) .. '/' .. tostring(limit))
    end
  end
  local ok = lua_redis.redis_make_request(task, redis_params, base .. ':z', true,
    on_redis_result, 'EVAL', args)
  if not ok then
    logger.errx(task, '%s: cannot schedule Redis request', N)
    task:insert_result('OUTGUARD_REDIS_ERROR', 1)
  end
end

-- Critical: ignore_passthrough lets accounting run even after a whitelist no-action.
local parent_id = rspamd_config:register_symbol({
  name = 'OUTGUARD_CHECK',
  type = 'callback',
  callback = check,
  flags = 'ignore_passthrough,explicit_disable,nostat'
})
for _, symbol in ipairs({ 'OUTGUARD_OBSERVE', 'OUTGUARD_ALERT', 'OUTGUARD_REDIS_ERROR' }) do
  rspamd_config:register_symbol({
    name = symbol, type = 'virtual', parent = parent_id, score = 0.0
  })
end
