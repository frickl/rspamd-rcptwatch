-- Executed by Redis EVAL, never placed in Rspamd lua.local.d/.
-- KEYS: [1] per-user last_seen ZSET [2] per-user counter HASH
--       [3] per-user alarm cooldown [4] aggregate metrics HASH
-- ARGV: [1] inactivity window [2] distinct recipient limit
--       [3] alert cooldown [4...] SHA256 hashes of user+NUL+envelope recipient
local window = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local cooldown = tonumber(ARGV[3])
if not window or not limit or not cooldown or window <= 0 or limit <= 0 or cooldown <= 0 then
  return redis.error_reply('invalid outbound guard parameters')
end
local now = tonumber(redis.call('TIME')[1])
local expired = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', now - window)
for i = 1, #expired, 500 do
  local chunk = {}
  for j = i, math.min(i + 499, #expired) do chunk[#chunk + 1] = expired[j] end
  redis.call('ZREM', KEYS[1], unpack(chunk))
  redis.call('HDEL', KEYS[2], unpack(chunk))
end
local new = 0
local highest = 0
for i = 4, #ARGV do
  local hash = ARGV[i]
  if not redis.call('ZSCORE', KEYS[1], hash) then new = new + 1 end
  redis.call('ZADD', KEYS[1], now, hash)
  local count = redis.call('HINCRBY', KEYS[2], hash, 1)
  if count > highest then highest = count end
end
redis.call('EXPIRE', KEYS[1], window + 60)
redis.call('EXPIRE', KEYS[2], window + 60)
local active = redis.call('ZCARD', KEYS[1])
redis.call('HINCRBY', KEYS[4], 'messages', 1)
redis.call('HINCRBY', KEYS[4], 'recipients', #ARGV - 3)
redis.call('HINCRBY', KEYS[4], 'new_relationships', new)
local alarm = 0
if active > limit and redis.call('SET', KEYS[3], '1', 'EX', cooldown, 'NX') then
  alarm = 1
  redis.call('HINCRBY', KEYS[4], 'alerts', 1)
end
redis.call('EXPIRE', KEYS[4], window + 3600)
return {active, new, alarm, highest}
