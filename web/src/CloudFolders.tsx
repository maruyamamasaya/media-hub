import { useEffect, useState } from 'react';
import { Cloud, FolderOpen, ChevronRight, Image as ImageIcon, Play, Download } from 'lucide-react';
import type { FolderUpload, FolderUploadItem } from './generated/contracts';
import { api, bytes } from './api';
import { Modal } from './Modal';

function mediaUrl(plan: FolderUpload, item: FolderUploadItem, thumbnail = false) {
  return `/api/v1/folder-library/${plan.id}/items/${item.id}/content${thumbnail ? '?thumbnail=true' : ''}`;
}
function video(item: FolderUploadItem) { return /\.(mp4|mov|m4v|webm|mkv)$/i.test(item.name); }
function CloudTile({plan, item, onOpen}: {plan: FolderUpload; item: FolderUploadItem; onOpen: () => void}) {
  const [broken, setBroken] = useState(false);
  return <button className="asset-card cloud-media-tile" onClick={onOpen}><div className="card-image">{!video(item) && !broken ? <img loading="lazy" src={mediaUrl(plan, item, true)} alt="" onError={() => setBroken(true)} /> : <div className="card-placeholder">{video(item) ? <Play size={32} /> : <ImageIcon size={32} />}<span>{video(item) ? '動画' : '開いて表示'}</span></div>}<div className="card-caption"><h3>{item.name}</h3></div></div><small>{bytes(item.byteSize)}</small></button>;
}

export function CloudFolders() {
  const [plans, setPlans] = useState<FolderUpload[]>([]);
  const [selected, setSelected] = useState<FolderUpload | null>(null);
  const [folderId, setFolderId] = useState<string | null>(null);
  const [item, setItem] = useState<FolderUploadItem | null>(null);
  const [error, setError] = useState('');
  const [mediaError, setMediaError] = useState('');
  const [loading, setLoading] = useState(true);
  const [unlocking, setUnlocking] = useState(false);
  const [setting, setSetting] = useState(false);
  const [password, setPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [saving, setSaving] = useState(false);
  async function reload() { setPlans(await api<FolderUpload[]>('/folder-library')); setSelected(null); setFolderId(null); setItem(null); }
  async function unlock() {
    const entered = password; setPassword(''); setError(''); setSaving(true);
    try { await api('/folder-locks/unlock', 'POST', {password: entered}); window.dispatchEvent(new Event('folder-unlocked')); setUnlocking(false); await reload(); }
    catch (e) { setError(e instanceof Error ? e.message : '解除できませんでした。'); }
    finally { setSaving(false); }
  }
  async function saveLock(remove: boolean) {
    if (!selected || !folderId) return;
    if (!remove && password !== confirmation) { setError('入力が一致しません。'); return; }
    const entered = password; setPassword(''); setConfirmation(''); setError(''); setSaving(true);
    try { await api('/folder-locks/settings', 'POST', {planId: selected.id, folderId, password: remove ? null : entered, confirmSave: true}); setSetting(false); window.dispatchEvent(new Event('folder-relock')); }
    catch (e) { setError(e instanceof Error ? e.message : '保存できませんでした。'); }
    finally { setSaving(false); }
  }
  useEffect(() => { const abort = new AbortController(); api<FolderUpload[]>('/folder-library', 'GET', undefined, abort.signal).then(setPlans).catch(e => { if (e.name !== 'AbortError') setError(e.message); }).finally(() => { if (!abort.signal.aborted) setLoading(false); }); return () => abort.abort(); }, []);
  const children = selected?.folders.filter(f => f.parentId === folderId) ?? [];
  const files = selected?.items.filter(i => i.folderId === folderId) ?? [];
  const trail = [];
  let current = selected?.folders.find(f => f.id === folderId);
  while (current) { trail.unshift(current); current = selected?.folders.find(f => f.id === current!.parentId); }
  function openFolder(plan: FolderUpload) { setSelected(plan); setFolderId(plan.folders.find(f => f.parentId === null)?.id ?? null); }
  return <section className="workspace" aria-label="S3フォルダライブラリ">
    <div className="page-heading"><div><h1>S3フォルダ</h1><p>アップロード済みの画像・動画を、元のフォルダ構成で見る</p></div><Cloud size={24} /></div>
    <p className="muted">原本はS3で管理します。素材を開くときだけ取得し、閲覧用キャッシュを使います。一覧表示で原本を自動ダウンロードしません。</p>
    <div className="upload-assurances"><button className="secondary" onClick={() => { setPassword(''); setUnlocking(true); }}>隠したフォルダを開く</button><button className="secondary" onClick={() => window.dispatchEvent(new Event('folder-relock'))}>再ロック</button>{selected && folderId ? <button className="secondary" onClick={() => { setPassword(''); setConfirmation(''); setSetting(true); }}>このフォルダの鍵を設定</button> : null}</div>
    {unlocking ? <Modal title="隠したフォルダを開く" onClose={() => { setUnlocking(false); setPassword(''); }}><form onSubmit={event => { event.preventDefault(); void unlock(); }}><label>フォルダのパスワード<input type="password" autoComplete="off" value={password} onChange={event => setPassword(event.target.value)} /></label><p>同じパスワードのフォルダを解除します。親に別の鍵がある場合は、親も解除してください。</p><button className="primary" disabled={saving || !password}>解除する</button>{error ? <p role="alert">{error}</p> : null}</form></Modal> : null}
    {setting && selected ? <Modal title="フォルダの鍵" onClose={() => { setSetting(false); setPassword(''); setConfirmation(''); }}><h3>{selected.folders.find(folder => folder.id === folderId)?.name}</h3><p>現在：{selected.folders.find(folder => folder.id === folderId)?.isLocked ? '鍵あり（解除中）' : 'このフォルダ自身の鍵なし'}</p><p>このフォルダと子の中身を隠します。設定は非公開S3へ保存し、iPhoneにも反映します。原本は変更しません。</p><form onSubmit={event => { event.preventDefault(); void saveLock(false); }}><label>新しいPIN（半角数字6桁）<input type="password" autoComplete="new-password" inputMode="numeric" pattern="[0-9]{6}" minLength={6} maxLength={6} value={password} onChange={event => setPassword(event.target.value)}/></label><label>もう一度<input type="password" autoComplete="new-password" value={confirmation} onChange={event => setConfirmation(event.target.value)}/></label><button className="primary" disabled={saving || !/^[0-9]{6}$/.test(password)}>鍵を設定して隠す</button></form><button className="secondary" disabled={saving} onClick={() => void saveLock(true)}>このフォルダを鍵なしにする</button><p>初期版は10フォルダまで。親の鍵はこの操作では外れません。軽量版の別フォルダは別に設定してください。</p>{error ? <p role="alert">{error}</p> : null}</Modal> : null}
    {loading ? <p role="status">保存済みフォルダを確認しています…</p> : null}{error ? <p role="alert" className="error-box">{error}</p> : null}
    <nav className="upload-breadcrumbs" aria-label="S3フォルダ階層"><button onClick={() => { setSelected(null); setFolderId(null); }}>保存済みフォルダ</button>{trail.map(folder => <span key={folder.id}><ChevronRight size={12} /><button onClick={() => setFolderId(folder.id)}>{folder.name}</button></span>)}</nav>
    {!loading && !selected && !plans.length ? <p>表示できるフォルダはありません。アップロードするか、隠したフォルダを解除してください。</p> : null}
    <div className="cloud-folder-grid">{!selected ? plans.map(plan => <button key={plan.id} onClick={() => openFolder(plan)}><FolderOpen size={27} /><span>{plan.name}<small>{plan.items.length}件 · {bytes(plan.byteSize)}</small></span><ChevronRight size={18} /></button>) : children.map(folder => <button key={folder.id} onClick={() => setFolderId(folder.id)}><FolderOpen size={27} /><span>{folder.name}</span><ChevronRight size={18} /></button>)}</div>
    {selected ? <div className="asset-grid">{files.map(file => <CloudTile key={file.id} plan={selected} item={file} onOpen={() => { setItem(file); setMediaError(''); }} />)}</div> : null}
    {selected && !children.length && !files.length ? <p>このフォルダは空です。</p> : null}
    {selected && item ? <Modal title={item.name} onClose={() => setItem(null)} wide><div className="cloud-media-view">{video(item) ? <video controls preload="metadata" src={mediaUrl(selected, item)} onError={() => setMediaError('動画を表示できません。形式または原本100MiBの閲覧上限を確認してください。')} /> : <img src={mediaUrl(selected, item)} alt={item.name} onError={() => setMediaError('画像を表示できません。AWS認証・対応形式・原本100MiBの閲覧上限を確認してください。')} />}{mediaError ? <p role="alert" className="error-box">{mediaError}</p> : null}<p>{bytes(item.byteSize)} · 非公開で保存済み</p><a className="secondary" href={mediaUrl(selected, item) + '?download=true'}><Download size={16} />原本をダウンロード</a></div></Modal> : null}
  </section>;
}
