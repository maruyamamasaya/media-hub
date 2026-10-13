"""Isolated UI fixtures; the WebM display file simulates a converter output."""
import io
import sys
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'local-api'))
from PIL import Image
from vault.service import Vault, identifier, LIBRARY_ID
from vault.storage import checksum

root = Path(sys.argv[1]).resolve()
if not root.is_relative_to((ROOT / '.local/test-runs').resolve()):
    raise ValueError('Fixtures must remain in the isolated test directory')
vault = Vault(root / 'library', root / 'fixtures')
for color in ['red', 'blue', 'green']:
    buffer = io.BytesIO()
    Image.new('RGB', (160, 100), color).save(buffer, 'PNG')
    job = vault.new_job()
    vault.add_stream(job, color + '.png', io.BytesIO(buffer.getvalue()))
with patch('vault.service.shutil.which', return_value=None):
    job = vault.new_job()
    vault.add_stream(job, 'clip.webm', io.BytesIO((root / 'clip.webm').read_bytes()))
asset = vault.asset(vault.job(job)['items'][0]['assetId'])
display = next(f for f in asset['files'] if f['role'] == 'display')
target = root / 'clip.webm'
vault.storage.put(target, display['objectKey'])
with vault.repo.connect() as db:
    db.execute("UPDATE files SET mimeType='video/webm',byteSize=?,sha256=?,state='ready',error=NULL WHERE id=?", (target.stat().st_size, checksum(target), display['id']))
vault.create_entity('collections', 'UI collection')
