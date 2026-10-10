#!/usr/bin/env python3
"""Prepare/install/remove this collector's per-user GUI LaunchAgent."""
import argparse
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import datetime
import fcntl

LABEL = 'local.notificationlab.capture'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'install', 'uninstall', 'status'])
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    executable = root/'apps/NotificationLabCapture.app/Contents/MacOS/NotificationLabCapture'
    target = pathlib.Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    domain = f'gui/{os.getuid()}'
    service = domain+'/'+LABEL
    if args.action == 'status':
        return subprocess.run(['launchctl', 'print', service]).returncode
    if args.action == 'uninstall':
        # Only unload our exact service and remove our exact matching plist.
        if target.exists():
            value = plistlib.loads(target.read_bytes())
            if value.get('Label') != LABEL or value.get('EnvironmentVariables', {}).get('NOTIFICATION_LAB_ROOT') != str(root):
                raise RuntimeError('Installed agent belongs to a different data directory; refusing to remove it.')
            result = subprocess.run(['launchctl', 'print', service], capture_output=True)
            if result.returncode == 0:
                subprocess.run(['launchctl', 'bootout', service], check=True)
            target.unlink()
        print('Removed '+str(target))
        return 0
    if not executable.is_file():
        raise RuntimeError('Build and authorize the final app at this location first.')
    value = {
        'Label': LABEL,
        'ProgramArguments': [str(executable), '--background'],
        'EnvironmentVariables': {'NOTIFICATION_LAB_ROOT': str(root)},
        'WorkingDirectory': str(root),
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit': False},
        'ThrottleInterval': 10,
        'LimitLoadToSessionType': 'Aqua',
        'StandardOutPath': '/dev/null',
        'StandardErrorPath': '/dev/null',
    }
    data = plistlib.dumps(value)
    folder = root/'deployment'; folder.mkdir(exist_ok=True)
    prepared = folder/f'{LABEL}.plist'; prepared.write_bytes(data)
    if args.action == 'prepare':
        print(prepared)
        return 0
    health = json.loads((root/'capture-health.json').read_text())
    if not health.get('healthy'):
        raise RuntimeError('Authorize and verify healthy capture before installing the login agent.')
    age = (datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(health['updated_at'].replace('Z', '+00:00'))).total_seconds()
    if not -2 <= age <= 120:
        raise RuntimeError('Verify healthy capture again, quit the manual app, and install within two minutes.')
    with (root/'state/capture.lock').open('r+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Quit the manual Capture app before installing the login agent.')
        fcntl.flock(lock, fcntl.LOCK_UN)
    result = subprocess.run(['launchctl', 'print', service], capture_output=True)
    if result.returncode == 0:
        raise RuntimeError('An agent with this label is already loaded. Inspect it with status before making changes.')
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.read_bytes() != data:
        raise RuntimeError('A different agent plist already exists at the destination; refusing to overwrite it.')
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as handle:
        handle.write(data); temporary = pathlib.Path(handle.name)
    os.chmod(temporary, 0o600); os.replace(temporary, target)
    # The user must quit the manual app first; a lock prevents a second collector.
    subprocess.run(['launchctl', 'bootstrap', domain, str(target)], check=True)
    print('Installed '+str(target))
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
