import uvicorn
from vault.app import create_app

if __name__ == '__main__':
    uvicorn.run(create_app(cloud_only=True, privacy_enabled=True), host='127.0.0.1', port=8765, access_log=False)
