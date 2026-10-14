"""Private desktop child: startup config via stdin; EOF stops the server."""
import asyncio
import json
import os
import socket
import sys
import threading
from pathlib import Path

import uvicorn
from vault.app import create_app


def main():
    config = json.loads(sys.stdin.readline())
    token = config['token']
    if not isinstance(token, str) or len(token) < 32:
        raise ValueError('Invalid startup token')
    root = Path(config['dataRoot']).resolve()
    root.mkdir(parents=True, exist_ok=True)
    # OS releases this lock even after a crash; never remove the lock file.
    with (root / '.desktop.lock').open('a+b') as lock:
        lock.seek(0)
        if os.name == 'nt':
            import msvcrt
            if not lock.read(1):
                lock.write(b'0')
                lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
            origin = f'http://127.0.0.1:{port}'
            app = create_app(root, config['fixtures'], desktop_token=token, desktop_origin=origin, cloud_only=True, privacy_enabled=True)
            server = uvicorn.Server(uvicorn.Config(app, access_log=False, log_level='error', timeout_graceful_shutdown=30))

            def watch_parent():
                sys.stdin.read()  # pipe EOF on normal quit or parent crash
                server.should_exit = True

            threading.Thread(target=watch_parent, daemon=True).start()

            async def serve():
                task = asyncio.create_task(server.serve(sockets=[sock]))
                while not server.started and not task.done():
                    await asyncio.sleep(.02)
                if server.started:
                    print(json.dumps({'origin': origin, 'pid': os.getpid()}), flush=True)
                await task

            asyncio.run(serve())


if __name__ == '__main__':
    main()
