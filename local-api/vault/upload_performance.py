"""Local aggregate timings: no filenames, object keys, credentials or payloads."""
from contextlib import contextmanager
from functools import wraps
from pathlib import Path
import threading
import time


class UploadPerformance:
    def __init__(self):
        self.started = time.perf_counter()
        self.lock = threading.Lock()
        self.stages = {}
        self.counters = {}

    @contextmanager
    def measure(self, name):
        started = time.perf_counter()
        failed = False
        try:
            yield
        except BaseException:
            failed = True
            raise
        finally:
            elapsed = time.perf_counter() - started
            with self.lock:
                entry = self.stages.setdefault(name, {'calls': 0, 'seconds': 0.0, 'maxSeconds': 0.0, 'failures': 0})
                entry['calls'] += 1
                entry['seconds'] += elapsed
                entry['maxSeconds'] = max(entry['maxSeconds'], elapsed)
                entry['failures'] += int(failed)

    def add(self, name, amount):
        with self.lock:
            self.counters[name] = self.counters.get(name, 0) + amount

    def result(self):
        with self.lock:
            return {'schemaVersion': 1, 'wallSeconds': time.perf_counter() - self.started,
                    'stages': {k: dict(v) for k, v in self.stages.items()},
                    'counters': dict(self.counters)}


def timed_stage(name):
    """Resolve by plan, keeping overlapping next-folder scans out of this run."""
    def decorate(method):
        @wraps(method)
        def measured(self, plan, *args, **kwargs):
            plan_id = plan['id'] if isinstance(plan, dict) else plan
            metrics = getattr(self, '_performance', {}).get(plan_id)
            if metrics is None:
                return method(self, plan, *args, **kwargs)
            with metrics.measure(name):
                return method(self, plan, *args, **kwargs)
        return measured
    return decorate


def timed_s3(method):
    @wraps(method)
    def measured(self, operation, *args, **kwargs):
        metrics = getattr(self, 'performance', None)
        if metrics is None:
            return method(self, operation, *args, **kwargs)
        body_bytes = 0
        if operation in ('put-object', 'upload-part') and '--body' in args:
            try:
                body_bytes = Path(args[args.index('--body') + 1]).stat().st_size
            except OSError:
                pass
        metrics.add('attemptedBodyBytes', body_bytes)
        with metrics.measure('s3.' + operation):
            result = method(self, operation, *args, **kwargs)
        metrics.add('acknowledgedBodyBytes', body_bytes)
        return result
    return measured
