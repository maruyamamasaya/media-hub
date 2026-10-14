#!/usr/bin/env python3
"""Explicit private-thumbnail backfill while the desktop library is closed."""
import argparse
import fcntl
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'local-api'))
from vault.folder_upload import FolderUploads


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, default=ROOT / '.local/desktop-library')
    parser.add_argument('--publish', action='store_true', help='Upload thumbnails and conditionally update catalogs')
    parser.add_argument('--purge-legacy-cache', action='store_true', help='Remove identifiable regenerable viewer copies')
    args = parser.parse_args()
    with (args.library / '.desktop.lock').open('a+b') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error('Macアプリを終了してから実行してください。')
        service = FolderUploads(args.library)
        plans = [p for p in service.list() if p['state'] == 'complete']
        results = []
        if args.publish:
            for plan in plans:
                results.append(service.publish_thumbnails(plan['id']))
        removed = service.purge_legacy_view_cache() if args.purge_legacy_cache else 0
        print(json.dumps({'folders': len(plans), 'published': results, 'legacyCopiesRemoved': removed}))


if __name__ == '__main__':
    main()
