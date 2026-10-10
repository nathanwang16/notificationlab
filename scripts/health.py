#!/usr/bin/env python3
"""Return 0 for healthy capture, 1 for stopped/degraded/stale, 2 for missing status."""
import argparse
import datetime
import json
import pathlib
import sys

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--max-age', type=float, default=15)
    args = parser.parse_args()
    try:
        status = json.loads((args.root/'capture-health.json').read_text())
        date = datetime.datetime.fromisoformat(status['updated_at'].replace('Z', '+00:00'))
        age = (datetime.datetime.now(datetime.timezone.utc)-date).total_seconds()
        status['heartbeat_age_seconds'] = round(age, 3)
        # Future timestamps also indicate a clock/status problem.
        status['heartbeat_fresh'] = -2 <= age <= args.max_age
        print(json.dumps(status, indent=2, ensure_ascii=False))
        return 0 if status.get('healthy') and status['heartbeat_fresh'] else 1
    except (OSError, ValueError, KeyError) as error:
        print(f'Health status unavailable: {error}', file=sys.stderr)
        return 2

if __name__ == '__main__':
    sys.exit(main())
