#!/usr/bin/env python3
"""One-shot Redis -> Prometheus textfile collector. No resident monitor or SMTP sender."""
import argparse
import os
from pathlib import Path
import tempfile
import redis

FIELDS = {
    'messages': ('outguard_messages_total', 'Messages evaluated by the guard'),
    'recipients': ('outguard_recipients_total', 'Envelope recipients evaluated by the guard'),
    'new_relationships': ('outguard_new_relationships_total', 'New recipient relationships'),
    'alerts': ('outguard_alerts_total', 'New threshold alerts'),
}

def render(data, up):
    result = []
    for field, (name, description) in FIELDS.items():
        result += [f'# HELP {name} {description}', f'# TYPE {name} counter']
        result.append(f'{name} {int(data.get(field, 0)) if up else 0}')
    result += ['# HELP outguard_redis_up Last Redis collector connection status',
               '# TYPE outguard_redis_up gauge', f'outguard_redis_up {int(up)}', '']
    return '\n'.join(result)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--redis-url', default=os.environ.get('OUTGUARD_REDIS_URL', 'redis://127.0.0.1:6379/0'))
    p.add_argument('--prefix', default='outguard:v1:')
    p.add_argument('--output', required=True, help='node_exporter textfile collector *.prom path')
    args = p.parse_args()
    try:
        client = redis.Redis.from_url(args.redis_url, decode_responses=True,
                                      socket_connect_timeout=1, socket_timeout=1)
        data = client.hgetall(args.prefix + 'metrics')
        output, up = render(data, True), True
    except redis.RedisError:
        output, up = render({}, False), False
    dest = Path(args.output)
    dest.parent.mkdir(parents=True, exist_ok=True)
    # Atomic replacement avoids partial Prometheus scrapes.
    fd, name = tempfile.mkstemp(prefix='.outguard-', dir=dest.parent, text=True)
    try:
        with os.fdopen(fd, 'w') as f: f.write(output)
        os.chmod(name, 0o644)
        os.replace(name, dest)
    finally:
        if os.path.exists(name): os.unlink(name)
    return 0 if up else 1

if __name__ == '__main__':
    raise SystemExit(main())
