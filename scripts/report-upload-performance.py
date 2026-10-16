#!/usr/bin/env python3
"""Print aggregate local upload diagnostics without filenames or AWS credentials."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='folder containing scan/upload-performance.json')
    args = parser.parse_args()
    found = False
    for filename, title in [('scan-performance.json', '準備'), ('upload-performance.json', '送信')]:
        path = args.directory / filename
        if not path.is_file():
            continue
        found = True
        result = json.loads(path.read_text())
        seconds = result['wallSeconds']
        print(f'{title}: 経過 {seconds:.3f}秒')
        if 'enumerationSeconds' in result:
            print(f"  列挙・属性確認: {result['enumerationSeconds']:.3f}秒 / {result['itemCount']}件")
        if 'completedItems' in result:
            print(f"  状態: {result['state']} / 今回完了 {result['completedItems']}件 / 重複除外 {result['duplicateCount']}件")
            if seconds:
                print(f"  今回完了原本の実効速度: {result['completedSourceBytes'] / seconds / 1e6:.3f}MB/秒 / {result['completedItems'] / seconds:.3f}件/秒")
        for name, entry in sorted(result['stages'].items(), key=lambda pair: pair[1]['seconds'], reverse=True):
            print(f"  {name}: 累積 {entry['seconds']:.3f}秒 / {entry['calls']}回 / 最大 {entry['maxSeconds']:.3f}秒 / 失敗 {entry['failures']}回")
        if result.get('counters'):
            print('  PUT要求本文bytes:', json.dumps(result['counters'], sort_keys=True))
    print('累積時間は並列・入れ子を含むため合算不可。実効速度はネットワーク帯域の実測値ではありません。')
    return 0 if found else 1


if __name__ == '__main__':
    raise SystemExit(main())
