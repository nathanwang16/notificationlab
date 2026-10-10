#!/usr/bin/env python3
"""Exercise the compiled AppKit collector using only a disposable source database."""
import argparse
import datetime
import json
import os
import pathlib
import plistlib
import sqlite3
import subprocess
import tempfile
import time
import uuid

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    args = parser.parse_args()
    lab = pathlib.Path(__file__).resolve().parents[1]
    folder = pathlib.Path(os.environ.get('NOTIFICATION_LAB_WORK', str(lab/'work')))/'test-runs'; folder.mkdir(parents=True, exist_ok=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix='lifecycle-', dir=folder))
    source = root/'source.sqlite'
    writer = sqlite3.connect(source)
    writer.executescript("PRAGMA journal_mode=WAL; CREATE TABLE app(app_id INTEGER PRIMARY KEY, identifier TEXT); CREATE TABLE record(rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, delivered_date REAL); INSERT INTO app VALUES(1,'com.hnc.Discord'); INSERT INTO app VALUES(2,'unrelated.source');")
    checks = []
    processes = []
    def check(condition, description):
        assert condition, description
        checks.append(description)
        print('PASS: '+description, flush=True)
    def insert(n, source_id=1):
        payload = plistlib.dumps({'req': {'titl': 'Fixture sender', 'subt': 'Fixture channel', 'body': f'Lifecycle {n} — 中文 🧪', 'iden': str(n)}}, fmt=plistlib.FMT_BINARY)
        writer.execute('INSERT INTO record VALUES(?,?,?,?,?)', (n, source_id, uuid.uuid4().bytes, payload, time.time()-978307200)); writer.commit()
    def wait(predicate, timeout=12):
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            try:
                value = predicate()
                if value:
                    return value
            except (OSError, ValueError, sqlite3.Error):
                pass
            time.sleep(.1)
        raise RuntimeError('Lifecycle wait expired')
    def health():
        return json.loads((root/'capture-health.json').read_text())
    def feed():
        with sqlite3.connect((root/'state/capture.sqlite').as_uri()+'?mode=ro', uri=True) as db:
            return [json.loads(row[0]) for row in db.execute('SELECT payload FROM events ORDER BY sequence')]
    def launch():
        environment = dict(os.environ, NOTIFICATION_LAB_ROOT=str(root))
        process = subprocess.Popen([str(args.app.resolve()/'Contents/MacOS/NotificationLabCapture'), '--background', '--no-ax', '--sources', 'com.hnc.Discord', '--db', str(source)], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        processes.append(process)
        try: wait(lambda: health().get('pid') == process.pid)
        except RuntimeError:
            if process.poll() is None: process.terminate(); process.wait(timeout=5)
            raise RuntimeError('Collector did not start: '+process.stderr.read().decode(errors='replace'))
        return process
    def command(action):
        return subprocess.run(['python3', str(lab/'scripts/command.py'), 'capture', action, '--root', str(root)], check=True, capture_output=True, text=True)
    try:
        insert(1)
        first = launch()
        check(health()['healthy'] and not feed(), 'native app seeds first-use history and reports healthy database-only capture')
        insert(2); wait(lambda: len(feed()) == 1)
        check(feed()[0]['body'] == 'Lifecycle 2 — 中文 🧪' and feed()[0]['source_bundle'] == 'com.hnc.discord', 'native app persists exact message fields with normalized Discord source')
        insert(3, source_id=2); time.sleep(1)
        check(len(feed()) == 1, 'native app excludes unrelated notification payloads')
        check(json.loads(command('stop').stdout)['accepted'], 'command API acknowledges persisted stop')
        wait(lambda: not health()['active'])
        first.terminate(); first.wait(timeout=5)
        insert(4)
        second = launch()
        check(not health()['active'] and len(feed()) == 1, 'stop state survives a native process restart')
        check(json.loads(command('start').stdout)['accepted'], 'command API acknowledges resume')
        wait(lambda: len(feed()) == 2)
        check(feed()[1]['request_identifier'] == '4', 'resume retrieves retained message delivered while stopped')
        last_command = json.loads((root/'state/configuration.json').read_text())['lastCommandID']
        second.terminate(); second.wait(timeout=5)
        insert(5)
        third = launch()
        wait(lambda: len(feed()) == 3)
        check(feed()[-1]['request_identifier'] == '5' and health()['healthy'], 'active native process restart catches up without replaying older messages')
        check(json.loads((root/'state/configuration.json').read_text())['lastCommandID'] == last_command, 'previous command remains consumed across restart')
        run = pathlib.Path(health()['run_directory'])
        diagnostics = [json.loads(line) for line in (run/'diagnostics.jsonl').read_text().splitlines()]
        check(not any(row.get('type') == 'started' for row in diagnostics), 'relaunch does not execute the stale start command again')
        duplicate = subprocess.run([str(args.app.resolve()/'Contents/MacOS/NotificationLabCapture'), '--background'], env=dict(os.environ, NOTIFICATION_LAB_ROOT=str(root)), capture_output=True, timeout=5)
        check(duplicate.returncode == 0 and b'already owns' in duplicate.stderr and third.poll() is None, 'second native collector exits without disturbing the owner')
        result = subprocess.run(['python3', str(lab/'scripts/read_events.py'), '--root', str(root), '--after', '1', '--source', 'COM.HNC.DISCORD'], capture_output=True, text=True, check=True)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        check([event['sequence'] for event in events] == [2, 3], 'read-only JSON feed resumes from a sequence cursor')
        result = subprocess.run(['python3', str(lab/'scripts/health.py'), '--root', str(root)], capture_output=True)
        check(result.returncode == 0, 'health CLI recognizes fresh healthy capture')
        stale = root/'stale'; stale.mkdir()
        snapshot = health(); snapshot['updated_at'] = (datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=30)).isoformat()
        (stale/'capture-health.json').write_text(json.dumps(snapshot))
        result = subprocess.run(['python3', str(lab/'scripts/health.py'), '--root', str(stale)], capture_output=True)
        check(result.returncode == 1, 'health CLI rejects a stale heartbeat')
        invalid = subprocess.run(['python3', str(lab/'scripts/command.py'), 'capture', 'start', '--sources', ',', '--root', str(root)], capture_output=True)
        check(invalid.returncode == 1, 'collector rejects an empty source command')
        report = {'fixture_directory': str(root), 'app': str(args.app.resolve()), 'checks_passed': len(checks), 'checks': checks, 'synthetic_source_only': True}
        (lab/'validation/lifecycle.json').write_text(json.dumps(report, indent=2)+'\n')
        print(str(len(checks))+' lifecycle checks passed')
    finally:
        writer.close()
        for process in processes:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)

if __name__ == '__main__':
    main()
