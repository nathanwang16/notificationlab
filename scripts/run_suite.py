#!/usr/bin/env python3
"""Measure the running native apps through their own local command-file interface."""
import argparse
import datetime
import json
import pathlib
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
parser.add_argument('--modes', nargs='+', choices=['smoke','baseline','burst','identical','long'], default=['smoke','baseline','burst','identical','long'])
parser.add_argument('--output', type=pathlib.Path, help='Report path; defaults to validation/local-suite.json')
parser.add_argument('--label', default='Synthetic sender configuration recorded separately')
args = parser.parse_args()
root = args.root.resolve()
capture = pathlib.Path(json.loads((root/'capture-latest.json').read_text())['run_directory'])

def read(path):
    return json.loads(path.read_text())

def rows(path):
    if not path.exists(): return []
    lines = path.read_text().splitlines()
    result = []
    for line in lines:
        try: result.append(json.loads(line))
        except json.JSONDecodeError: pass  # Another process may be appending its last line.
    return result

def wait_for(predicate, timeout, description):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(0.25)
    raise RuntimeError('Timed out: ' + description)

status = read(capture/'capture-status.json')
if not status['active'] or 'local.notificationlab.generator' not in status['sources']:
    parser.error('Start Capture with the test sender in its source allowlist first.')
if not status['accessibility_trusted'] or not status['database'].startswith('connected read-only'):
    parser.error('Both probes must be connected to measure this suite.')
sender = root/'generator/generator-status.json'
if not read(sender)['authorized'] or read(sender)['running']:
    parser.error('Sender must have notification permission and be idle.')

started = datetime.datetime.now(datetime.timezone.utc).isoformat()
reports = []
for mode in args.modes:
    before = read(sender)['run']
    subprocess.run([sys.executable, str(root/'scripts/command.py'), 'generator', mode, '--root', str(root)], check=True, stdout=subprocess.DEVNULL)
    current = wait_for(lambda: (state if (state := read(sender))['run'] != before else None), 15, 'sender to start ' + mode)
    run = current['run']
    print(f'Started {mode}: {run}', flush=True)
    wait_for(lambda: not read(sender)['running'], 60, 'sender to finish ' + mode)
    wait_for(lambda: sum(r.get('type') == 'snapshot' and r.get('run') == run for r in rows(root/'generator/generator.jsonl')) >= 3, 30, 'retained delivery snapshots')
    # Leave time for delayed usernoted persistence without restarting either probe.
    time.sleep(3)
    process = subprocess.run([sys.executable, str(root/'scripts/analyze.py'), '--root', str(root), '--capture', str(capture), '--run', run], check=True, capture_output=True, text=True)
    report = json.loads(process.stdout)['runs'][0]
    reports.append(report)
    print(f"{mode}: retained {report['retained_delivery_ids_observed']}/{report['requested']}; DB {report['database_unique_ids']}; AX {report['accessibility_matched_request_ids']}; exact delivered text DB {report['database_exact_delivered_payload_count']}, AX {report['accessibility_exact_delivered_payload_count']}", flush=True)

summary = {'started_at': started, 'finished_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'capture_directory': str(capture), 'sender_configuration': args.label, 'runs': reports, 'capture_status': read(capture/'capture-status.json'), 'note': 'Runner completion does not imply every capture metric passed; inspect counts, fidelity and latency.'}
output = args.output or root/'validation/local-suite.json'
output.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + '\n')
print('Saved ' + str(output), flush=True)
