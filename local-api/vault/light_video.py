"""Manual local derivatives only. No AWS operations and no source writes."""
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import threading
import uuid

from .folder_upload import atomic_json, signature
from .service import VaultError

EXTENSIONS = {'.mov', '.mp4', '.m4v', '.mkv', '.webm'}


def probe(path):
    executable = shutil.which('ffprobe')
    if not executable:
        raise VaultError('missing_tool', '動画ツールが見つかりません。ffmpegの設定が必要です。', 409)
    try:
        result = subprocess.run([executable, '-v', 'error', '-protocol_whitelist', 'file', '-show_entries',
            'format=duration:stream=codec_type,width,height,r_frame_rate,color_transfer', '-of', 'json', str(path)],
            capture_output=True, text=True, check=True, timeout=60)
        data = json.loads(result.stdout)
        video = next(s for s in data['streams'] if s.get('codec_type') == 'video')
        duration = float(data['format']['duration'])
        numerator, denominator = video['r_frame_rate'].split('/')
        fps = float(numerator) / float(denominator)
        if not math.isfinite(duration) or duration <= 0 or not math.isfinite(fps) or fps <= 0:
            raise ValueError()
        return duration, video, fps
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, StopIteration, ZeroDivisionError):
        raise VaultError('invalid_video', '動画を読み取れませんでした。iCloudから取得済みか確認してください。', 409)


class LightVideos:
    def __init__(self, root):
        self.root = Path(root) / 'light-videos'
        self.root.mkdir(parents=True, exist_ok=True)
        self.root.chmod(0o700)
        self.lock = threading.RLock()
        self.active = None
        self.process = None
        for path in self.root.glob('*/job.json'):
            job = json.loads(path.read_text())
            if job['state'] == 'creating':
                job['state'] = 'interrupted'
                job['error'] = '作成が中断しました。手動で再作成できます。'
                atomic_json(path, job)

    def read(self, job_id):
        try:
            if str(uuid.UUID(job_id)) != job_id:
                raise ValueError()
        except (ValueError, TypeError):
            raise VaultError('invalid_request', '作成IDが不正です。')
        path = self.root / job_id / 'job.json'
        if not path.is_file():
            raise VaultError('not_found', '作成履歴がありません。', 404)
        return json.loads(path.read_text())

    def save(self, job):
        directory = self.root / job['id']
        directory.mkdir(exist_ok=True, mode=0o700)
        atomic_json(directory / 'job.json', job)
        (directory / 'job.json').chmod(0o600)

    def public(self, job):
        return {key: job[key] for key in ('id', 'name', 'state', 'originalBytes', 'estimatedBytes',
            'outputBytes', 'durationSeconds', 'progress', 'error', 'warning')}

    def list(self):
        with self.lock:
            return [self.public(json.loads(p.read_text())) for p in sorted(self.root.glob('*/job.json'), key=lambda p: p.stat().st_mtime, reverse=True)]

    def inspect(self, body):
        if set(body) != {'path'} or not isinstance(body['path'], str):
            raise VaultError('invalid_request', '動画を選んでください。')
        path = Path(body['path']).expanduser()
        if not path.is_absolute() or path.is_symlink() or not path.is_file() or path.suffix.lower() not in EXTENSIONS:
            raise VaultError('invalid_request', 'Macにある動画ファイルを選んでください。')
        path = path.resolve()
        before = signature(path.stat())
        if not 0 < before[2] <= 5 * 1024**3:
            raise VaultError('too_large', '1本5GiB以下の動画に対応しています。', 413)
        duration, video, fps = probe(path)
        if signature(path.stat()) != before:
            raise VaultError('changed_file', '動画が変更されました。選び直してください。', 409)
        if duration > 7200 or fps > 60.1:
            raise VaultError('unsupported_video', '初期版は2時間以内・60fps以下に対応しています。', 409)
        if video.get('color_transfer') in ('smpte2084', 'arib-std-b67'):
            raise VaultError('unsupported_video', 'HDR動画は画質確認が必要なため、この機能ではまだ変換しません。', 409)
        estimated = math.ceil(duration * 3_000_000 / 8 * 1.1)
        warning = '元の動画が軽いため、容量が増える可能性があります。' if before[2] <= estimated else ''
        with self.lock:
            for p in self.root.glob('*/job.json'):
                old = json.loads(p.read_text())
                if old['source'] == str(path) and old['signature'] == before and old['state'] in ('planned', 'creating', 'complete'):
                    return self.public(old)
            job = dict(id=str(uuid.uuid4()), name=path.name, source=str(path), signature=before, state='planned',
                originalBytes=before[2], estimatedBytes=estimated, outputBytes=0, durationSeconds=duration,
                progress=0, error='', warning=warning)
            self.save(job)
            return self.public(job)

    def start(self, job_id):
        with self.lock:
            if self.active:
                raise VaultError('busy', '別の動画を作成中です。', 409)
            job = self.read(job_id)
            if job['state'] == 'complete':
                return self.public(job)
            if not shutil.which('ffmpeg'):
                raise VaultError('missing_tool', 'ffmpegが見つかりません。', 409)
            if signature(Path(job['source']).stat()) != job['signature']:
                raise VaultError('changed_file', '原本が変更されました。動画を選び直してください。', 409)
            if shutil.disk_usage(self.root).free < job['estimatedBytes'] * 2 + 256 * 1024**2:
                raise VaultError('storage_error', '軽量版を作る空き容量が不足しています。', 507)
            job.update(state='creating', progress=0, error='')
            self.active = job_id
            self.save(job)
            threading.Thread(target=self.work, args=(job_id,), daemon=True).start()
            return self.public(job)

    def cancel(self, job_id):
        with self.lock:
            job = self.read(job_id)
            if job['state'] == 'creating':
                job.update(state='cancelled', error='作成を停止しました。原本は保持されています。')
                self.save(job)
                if self.process:
                    self.process.terminate()
            return self.public(job)

    def shutdown(self):
        with self.lock:
            if self.active:
                self.cancel(self.active)

    def work(self, job_id):
        directory = self.root / job_id
        pending = directory / 'working.mp4'
        try:
            with self.lock:
                job = self.read(job_id)
                if job['state'] != 'creating':
                    return
                pending.unlink(missing_ok=True)  # Only this job's unfinished derivative.
                command = [shutil.which('ffmpeg'), '-nostdin', '-v', 'error', '-n', '-protocol_whitelist', 'file',
                    '-i', job['source'], '-t', str(job['durationSeconds']), '-map', '0:v:0', '-map', '0:a:0?',
                    '-map_metadata', '-1', '-map_chapters', '-1', '-vf',
                    "scale=w='if(gte(iw,ih),min(1920,iw),min(1080,iw))':h='if(gte(iw,ih),min(1080,ih),min(1920,ih))':force_original_aspect_ratio=decrease:force_divisible_by=2",
                    '-c:v', 'libx264', '-preset', 'medium', '-threads', '4', '-b:v', '2872k',
                    '-maxrate', '2872k', '-bufsize', '5744k', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k',
                    '-movflags', '+faststart', '-fs', str(job['estimatedBytes'] * 2), '-progress', 'pipe:1', str(pending)]
                self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                process = self.process
            for line in process.stdout:
                if line.startswith('out_time_us='):
                    try:
                        progress = min(99, max(0, int(float(line.split('=', 1)[1]) / 1_000_000 / job['durationSeconds'] * 100)))
                    except ValueError:
                        continue
                    with self.lock:
                        current = self.read(job_id)
                        if current['state'] == 'creating' and current['progress'] != progress:
                            current['progress'] = progress
                            self.save(current)
            if process.wait() != 0:
                raise ValueError()
            duration, _, _ = probe(pending)
            if abs(duration - job['durationSeconds']) > 1 or signature(Path(job['source']).stat()) != job['signature']:
                raise ValueError()
            with self.lock:
                current = self.read(job_id)
                if current['state'] != 'creating':
                    return
                output = directory / 'light.mp4'
                pending.chmod(0o600)
                pending.replace(output)
                current.update(state='complete', progress=100, outputBytes=output.stat().st_size)
                self.save(current)
        except Exception:
            with self.lock:
                current = self.read(job_id)
                if current['state'] == 'creating':
                    current.update(state='failed', error='作成できませんでした。原本と空き容量を確認して再試行してください。')
                    self.save(current)
        finally:
            pending.unlink(missing_ok=True)
            with self.lock:
                self.process = None
                self.active = None

    def content(self, job_id):
        with self.lock:
            job = self.read(job_id)
            path = self.root / job_id / 'light.mp4'
            if job['state'] != 'complete' or not path.is_file():
                raise VaultError('not_found', '軽量版はまだ作成されていません。', 404)
            return path, Path(job['name']).stem + '-軽量版.mp4'

    def prepare_upload(self, job_id, uploads):
        # Preparation is local only. The existing uploader requires its own
        # explicit confirmUpload action before making any cloud calls.
        with self.lock, uploads.lock:
            job = self.read(job_id)
            path, display_name = self.content(job_id)
            destinations = uploads.list()
            if not destinations:
                raise VaultError('missing_destination', '先にフォルダアップロードで保存先を設定してください。', 409)
            destination = destinations[0]
            if path.stat().st_size != job['outputBytes']:
                raise VaultError('changed_file', '軽量版の容量が変わりました。送信を停止しました。', 409)
            previous_id = job.get('uploadPlanId')
            if previous_id:
                previous = uploads.read(previous_id)
                if all(previous[k] == destination[k] for k in ('bucket', 'profile', 'region')):
                    item = previous['items'][0]
                    if signature(path.stat()) != item['signature']:
                        raise VaultError('changed_file', '確認後に軽量版が変わりました。送信を停止しました。', 409)
                    return uploads.public(previous)
            prepared = uploads.scan({'path': str(path.parent), **{k: destination[k] for k in ('bucket', 'profile', 'region')}})
            plan = uploads.read(prepared['id'])
            if len(plan['items']) != 1 or plan['items'][0]['relativePath'] != 'light.mp4' or len(plan['folders']) != 1:
                raise VaultError('invalid_request', '軽量版以外の素材が含まれるため送信できません。', 409)
            plan['name'] = Path(job['name']).stem + '（軽量版）'
            plan['folders'][0]['name'] = plan['name']
            plan['items'][0]['name'] = display_name
            uploads.save(plan)
            job['uploadPlanId'] = plan['id']
            self.save(job)
            return uploads.public(plan)
