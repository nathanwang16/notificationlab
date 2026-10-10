#!/usr/bin/env python3
"""Read captured notifications as JSON lines; sequence is a resumable cursor."""
import argparse
import json
import pathlib
import sqlite3
import sys
import time

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--after', type=int, default=0, help='Read events with sequence greater than this value')
    parser.add_argument('--follow', action='store_true', help='Keep reading; checks every 500 ms')
    parser.add_argument('--source', help='Optional bundle ID filter, case-insensitive')
    args = parser.parse_args()
    if args.after < 0:
        parser.error('--after must be nonnegative')
    path = (args.root/'state/capture.sqlite').resolve()
    cursor = args.after
    try:
        with sqlite3.connect(path.as_uri()+'?mode=ro', uri=True, timeout=1) as connection:
            while True:
                # One read snapshot makes retention-gap detection consistent with the rows.
                connection.execute('BEGIN')
                oldest = connection.execute('SELECT min(sequence) FROM events').fetchone()[0]
                if cursor and oldest is not None and cursor < oldest - 1:
                    connection.rollback()
                    raise RuntimeError(f'Cursor {cursor} has expired; oldest retained sequence is {oldest}. Re-run with --after {oldest-1} to accept the gap.')
                rows = connection.execute('SELECT sequence,payload FROM events WHERE sequence>? ORDER BY sequence', (cursor,)).fetchall()
                connection.commit()
                for sequence, payload in rows:
                    event = json.loads(payload)
                    if not args.source or event['source_bundle'].lower() == args.source.lower():
                        print(json.dumps(event, ensure_ascii=False, separators=(',', ':')), flush=True)
                    cursor = sequence
                if not args.follow:
                    return 0
                time.sleep(.5)
    except KeyboardInterrupt:
        return 0
    except (sqlite3.Error, RuntimeError, OSError) as error:
        print(f'Cannot read notification feed: {error}', file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())
