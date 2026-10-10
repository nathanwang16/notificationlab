#!/usr/bin/env python3
"""Compare sender expectations, retained deliveries, and the two independent probes."""
import argparse, json, pathlib, datetime, statistics

def rows(path):
    archives = sorted(path.parent.glob(path.name + '.[0-9]*'), key=lambda p: int(p.suffix[1:]), reverse=True)
    return [json.loads(line) for part in archives + [path] if part.exists() for line in part.read_text().splitlines() if line.strip()]

def time(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--capture', type=pathlib.Path)
    parser.add_argument('--run', help='One sender run ID, e.g. 514E1DFC')
    args = parser.parse_args()
    root = args.root
    capture = args.capture or pathlib.Path(json.loads((root/'capture-latest.json').read_text())['run_directory'])
    expected = rows(root/'generator/expected.jsonl')
    if args.run:
        expected = [r for r in expected if r['run'] == args.run]
        if not expected:
            parser.error('No expectations for run ' + args.run)
    results = {r['request_identifier']: r for r in rows(root/'generator/generator.jsonl') if r.get('type') == 'request_result'}
    deliveries = {r['request_identifier']: r for r in rows(root/'generator/delivered.jsonl')}
    db, ax = rows(capture/'database.jsonl'), rows(capture/'accessibility.jsonl')
    runs = {}
    for request in expected:
        runs.setdefault(request['run'], []).append(request)
    reports = []
    for run, requests in runs.items():
        wanted = {r['request_identifier'] for r in requests}
        retained = wanted & deliveries.keys()
        accepted = {key for key in wanted if results.get(key, {}).get('accepted')}
        db_matches = {}
        for row in db:
            key = row.get('request_identifier') or row.get('test_token')
            if key in wanted:
                db_matches.setdefault(key, row)
        ax_matches = {}
        id_to_request = {r['notification_id']: r.get('request_identifier') or r.get('test_token') for r in db if r.get('notification_id')}
        for row in ax:
            key = id_to_request.get(row.get('notification_id')) or row.get('test_token')
            if key in wanted:
                ax_matches.setdefault(key, row)
        # A UUID joined to the database request ID can distinguish identical visible text.
        ambiguous = requests[0]['mode'] == 'identical' and (len(ax_matches) != len(wanted) or any(not row.get('notification_id') for row in ax_matches.values()))
        expected_by_id = {r['request_identifier']: r for r in requests}
        expected_tokens = {r['visible_token'] for r in requests if r['request_identifier'] in retained}
        fidelity = {key: {field: matched.get(field) == expected_by_id[key][field] for field in ['title','subtitle','body']} for key, matched in db_matches.items()}
        ax_fidelity = {key: {field: matched[field] == expected_by_id[key][field] if field in matched else None for field in ['title','subtitle','body']} for key, matched in ax_matches.items()}
        observed_tokens = {row.get('test_token') for row in ax if row.get('test_token') in {r['visible_token'] for r in requests}}
        report = {'run':run,'mode':requests[0]['mode'],'requested':len(wanted),'accepted':len(accepted),'retained_delivery_ids_observed':len(retained),'database_unique_ids':len(db_matches),'accessibility_unique_visible_tokens':len(observed_tokens),'accessibility_identity_ambiguous':ambiguous,'database_missing_retained_ids':sorted(retained-db_matches.keys()),'accessibility_missing_visible_tokens':sorted(expected_tokens-observed_tokens),'database_field_fidelity':fidelity,'database_exact_payload_count':sum(all(fields.values()) for fields in fidelity.values())}
        report.update({'accessibility_matched_request_ids': len(ax_matches), 'accessibility_missing_retained_ids': sorted(retained-ax_matches.keys()) if not ambiguous else None, 'accessibility_field_fidelity': ax_fidelity, 'accessibility_exact_payload_count': sum(all(value is True for value in fields.values()) for fields in ax_fidelity.values()), 'accessibility_visible_tokens_observed': len({row.get('test_token') for row in ax if row.get('test_token') in {r['visible_token'] for r in requests}})})
        report['delivered_payload_differs_from_request_ids'] = sorted(key for key in retained if any(deliveries[key][field] != expected_by_id[key][field] for field in ['title','subtitle','body']))
        report['delivered_body_lengths'] = {key: {'requested_characters': len(expected_by_id[key]['body']), 'delivered_characters': len(deliveries[key]['body'])} for key in report['delivered_payload_differs_from_request_ids']}
        for name, matched in [('database',db_matches),('accessibility',ax_matches)]:
            delivered_fidelity = {key: {field: matched[key][field] == deliveries[key][field] if field in matched[key] else None for field in ['title','subtitle','body']} for key in retained & matched.keys()}
            report[name+'_delivered_field_fidelity'] = delivered_fidelity
            report[name+'_exact_delivered_payload_count'] = sum(all(value is True for value in fields.values()) for fields in delivered_fidelity.values())
        for name, matched in [('database',db_matches),('accessibility',ax_matches)]:
            delays=[]
            for key in retained & matched.keys():
                delay=time(matched[key]['observed_at'])-time(deliveries[key]['delivered_at'])
                delays.append(delay)
            if delays:
                ordered=sorted(delays)
                report[name+'_latency_seconds']={'count':len(delays),'median':round(statistics.median(delays),3),'p95':round(ordered[max(0,int(len(ordered)*0.95+0.999)-1)],3),'max':round(max(delays),3),'note':'Collector observation minus sender-reported delivery date; includes display queueing for AX.'}
        reports.append(report)
    summary={'capture_directory':str(capture),'capture_status':json.loads((capture/'capture-status.json').read_text()) if (capture/'capture-status.json').exists() else None,'runs':reports,'limitations':['Retained-delivery snapshots are not a complete delivery history.','Only sender runs posted during this capture session can measure capture coverage; use --run to select a fresh test.','Text fidelity is measured for synthetic notifications; real Discord payload coverage needs an incoming-message test.','Distinct AX UUIDs are joined to database request IDs when available; visible text alone is ambiguous for identical notifications.','Latency uses wall clocks, and is not a guarantee of network-to-message latency.','No delivery/capture claim is made for notifications absent from retained snapshots.']}
    output=capture/'analysis.json'
    output.write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(summary,indent=2,ensure_ascii=False))

if __name__=='__main__':
    main()
