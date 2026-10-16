"""Bounded ordinary-thumbnail cache. The caller must authorize before every read."""
import hashlib
import os
from pathlib import Path
import threading


class ThumbnailCache:
    def __init__(self, root, limit=256 * 1024 ** 2):
        self.root = Path(root)
        self.limit = limit
        self.lock = threading.RLock()
        self.generation = 0
        self.root.mkdir(parents=True, exist_ok=True)
        self.root.chmod(0o700)
        self.used = sum(p.stat().st_size for p in self.root.glob("*.thumb"))

    def path(self, identity):
        return self.root / (hashlib.sha256(identity.encode()).hexdigest() + '.thumb')

    def read(self, identity, digest):
        with self.lock:
            path = self.path(identity)
            try:
                data = path.read_bytes()
                if len(data) > 50000 or hashlib.sha256(data).hexdigest() != digest:
                    self.used = max(0, self.used - len(data))
                    path.unlink(missing_ok=True)
                    return None
                os.utime(path, None)
                return data
            except FileNotFoundError:
                return None

    def store(self, identity, data, digest, generation):
        if len(data) > 50000 or hashlib.sha256(data).hexdigest() != digest:
            return
        with self.lock:
            if generation != self.generation:
                return
            path = self.path(identity)
            previous = path.stat().st_size if path.exists() else 0
            path.write_bytes(data)
            path.chmod(0o600)
            self.used += len(data) - previous
            if self.used <= self.limit:
                return
            files = sorted(self.root.glob('*.thumb'), key=lambda p: p.stat().st_mtime)
            total = self.used
            for old in files:
                if total <= self.limit:
                    break
                total -= old.stat().st_size
                old.unlink(missing_ok=True)
            self.used = total

    def stats(self):
        with self.lock:
            return {'bytes': self.used, 'limit': self.limit}

    def clear(self):
        with self.lock:
            self.generation += 1
            for path in self.root.glob('*.thumb'):
                path.unlink(missing_ok=True)
            self.used = 0
            return self.stats()
