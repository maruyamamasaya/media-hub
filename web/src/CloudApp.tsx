import { useEffect, useState } from 'react';
import { Cloud, Upload, ShieldCheck } from 'lucide-react';
import { CloudFolders } from './CloudFolders';
import { FolderUploader } from './FolderUploader';
import { LightVideoMaker } from './LightVideoMaker';
import './styles.css';
import { api } from './api';

export function CloudApp() {
  const [page, setPage] = useState<'library' | 'upload' | 'light' | 'settings'>('library');
  const [epoch, setEpoch] = useState(0);
  const [locking, setLocking] = useState(false);
  const [lockError, setLockError] = useState('');
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    let disposed = false;
    const relock = async () => {
      clearTimeout(timer); setLocking(true); setLockError(''); setPage('library'); setEpoch(previous => previous + 1);
      try { await api('/folder-locks/relock', 'POST'); if (!disposed) setLocking(false); }
      catch { if (!disposed) setLockError('再ロックできませんでした。アプリを起動し直してください。'); }
    };
    const visibility = () => { if (document.hidden) void relock(); };
    const unlocked = () => { clearTimeout(timer); timer = setTimeout(() => void relock(), 300_000); };
    const requested = () => { void relock(); };
    document.addEventListener('visibilitychange', visibility);
    window.addEventListener('folder-unlocked', unlocked);
    window.addEventListener('folder-relock', requested);
    void relock();
    return () => { disposed = true; clearTimeout(timer); document.removeEventListener('visibilitychange', visibility); window.removeEventListener('folder-unlocked', unlocked); window.removeEventListener('folder-relock', requested); };
  }, []);
  if (locking) return <main className="cloud-upload-page"><h1>再ロック中</h1><p>{lockError || '鍵の状態を確認しています…'}</p></main>;
  return <div key={epoch} className="cloud-app"><header className="cloud-app-header"><strong>media-hub</strong><nav aria-label="メインメニュー"><button aria-current={page === 'library' ? 'page' : undefined} onClick={() => setPage('library')}><Cloud size={17} />S3フォルダ</button><button aria-current={page === 'upload' ? 'page' : undefined} onClick={() => setPage('upload')}><Upload size={17} />アップロード</button><button aria-current={page === 'light' ? 'page' : undefined} onClick={() => setPage('light')}>軽量版を作る</button><button aria-current={page === 'settings' ? 'page' : undefined} onClick={() => setPage('settings')}>設定</button></nav></header>{page === 'library' ? <CloudFolders /> : page === 'upload' ? <main className="cloud-upload-page"><h1>フォルダをアップロード</h1><FolderUploader onOpenLibrary={() => setPage('library')} /></main> : page === 'light' ? <main className="cloud-upload-page"><h1>軽量版を作る</h1><LightVideoMaker /></main> : <main className="cloud-upload-page"><h1>設定</h1><p><ShieldCheck size={18} />本人専用・非公開</p><p>原本はS3で管理します。アップロードはMacから手動で行い、iPhoneは閲覧専用です。</p><p>ローカルライブラリへの取り込み・フォルダ同期・ローカル保管への切り替えは終了しました。</p><p>以前のローカル素材は削除していません。閲覧用の一時キャッシュは原本の正本として扱いません。</p></main>}</div>;
}
