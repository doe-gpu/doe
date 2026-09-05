"""Bind retained GPU recordings to their native preparation and submissions."""
from __future__ import annotations

from typing import Any


def validate_gpu_replays(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return validated recording generations, including their encoded work."""
    pending: dict[int, list[dict[str, Any]]] = {}
    active: dict[tuple[int, int], dict[str, Any]] = {}
    recordings: list[dict[str, Any]] = []
    for row in rows:
        event = row.get('event')
        if event not in ('dispatch_encoded', 'submission_succeeded',
                         'compute_program_prepared', 'compute_program_submitted'):
            continue
        process_id = row['processId']
        if event == 'dispatch_encoded':
            pending.setdefault(process_id, []).append(row)
        elif event == 'submission_succeeded':
            pending.pop(process_id, None)
        elif event == 'compute_program_prepared':
            dispatches = pending.pop(process_id, [])
            if (row['submissionIndex'] != 0 or row['dispatchCount'] != len(dispatches)
                    or not dispatches or any(item['sequence'] >= row['sequence'] for item in dispatches)):
                raise ValueError('GPU preparation does not match encoded work')
            recording = {'prepared': row, 'dispatches': dispatches, 'submissions': []}
            # A native address may be reused after release. Preparation sequence
            # distinguishes those recording generations within the journal.
            active[(process_id, row['programId'])] = recording
            recordings.append(recording)
        else:
            recording = active.get((process_id, row['programId']))
            if recording is None:
                raise ValueError('GPU replay identity has no preparation')
            prepared = recording['prepared']
            prior = recording['submissions'][-1] if recording['submissions'] else prepared
            if (row['dispatchCount'] != prepared['dispatchCount']
                    or row['submissionIndex'] != len(recording['submissions']) + 1
                    or row['sequence'] <= prior['sequence']):
                raise ValueError('GPU replay identity or work mismatch')
            recording['submissions'].append(row)
    return recordings
