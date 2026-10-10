#!/usr/bin/env python3
"""Send a command to these apps through their own local command-file interface."""
import argparse
import json
import os
import pathlib
import tempfile
import uuid
import time
import fcntl
import sys

parser = argparse.ArgumentParser()
parser.add_argument('app', choices=['capture', 'generator'])
parser.add_argument('action')
parser.add_argument('--sources', help='Comma-separated bundle IDs; capture start only')
parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
parser.add_argument('--wait', type=float, help='Capture acknowledgement timeout; default 10 seconds for Capture, 0 for Sender')
args = parser.parse_args()
allowed = {
    'capture': {'start', 'stop', 'inventory', 'diagnose', 'request_accessibility', 'enable_ax', 'disable_ax'},
    'generator': {'smoke', 'baseline', 'burst', 'identical', 'long', 'stop', 'snapshot', 'request_permission'},
}
if args.action not in allowed[args.app]:
    parser.error('Unknown action for ' + args.app)
if args.sources is not None and (args.app, args.action) != ('capture', 'start'):
    parser.error('--sources requires capture start')
command = {'id': str(uuid.uuid4()), 'action': args.action, 'created_at_unix': time.time()}
if args.sources is not None:
    command['sources'] = args.sources
timeout = args.wait if args.wait is not None else (10 if args.app == 'capture' else 0)
with (args.root/('.' + args.app + '-command.lock')).open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with tempfile.NamedTemporaryFile('w', dir=args.root, prefix='.command-', delete=False) as handle:
        json.dump(command, handle)
        handle.write('\n')
        temporary = handle.name
    os.replace(temporary, args.root / (args.app + '-command.json'))
    if timeout > 0 and args.app == 'capture':
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                ack = json.loads((args.root/'capture-command-ack.json').read_text())
                if ack.get('id') == command['id']:
                    print(json.dumps(ack))
                    sys.exit(0 if ack.get('accepted') else 1)
            except (OSError, ValueError):
                pass
            time.sleep(.1)
        print('Capture did not acknowledge this command before the timeout; inspect its health before retrying.', file=sys.stderr)
        sys.exit(1)
    print(json.dumps(command))
