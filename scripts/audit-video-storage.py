#!/usr/bin/env python3
"""Read-only local video survey. No upload, conversion, deletion or file output."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import subprocess

GIB = 2 ** 30
VIDEO_EXTENSIONS = {'.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi', '.mts', '.m2ts'}


def positive_number(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) and number > 0 else None


def survey(root, probe):
    totals = dict(videoCount=0, measuredCount=0, unmeasuredCount=0,
                  originalBytes=0, measuredBytes=0, durationSeconds=0,
                  hdrCount=0, highResolutionCount=0, maxFileBytes=0)
    entries = [(str(root.parent), [], [root.name])] if root.is_file() else os.walk(root, followlinks=False)
    for directory, dirs, files in entries:
        dirs[:] = sorted(d for d in dirs if not d.startswith('.') and not (Path(directory) / d).is_symlink())
        for name in sorted(files):
            path = Path(directory) / name
            if name.startswith('.') or path.suffix.lower() not in VIDEO_EXTENSIONS or path.is_symlink():
                continue
            try:
                size = path.stat().st_size
            except OSError:
                continue
            totals['videoCount'] += 1
            totals['originalBytes'] += size
            totals['maxFileBytes'] = max(totals['maxFileBytes'], size)
            try:
                result = subprocess.run([probe, '-v', 'error', '-protocol_whitelist', 'file',
                    '-show_entries', 'format=duration:stream=codec_type,width,height,color_transfer,duration',
                    '-of', 'json', str(path)], capture_output=True, text=True, timeout=60, check=True)
                data = json.loads(result.stdout)
                streams = [s for s in data.get('streams', []) if s.get('codec_type') == 'video']
                duration = positive_number(data.get('format', {}).get('duration'))
                if not duration:
                    duration = max((positive_number(s.get('duration')) or 0 for s in streams), default=0)
                if not streams or not duration:
                    raise ValueError('missing duration')
                totals['measuredCount'] += 1
                totals['measuredBytes'] += size
                totals['durationSeconds'] += duration
                totals['hdrCount'] += int(any(s.get('color_transfer') in ('smpte2084', 'arib-std-b67') for s in streams))
                totals['highResolutionCount'] += int(any(max(s.get('width', 0), s.get('height', 0)) > 1920 for s in streams))
            except (OSError, subprocess.SubprocessError, ValueError, TypeError):
                totals['unmeasuredCount'] += 1
    return totals


def estimate(totals, mbps, hours, fx, tax, storage_rate, transfer_rate):
    # Mbps includes video and audio. 10% is an explicit planning allowance,
    # not an encoder guarantee. Originals and derivatives are both retained.
    additional = totals['durationSeconds'] * mbps * 1_000_000 / 8 * 1.10
    delivery = hours * 3600 * mbps * 1_000_000 / 8 * 1.10
    storage_usd = additional / GIB * storage_rate
    delivery_usd = delivery / GIB * transfer_rate
    average_original = (totals['measuredBytes'] * 8 / totals['durationSeconds'] / 1_000_000
                        if totals['durationSeconds'] else None)
    original_delivery = hours * 3600 * average_original * 1_000_000 / 8 * 1.10 if average_original else None
    savings_usd = ((original_delivery - delivery) / GIB * transfer_rate - storage_usd
                   if original_delivery is not None else None)
    return dict(totalAudioVideoMbps=mbps, monthlyViewingHours=hours,
                additionalStorageGiB=additional / GIB, deliveryGiB=delivery / GIB,
                additionalStorageUSD=storage_usd, deliveryUSD=delivery_usd,
                additionalStorageJPY=storage_usd * fx * (1 + tax),
                deliveryJPY=delivery_usd * fx * (1 + tax),
                netMonthlySavingsJPY=savings_usd * fx * (1 + tax) if savings_usd is not None else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--fx', type=float, default=150)
    parser.add_argument('--tax', type=float, default=0.10)
    args = parser.parse_args()
    root = args.folder.expanduser().resolve()
    if not (root.is_dir() or (root.is_file() and root.suffix.lower() in VIDEO_EXTENSIONS)) or root in (Path.home(), Path(root.anchor)):
        parser.error('動画ファイルまたは動画フォルダを指定してください（ホーム全体やディスク全体は不可）。')
    if args.fx <= 0 or not math.isfinite(args.fx) or args.tax < 0 or not math.isfinite(args.tax):
        parser.error('為替は正数、税率は0以上で指定してください。')
    probe = shutil.which('ffprobe')
    if not probe:
        parser.error('ffprobeが必要です。まだインストールは行っていません。')
    totals = survey(root, probe)
    totals['averageFileBytes'] = totals['originalBytes'] / totals['videoCount'] if totals['videoCount'] else 0
    totals['averageOriginalMbps'] = (totals['measuredBytes'] * 8 / totals['durationSeconds'] / 1_000_000
                                     if totals['durationSeconds'] else None)
    report = dict(measured=totals, assumptions=dict(region='ap-northeast-1', storageClass='S3 Standard',
        priceChecked='2026-10-14', storageUSDPerGiBMonth=0.025, transferUSDPerGiB=0.114,
        freeTierApplied=False, fxJPYPerUSD=args.fx, taxRate=args.tax, extraBytesAllowance=0.10,
        excludes='原本保存・API・GET/PUT・ログ・旧版・未計測動画・Mac処理時間'),
        scenarios=[estimate(totals, rate, hours, args.fx, args.tax, .025, .114)
                   for rate in (2, 3, 5) for hours in (1, 10, 30)])
    print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
