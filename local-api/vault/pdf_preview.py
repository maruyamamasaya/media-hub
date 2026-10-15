"""First-page preview using the bundled Apple PDFKit helper. Never logs content."""
import os
from pathlib import Path
import subprocess


def render_pdf(source, target, pass_fds=()):
    helper = Path(os.getenv('MEDIA_HUB_CRYPTO_HELPER', Path(__file__).resolve().parents[2] / '.local/Media Hub.app/Contents/Resources/MediaHubCrypto'))
    if not helper.is_file():
        return False
    result = subprocess.run([str(helper), '--pdf-thumbnail', str(source), str(target)],
                            pass_fds=pass_fds, capture_output=True, timeout=60)
    return result.returncode == 0 and Path(target).is_file()
