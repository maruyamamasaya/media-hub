import { useEffect, useRef, useState } from 'react';
import { Download, Heart, RotateCcw, Trash2, ImageOff, RefreshCw, Archive, Settings, Upload } from 'lucide-react';
import type { Asset, Tag, Collection, ArchiveRequest, TransferRequest } from './generated/contracts';
import { api, bytes, fileUrl } from './api';
import { Modal } from './Modal';

interface Props { asset: Asset; tags: Tag[]; collections: Collection[]; onClose: () => void; onChanged: (asset?: Asset) => void; onTagCreated: (tag: Tag) => void; }

export function AssetDetail({ asset: initial, tags, collections, onClose, onChanged, onTagCreated }: Props) {
  const video = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const element = video.current;
    const stopHidden = () => { if (document.hidden) element?.pause(); };
    document.addEventListener('visibilitychange', stopHidden);
    return () => { element?.pause(); document.removeEventListener('visibilitychange', stopHidden); };
  }, []);
  const [asset, setAsset] = useState(initial);
  const [name, setName] = useState(initial.name);
  const [note, setNote] = useState(initial.note);
  const [kind, setKind] = useState(initial.kind);
  const [tagIds, setTagIds] = useState(initial.tags.map(t => t.id));
  const [collectionIds, setCollectionIds] = useState(initial.collections.map(c => c.id));
  const [newTag, setNewTag] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [storageSettings, setStorageSettings] = useState(false);
  const [transferConfirm, setTransferConfirm] = useState(false);
  const [confirm, setConfirm] = useState<'trash' | 'purge' | null>(null);
  const [imageBroken, setImageBroken] = useState(false);
  const preview = asset.files.find(f => f.role === 'display' && f.state === 'ready');
  const original = asset.files.find(f => f.role === 'original');
  const small = !!original?.width && !!original?.height && Math.max(original.width, original.height) <= 128;
  const [viewMode, setViewMode] = useState<'fit' | 'actual' | 'zoom'>(() => {
    const f = initial.files.find(f => f.role === 'original');
    return f?.width && f?.height && Math.max(f.width, f.height) <= 128 ? 'actual' : 'fit';
  });
  const [pixelated, setPixelated] = useState(false);
  const shownFile = (small || viewMode !== 'fit') && original && ['image/png', 'image/jpeg', 'image/webp'].includes(original.mimeType) ? original : preview;
  const scale = viewMode === 'zoom' ? 4 : 1;


  async function action(work: () => Promise<Asset | void>) {
    setBusy(true); setError('');
    try {
      const updated = await work();
      if (updated) { setAsset(updated); onChanged(updated); }
      else { onChanged(); onClose(); }
    } catch (e) { setError(e instanceof Error ? e.message : '更新に失敗しました。'); }
    finally { setBusy(false); setConfirm(null); }
  }
  async function reload() {
    await action(async () => {
      const fresh = await api<Asset>(`/assets/${asset.id}`);
      setName(fresh.name); setNote(fresh.note); setKind(fresh.kind);
      setTagIds(fresh.tags.map(t => t.id)); setCollectionIds(fresh.collections.map(c => c.id));
      return fresh;
    });
  }
  async function addTag() {
    setBusy(true); setError('');
    try {
      const tag = await api<Tag>('/tags', 'POST', { name: newTag });
      onTagCreated(tag); setTagIds(ids => [...new Set([...ids, tag.id])]); setNewTag('');
    } catch (e) { setError(e instanceof Error ? e.message : 'タグを追加できません。'); }
    finally { setBusy(false); }
  }
  function toggle(ids: string[], id: string) { return ids.includes(id) ? ids.filter(i => i !== id) : [...ids, id]; }
  return <Modal title="素材の詳細" wide onClose={onClose}>
    <div className="detail-layout">
      <div className="detail-visual">
        <div className={`preview-canvas checkerboard ${viewMode}`}>
        {shownFile?.mimeType.startsWith('video/') && !imageBroken ? <video ref={video} src={fileUrl(asset, shownFile)} controls muted playsInline preload="metadata" style={{maxWidth: '100%', maxHeight: '100%'}} onError={() => setImageBroken(true)} /> : shownFile && !imageBroken ? <img style={{imageRendering: pixelated ? 'pixelated' : 'auto', ...(viewMode !== 'fit' ? {width: (shownFile.width ?? 0) * scale || undefined, height: (shownFile.height ?? 0) * scale || undefined} : {})}} src={fileUrl(asset, shownFile)} alt={asset.name} onError={() => setImageBroken(true)} /> : <div className="preview-placeholder"><ImageOff size={36} /><p>プレビューを表示できません</p><span>原本はダウンロードして確認できます。</span></div>}
        </div>
        <div className="preview-controls"><button className="secondary" aria-pressed={viewMode === 'fit'} onClick={() => setViewMode('fit')}>全体</button><button className="secondary" aria-pressed={viewMode === 'actual'} onClick={() => setViewMode('actual')}>原寸</button><button className="secondary" aria-pressed={viewMode === 'zoom'} onClick={() => setViewMode('zoom')}>4倍</button><label><input type="checkbox" checked={pixelated} onChange={e => setPixelated(e.target.checked)} />ドットを鮮明に</label></div>
        <div className="visual-bottom"><span>{original?.mimeType.replace('image/', '').toUpperCase()}</span><span>{original?.width ? `${original.width} × ${original.height}` : '画素数不明'}</span></div>
      </div>
      <section className="detail-fields">
        <div className="detail-actions"><button className="secondary" aria-label="素材の設定" aria-expanded={storageSettings} disabled={busy} onClick={() => { setStorageSettings(!storageSettings); setTransferConfirm(false); }}><Settings size={17} /></button><button className={asset.favorite ? 'favorite active' : 'favorite'} disabled={busy || asset.state === 'deleting'} aria-label={asset.favorite ? 'お気に入り解除' : 'お気に入りに追加'} onClick={() => action(() => api<Asset>(`/assets/${asset.id}`, 'PATCH', { revision: asset.revision, favorite: !asset.favorite }))}><Heart size={18} fill={asset.favorite ? 'currentColor' : 'none'} /></button>
          {original?.state === 'ready' ? <a className="button secondary" href={fileUrl(asset, original, true)} download><Download size={16} />原本をダウンロード</a> : <span className="error">原本を取得できません</span>}
        </div>
        {storageSettings ? <div className="storage-settings"><h3>保管場所の設定</h3><p className="muted">開発用リモートもこのPC内です。AWSへの通信は行いません。</p>{asset.localCleanupPending ? <p role="status">アップロードは完了しましたが、ローカル原本の整理が残っています。変更された原本は削除しません。</p> : null}{!asset.trashedAt ? <><button className="secondary" disabled={busy || asset.localCleanupPending || asset.storageLocation === 'local'} onClick={() => action(async () => { const updated = await api<Asset>(`/assets/${asset.id}/transfer`, 'POST', {revision: asset.revision, destination: 'local', removeLocal: false} satisfies TransferRequest); setImageBroken(false); return updated; })}><Download size={15} />ローカルにダウンロード</button><button className="secondary" disabled={busy || (asset.storageLocation !== 'local' && !asset.localCleanupPending)} onClick={() => setTransferConfirm(true)}><Upload size={15} />{asset.localCleanupPending ? 'ローカル原本の整理を再試行' : 'リモートにアップロード'}</button>{transferConfirm ? <div className="confirm-box"><p>原本を開発用リモートに保管し、照合後にローカルの原本ファイルを削除します。フォルダから参照している画像も削除対象です。プレビューは残ります。</p><button className="secondary" disabled={busy} onClick={() => setTransferConfirm(false)}>キャンセル</button><button className="primary" disabled={busy} onClick={() => action(async () => { const updated = await api<Asset>(`/assets/${asset.id}/transfer`, 'POST', {revision: asset.revision, destination: 'development-remote', removeLocal: true} satisfies TransferRequest); setTransferConfirm(false); setImageBroken(false); return updated; })}>{busy ? '処理中…' : '照合してローカル原本を整理'}</button></div> : null}</> : <p>ごみ箱から復元すると転送できます。</p>}</div> : null}<div className="storage-detail"><strong>{asset.storageLocation === 'local' ? asset.remoteAvailable ? 'ローカル保管（リモートにも保管）' : 'ローカル保管' : '開発用リモート保管'}</strong><p className="muted">{asset.storageLocation === 'local' ? asset.originalOwnership === 'reference' ? 'フォルダ内の原本を参照しています。素材を完全削除しても、参照元の画像は残ります。' : 'このPCのローカル画像フォルダに原本を保管しています。' : 'リモート保管を模擬しています。原本の実体はこのPC内です。'}</p>{asset.storageLocation === 'local' ? <code className="storage-path">{original?.objectKey.replace(/^local-originals\//, '').replace(/^references\/[^/]+\//, '')}</code> : null}{original?.error ? <p role="alert" className="error">{original.error}</p> : null}</div>{asset.storageLocation !== 'local' ? <div className="archive-detail"><strong>{asset.archivedAt ? 'アーカイブ' : '通常の素材'}</strong>{!asset.trashedAt ? <button className="secondary" disabled={busy || asset.state === 'deleting'} onClick={() => action(() => api<Asset>(`/assets/${asset.id}/archive`, 'POST', { revision: asset.revision, archived: !asset.archivedAt } satisfies ArchiveRequest))}><Archive size={15} />{asset.archivedAt ? '通常に戻す' : 'アーカイブする'}</button> : null}<p className="muted">{asset.archivedAt ? '原本の取得や編集は、そのまま利用できます。' : 'アーカイブすると通常の一覧から外れます。'}</p></div> : null}
        {error ? <div className="error-box" role="alert">{error}<button onClick={reload} disabled={busy}>最新の情報を読み込む</button></div> : null}
        <form onSubmit={event => { event.preventDefault(); action(() => api<Asset>(`/assets/${asset.id}`, 'PATCH', { revision: asset.revision, name, note, kind, tagIds, collectionIds })); }}>
          <label>名前<input value={name} maxLength={255} required onChange={e => setName(e.target.value)} /></label>
          <label>種別<select value={kind} onChange={e => setKind(e.target.value)}><option value="image">画像</option><option value="photo">写真</option><option value="video">動画</option></select></label>
          <label>メモ<textarea rows={3} value={note} maxLength={5000} placeholder="用途やアイデアを書き留める" onChange={e => setNote(e.target.value)} /></label>
          <fieldset><legend>タグ</legend><div className="tag-options">{tags.map(tag => <label className={tagIds.includes(tag.id) ? 'check-chip selected' : 'check-chip'} key={tag.id}><input type="checkbox" checked={tagIds.includes(tag.id)} onChange={() => setTagIds(toggle(tagIds, tag.id))} />{tag.name}</label>)}{!tags.length ? <span className="muted">まだタグがありません</span> : null}</div></fieldset>
          <div className="inline-input"><input aria-label="新しいタグ" placeholder="新しいタグ" value={newTag} maxLength={100} onChange={e => setNewTag(e.target.value)} /><button type="button" className="secondary" disabled={busy || !newTag.trim()} onClick={addTag}>追加</button></div>
          <fieldset><legend>コレクション</legend>{collections.length ? collections.map(collection => <label className="collection-check" key={collection.id}><input type="checkbox" checked={collectionIds.includes(collection.id)} onChange={() => setCollectionIds(toggle(collectionIds, collection.id))} />{collection.name}</label>) : <span className="muted">サイドバーから作成できます</span>}</fieldset>
          <button className="primary save" disabled={busy || asset.state === 'deleting'}>{busy ? '処理中…' : '変更を保存'}</button>
        </form>
        <dl className="file-info"><dt>元ファイル</dt><dd>{original?.originalFilename}</dd><dt>サイズ</dt><dd>{bytes(original?.byteSize ?? 0)}</dd><dt>追加日時</dt><dd>{new Date(asset.createdAt).toLocaleString('ja-JP')}</dd><dt>撮影日時</dt><dd>{asset.capturedAt ? new Date(asset.capturedAt).toLocaleString('ja-JP') : '未設定'}</dd></dl>
        <button className="text-button" disabled={busy} onClick={() => { setImageBroken(false); action(() => api<Asset>(`/assets/${asset.id}/preview-retry`, 'POST', {})); }}><RefreshCw size={14} />プレビューを再生成</button>
        <div className="danger-zone">{asset.trashedAt ? <><button className="secondary" disabled={busy || asset.state === 'deleting'} onClick={() => action(() => api<Asset>(`/assets/${asset.id}/restore`, 'POST', { revision: asset.revision }))}><RotateCcw size={15} />復元する</button><button className="danger" disabled={busy} onClick={() => setConfirm('purge')}><Trash2 size={15} />{asset.state === 'deleting' ? '削除を再試行' : '完全に削除'}</button></> : <button className="text-button" disabled={busy} onClick={() => setConfirm('trash')}><Trash2 size={15} />ごみ箱へ移動</button>}</div>
        {confirm ? <div className="confirm-box" role="alert"><p>{confirm === 'purge' ? '原本と素材情報を完全に削除します。元の入力フォルダのファイルは削除しません。この操作は取り消せません。' : 'この素材をごみ箱へ移動します。後から復元できます。'}</p><button className="secondary" onClick={() => setConfirm(null)}>キャンセル</button><button className="danger" disabled={busy} onClick={() => action(() => confirm === 'purge' ? api<void>(`/assets/${asset.id}`, 'DELETE', { revision: asset.revision }).then(() => undefined) : api<Asset>(`/assets/${asset.id}/trash`, 'POST', { revision: asset.revision }))}>{confirm === 'purge' ? '完全削除を実行' : '移動を実行'}</button></div> : null}
      </section>
    </div>
  </Modal>;
}
