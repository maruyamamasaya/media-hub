import { useEffect, useRef, useState } from 'react';
import { Library, Heart, Folder, Plus, Search, Settings, Trash2, Download, Upload, Image as ImageIcon, ArrowUpRight, SlidersHorizontal, Menu, Check, AlertCircle, X, Archive, Monitor, Cloud } from 'lucide-react';
import type { Asset, AssetPage, Collection, Tag, ImportJob, BulkOrganizeRequest, BulkOrganizeResult, BulkDownloadRequest, StorageRoot, SyncDirectoryRequest, SyncDirectoryResult } from './generated/contracts';
import { api, bytes, fileUrl } from './api';
import { MyShort } from './MyShort';
import { AssetDetail } from './AssetDetail';
import { Modal } from './Modal';
import { ArchiveDialog, type ArchiveAction } from './ArchiveDialog';
import { FolderUploader } from './FolderUploader';
import { CloudFolders } from './CloudFolders';
import { CloudApp } from './CloudApp';
import './styles.css';

declare global { interface Window { photoHub?: { chooseDirectory: () => Promise<string | null>; chooseVideo: () => Promise<string | null> } } }

interface Status { mode: string; localDirectory: string; localCount: number; remoteCount: number; assetCount: number; normalCount: number; archiveCount: number; byteSize: number; formats: string[]; }

function AssetCard({ asset, onOpen, selecting, selected, onSelect }: { asset: Asset; onOpen: () => void; selecting: boolean; selected: boolean; onSelect: () => void }) {
  const thumbnail = asset.files.find(f => f.role === 'thumbnail' && f.state === 'ready');
  const original = asset.files.find(f => f.role === 'original');
  const small = !!original?.width && !!original?.height && Math.max(original.width, original.height) <= 128;
  const tilePreview = small && asset.storageLocation === 'local' && original?.mimeType.startsWith('image/') && original.mimeType !== 'image/heic' && original?.state === 'ready' ? original : thumbnail;
  const [broken, setBroken] = useState(false);
  const [imageLoaded, setImageLoaded] = useState(false);
  const [showLocation, setShowLocation] = useState(false);
  const locationName = asset.storageLocation === 'local' ? 'ローカル' : '開発用リモート';
  const connection = !original || original.state !== 'ready' || broken ? 'error' : tilePreview && !imageLoaded ? 'connecting' : 'ready';
  const locationInfo = `${locationName}：${connection === 'error' ? original?.error || (broken ? 'プレビューの取得に失敗しました' : '原本を確認できません') : connection === 'connecting' ? 'プレビュー読み込み中' : '原本確認済み'}${asset.storageLocation === 'local' ? '' : '（保存先はこのPC内）'}`;

  return <div className="asset-tile">{selecting ? <input className="tile-selection" type="checkbox" aria-label={`${asset.name}を選択`} checked={selected} onChange={onSelect} /> : null}<button className={selected ? "asset-card selected" : "asset-card"} onClick={onOpen} aria-label={`${asset.name}の詳細を開く`}>
    <div className={small ? "card-image small-material checkerboard" : "card-image"}>
      {tilePreview && !broken ? <img style={small ? {width: original?.width ?? undefined, height: original?.height ?? undefined} : undefined} src={fileUrl(asset, tilePreview)} alt="" loading="lazy" onLoad={() => setImageLoaded(true)} onError={() => setBroken(true)} /> : <div className="card-placeholder"><ImageIcon size={30} /><span>プレビューなし</span></div>}
      <span className="format-label">{original?.mimeType.replace('image/', '').toUpperCase()}</span>
      {asset.favorite ? <span className="card-heart"><Heart size={16} fill="currentColor" /></span> : null}
      {asset.archivedAt ? <span className="card-archive"><Archive size={12} />アーカイブ</span> : null}
      {small ? <span className="dimension-label">{original?.width}×{original?.height}</span> : null}
      <div className="card-caption"><h3 title={asset.name}>{asset.name}</h3></div>
    </div>
  </button><button className={`card-location ${connection}`} title={locationInfo} aria-label={locationInfo} aria-expanded={showLocation} onClick={() => setShowLocation(value => !value)}>{asset.storageLocation === 'local' ? <Monitor size={13} /> : <Cloud size={13} />}<span className="connection-lamp" aria-hidden="true" /></button>{showLocation ? <div className="location-tooltip" role="status">{locationInfo}</div> : null}</div>;
}

export default function App() { return <CloudApp />; }

export function LegacyApp() {
  const [view, setView] = useState('all');
  const [archiveScope, setArchiveScope] = useState('normal');
  const [location, setLocation] = useState('all');
  const [archiveAction, setArchiveAction] = useState<ArchiveAction | null>(null);
  const [message, setMessage] = useState('');
  const [collection, setCollection] = useState('');
  const [collections, setCollections] = useState<Collection[]>([]);
  const [tags, setTags] = useState<Tag[]>([]);
  const [status, setStatus] = useState<Status | null>(null);
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');
  const [kind, setKind] = useState('');
  const [sort, setSort] = useState('added');
  const [order, setOrder] = useState('desc');
  const [tagFilter, setTagFilter] = useState<string[]>([]);
  const [extensionFilter, setExtensionFilter] = useState<string[]>([]);
  const [extensions, setExtensions] = useState<string[]>([]);
  function toggleFilter(value: string, selected: string[], update: (values: string[]) => void) { update(selected.includes(value) ? selected.filter(v => v !== value) : [...selected, value]); }

  const [page, setPage] = useState<AssetPage>({ items: [], total: 0, nextCursor: null });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [revision, setRevision] = useState(0);
  const [selecting, setSelecting] = useState(false);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [listDialog, setListDialog] = useState<'settings' | null>(null);
  const [bulkEntity, setBulkEntity] = useState<'tags' | 'collections' | null>(null);
  const [bulkItemIds, setBulkItemIds] = useState<string[]>([]);
  const [bulkMode, setBulkMode] = useState('add');
  const [bulkBusy, setBulkBusy] = useState(false);
  const selectedAssets = page.items.filter(a => selectedIds.includes(a.id));
  const selectionEntries = selectedAssets.map(a => ({id: a.id, revision: a.revision}));
  function selectAsset(id: string) { setSelectedIds(previous => previous.includes(id) ? previous.filter(i => i !== id) : previous.length < 100 ? [...previous, id] : previous); }
  async function downloadSelection() {
    setBulkBusy(true);
    await run(async () => {
      const response = await fetch('/api/v1/bulk-download', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({assets: selectionEntries} satisfies BulkDownloadRequest)});
      if (!response.ok) { const problem = await response.json(); throw new Error(problem.message); }
      const url = URL.createObjectURL(await response.blob());
      const anchor = document.createElement('a'); anchor.href = url; anchor.download = 'assets.zip'; document.body.appendChild(anchor); anchor.click(); anchor.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
    });
    setBulkBusy(false);
  }
  const [myShort, setMyShort] = useState(false);
  const [detail, setDetail] = useState<Asset | null>(null);
  const [uploading, setUploading] = useState(false);
  const [job, setJob] = useState<ImportJob | null>(null);
  const [importJobs, setImportJobs] = useState<ImportJob[]>([]);
  const [dragging, setDragging] = useState(false);
  const [sidebar, setSidebar] = useState(false);
  const [settings, setSettings] = useState(false);
  const [settingsPage, setSettingsPage] = useState<'sync' | 'storage' | 'tools' | 'backup' | 'cloud' | 'cloud-library' | null>(null);
  const [storageRoots, setStorageRoots] = useState<StorageRoot[]>([]);
  const [syncRootId, setSyncRootId] = useState('');
  const [syncPath, setSyncPath] = useState('');
  const [syncResult, setSyncResult] = useState<SyncDirectoryResult | null>(null);
  const [collectionDialog, setCollectionDialog] = useState<'create' | 'manage' | null>(null);
  const [collectionName, setCollectionName] = useState('');
  const input = useRef<HTMLInputElement>(null);
  const requestVersion = useRef(0);
  const settingsHeading = useRef<HTMLHeadingElement>(null);
  useEffect(() => { if (settingsPage) settingsHeading.current?.focus(); }, [settingsPage]);

  useEffect(() => { const timer = setTimeout(() => setQuery(search), 250); return () => clearTimeout(timer); }, [search]);
  const activeQuery = view === 'search' || view === 'archive' ? query : '';
  const listParams = new URLSearchParams({ q: activeQuery, view: view === 'search' ? 'all' : view, archive: location === 'local' ? 'normal' : archiveScope, location, collection, kind, sort, order, limit: '60' });
  tagFilter.forEach(id => listParams.append('tag', id));
  extensionFilter.forEach(ext => listParams.append('extension', ext));
  const params = listParams.toString();
  useEffect(() => { setSelectedIds([]); setBulkEntity(null); }, [params]);

  useEffect(() => {
    const abort = new AbortController();
    requestVersion.current++;
    setLoading(true); setPage({items:[],total:0,nextCursor:null}); setError('');
    api<AssetPage>(`/assets?${params}`, 'GET', undefined, abort.signal).then(setPage).catch(e => { if (e.name !== 'AbortError') setError(e.message); }).finally(() => { if (!abort.signal.aborted) setLoading(false); });
    return () => abort.abort();
  }, [params, revision]);
  useEffect(() => {
    const abort = new AbortController();
    Promise.all([api<Collection[]>('/collections', 'GET', undefined, abort.signal), api<Tag[]>('/tags', 'GET', undefined, abort.signal), api<Status>('/status', 'GET', undefined, abort.signal)]).then(([c, t, s]) => { setCollections(c); setTags(t); setStatus(s); }).catch(e => { if (e.name !== 'AbortError') setError(e.message); });
    api<StorageRoot[]>('/storage-roots', 'GET', undefined, abort.signal).then(setStorageRoots).catch(e => { if (e.name !== 'AbortError') setError(e.message); });
    api<{extensions: string[]}>('/filter-options', 'GET', undefined, abort.signal).then(result => setExtensions(result.extensions)).catch(e => { if (e.name !== 'AbortError') setError(e.message); });
    return () => abort.abort();
  }, [revision]);

  useEffect(() => { if (settingsPage === 'sync') api<StorageRoot[]>('/storage-roots').then(setStorageRoots).catch(e => setError(e.message)); }, [settingsPage, revision]);

  function refresh() { setRevision(r => r + 1); }
  function navigate(next: string, id = '') { setMyShort(false); setSettingsPage(null); setView(next); setCollection(id); setArchiveScope('normal'); setSearch(''); setQuery(''); setMessage(''); setSidebar(false); }
  async function run(work: () => Promise<void>) { setError(''); try { await work(); } catch (e) { setError(e instanceof Error ? e.message : '処理に失敗しました。'); } }
  async function open(asset: Asset) { await run(async () => setDetail(await api<Asset>(`/assets/${asset.id}`))); }
  async function upload(files: FileList | File[]) {
    if (uploading || !files.length) return;
    setUploading(true); setError(''); setJob(null); setImportJobs([]);
    try {
      // One bounded request per file exposes progress and preserves partial success.
      const jobs: ImportJob[] = [];
      for (const file of Array.from(files)) {
        const form = new FormData(); form.append('files', file);
        const result = await api<ImportJob>('/imports', 'POST', form);
        jobs.push(result);
        setImportJobs([...jobs]);
        setJob({ id: result.id, items: jobs.flatMap(j => j.items) });
        refresh();
      }
    } catch (e) { setError(e instanceof Error ? e.message : '追加に失敗しました。'); }
    finally { setUploading(false); if (input.current) input.current.value = ''; }
  }
  async function fixtures() {
    setUploading(true);
    await run(async () => { const result = await api<ImportJob>('/fixture-imports', 'POST', {}); setJob(result); setImportJobs([result]); refresh(); });
    setUploading(false);
  }
  async function syncDirectory() {
    setUploading(true); setSyncResult(null);
    await run(async () => { const result = await api<SyncDirectoryResult>('/sync-directory', 'POST', {path: syncPath, rootId: syncRootId || null} satisfies SyncDirectoryRequest); setSyncResult(result); setSyncRootId(result.rootId); refresh(); });
    setUploading(false);
  }
  async function chooseSyncDirectory() { await run(async () => { const path = await window.photoHub?.chooseDirectory(); if (path) setSyncPath(path); }); }
  async function scanLocal() {
    setUploading(true);
    await run(async () => { const result = await api<ImportJob>('/import-local-directory', 'POST', {}); setJob(result); setImportJobs([result]); setMessage(result.items.length ? 'ローカルフォルダを読み込みました。' : '新しい画像はありません。登録済みファイルの変更は詳細で確認できます。'); refresh(); });
    setUploading(false);
  }
  async function more() {
    if (!page.nextCursor || loading) return;
    const current = requestVersion.current;
    setLoading(true);
    await run(async () => {
      const next = await api<AssetPage>(`/assets?${params}&cursor=${encodeURIComponent(page.nextCursor!)}`);
      if (requestVersion.current === current) setPage(previous => ({ ...next, items: [...previous.items, ...next.items] }));
    });
    if (requestVersion.current === current) setLoading(false);
  }
  const currentCollection = collections.find(c => c.id === collection);
  async function retryImports() {
    setUploading(true);
    await run(async () => {
      const results = [];
      for (const previous of importJobs) results.push(previous.items.some(i => i.code === 'storage_error') ? await api<ImportJob>(`/imports/${previous.id}/retry`, 'POST', {}) : previous);
      setImportJobs(results); setJob({id:results[0]?.id ?? '',items:results.flatMap(j => j.items)}); refresh();
    });
    setUploading(false);
  }
  return <div className="app-shell" onDragOver={e => { e.preventDefault(); if (e.dataTransfer.types.includes('Files')) setDragging(true); }} onDragLeave={e => { if (!e.relatedTarget) setDragging(false); }} onDrop={e => { e.preventDefault(); setDragging(false); upload(e.dataTransfer.files); }}>
    <aside className={sidebar ? 'sidebar open' : 'sidebar'}>
      <a className="brand" href="#" onClick={e => { e.preventDefault(); navigate('all'); }}><span className="brand-icon"><Library size={23} /></span><span>Asset Library<small>PERSONAL COLLECTION</small></span></a>
      <div className="storage-switch" role="group" aria-label="保管場所を切り替え">
        <button aria-pressed={location === 'all'} onClick={() => setLocation('all')}>すべて</button>
        <button aria-pressed={location === 'local'} onClick={() => { setLocation('local'); setArchiveScope('normal'); if (view === 'archive') navigate('all'); }}><Monitor size={14} />ローカル</button>
        <button aria-pressed={location === 'development-remote'} title="現在はこのPC内の開発用リモート" onClick={() => setLocation('development-remote')}><Cloud size={14} />リモート</button>
      </div>
      <span className="nav-label">ライブラリ</span>
      <button className="nav-item sidebar-add" disabled={uploading} onClick={() => { input.current?.click(); setSidebar(false); }}><Plus size={18} />{uploading ? '追加中…' : '素材を追加'}</button>
      <button className={!settingsPage && !myShort && view === 'search' ? 'nav-item active' : 'nav-item'} onClick={() => navigate('search')}><Search size={18} />検索</button>
      <button className={settingsPage === 'cloud-library' ? 'nav-item active' : 'nav-item'} onClick={() => { setMyShort(false); setSettingsPage('cloud-library'); setSidebar(false); }}><Cloud size={18} />S3フォルダ</button><nav aria-label="ライブラリ"><button className={myShort ? 'nav-item active' : 'nav-item'} onClick={() => { setMyShort(true); setSettingsPage(null); setSidebar(false); }}><ImageIcon size={18} />マイショート</button><button className={!settingsPage && !myShort && view === 'all' && !collection ? 'nav-item active' : 'nav-item'} onClick={() => navigate('all')}><Library size={18} />通常の素材<span>{status?.normalCount ?? '—'}</span></button><button className={!settingsPage && !myShort && view === 'favorites' ? 'nav-item active' : 'nav-item'} onClick={() => navigate('favorites')}><Heart size={18} />お気に入り</button>{location !== 'local' ? <button className={!settingsPage && !myShort && view === 'archive' ? 'nav-item active' : 'nav-item'} onClick={() => navigate('archive')}><Archive size={18} />アーカイブ<span>{status?.archiveCount ?? '—'}</span></button> : null}</nav>
      <div className="nav-label collection-heading"><span>コレクション</span><button className="icon-button" aria-label="コレクションを作成" onClick={() => { setCollectionName(''); setCollectionDialog('create'); }}><Plus size={16} /></button></div>
      <nav aria-label="コレクション">{collections.map(c => <button key={c.id} className={collection === c.id && !myShort ? 'nav-item active' : 'nav-item'} onClick={() => navigate('all', c.id)}><Folder size={18} /><span className="collection-title">{c.name}</span></button>)}{!collections.length ? <p className="nav-empty">用途やプロジェクトごとに<br />素材をまとめられます。</p> : null}</nav>
      <div className="sidebar-bottom"><button className={view === 'trash' ? 'nav-item active' : 'nav-item'} onClick={() => navigate('trash')}><Trash2 size={18} />ごみ箱</button><button className="nav-item" onClick={() => { setSettingsPage(null); setSettings(true); setSidebar(false); }}><Settings size={18} />設定</button><div className="storage-note"><span className="status-dot" /><span>ローカルライブラリ<small>{bytes(status?.byteSize ?? 0)} 使用中</small></span></div></div>
    </aside>
    {sidebar ? <button className="sidebar-shade" aria-label="ナビゲーションを閉じる" onClick={() => setSidebar(false)} /> : null}
    <main>
      <header className="topbar"><button className="icon-button mobile-menu" aria-label="ナビゲーションを開く" onClick={() => setSidebar(!sidebar)}><Menu /></button></header>
        <input ref={input} type="file" accept=".jpg,.jpeg,.png,.webp,.heic,.heif,.mp4,.mov,.webm,.mkv,.avi,.m4v" multiple hidden onChange={e => e.target.files && upload(e.target.files)} />
      {myShort ? <MyShort location={location} tags={tags} collections={collections} paused={!!detail || settings || !!collectionDialog || !!archiveAction || !!listDialog || !!bulkEntity} onDetail={open} onChanged={refresh} /> : settingsPage === 'cloud-library' ? <CloudFolders /> : settingsPage ? <section className="settings-page" aria-label="設定の詳細"><button className="text-button" onClick={() => { setSettingsPage(null); setSettings(true); }}>← 設定に戻る</button><header className="settings-page-heading"><h1 ref={settingsHeading} tabIndex={-1}>{{'cloud-library': 'S3フォルダ', cloud: 'S3フォルダアップロード', sync: 'フォルダ同期', storage: '保管場所と使用量', tools: 'テスト用素材', backup: 'バックアップ'}[settingsPage]}</h1></header><div className="settings-body">{settingsPage === 'cloud' ? <FolderUploader onOpenLibrary={() => setSettingsPage('cloud-library')} /> : null}{settingsPage === 'sync' ? <><p>Finder／Explorerで画像を配置し、フォルダを指定して同期します。原本はコピーせず参照します。</p><label>登録先<select disabled={uploading} value={syncRootId} onChange={e => { const id = e.target.value; setSyncRootId(id); setSyncPath(storageRoots.find(r => r.id === id)?.path ?? ''); setSyncResult(null); }}><option value="">新しいフォルダ</option>{storageRoots.map(root => <option key={root.id} value={root.id}>{root.state === 'missing' ? '見つかりません：' : ''}{root.path}</option>)}</select></label><label>同期フォルダのパス<input disabled={uploading} value={syncPath} onChange={e => setSyncPath(e.target.value)} placeholder="画像フォルダの絶対パス" /></label>{window.photoHub ? <button className="secondary" disabled={uploading} onClick={chooseSyncDirectory}>フォルダを選ぶ</button> : null}<button className="primary" disabled={uploading || !syncPath.trim()} onClick={syncDirectory}>{uploading ? '同期中…' : '同期する'}</button><p className="muted">フォルダを移動した場合は、登録先を選び、新しいパスを指定して同期してください。同じ内容は固定IDを引き継ぎます。内容が変わった画像は変更として通知します。</p>{storageRoots.filter(root => root.state === 'missing').map(root => <p role="alert" className="error" key={root.id}>フォルダが見つかりません：{root.path}</p>)}{syncResult ? <p role="status">新規 {syncResult.added}／一致 {syncResult.matched}／移動 {syncResult.moved}／変更 {syncResult.changed}／欠損 {syncResult.missing}／失敗 {syncResult.failed}{syncResult.limited ? '。新規登録の上限100件に達しました。もう一度同期してください。' : ''}</p> : null}{error ? <p role="alert" className="error">{error}</p> : null}</> : null}{settingsPage === 'storage' ? <><p>既存素材は開発用リモート、新しく追加する素材はローカルとして表示します。開発用リモートの実体もこのPC内にあり、AWS・端末間共有は未接続です。</p><dl><dt>ローカル</dt><dd>{status?.localCount ?? 0} 点</dd><dt>開発用リモート</dt><dd>{status?.remoteCount ?? 0} 点</dd></dl><h3>アプリ管理のローカル画像フォルダ</h3><p>このフォルダへ画像を置いて読み込めます（1回につき新規100件まで）。フォルダから読み込んだ原本はコピーせず参照し、素材情報とプレビューだけ登録します。</p><code className="storage-path">{status?.localDirectory}</code><button className="secondary" disabled={uploading} onClick={scanLocal}>{uploading ? '読み込み中…' : 'ローカルフォルダを読み込む'}</button><p className="muted">ファイル選択・ドラッグで追加した画像はこのフォルダへコピーします。参照ファイルの移動・編集は欠損／変更として表示します。自動追跡は後工程です。</p><dl><dt>素材数</dt><dd>{status?.assetCount ?? 0} 点</dd><dt>通常</dt><dd>{status?.normalCount ?? 0} 点</dd><dt>アーカイブ</dt><dd>{status?.archiveCount ?? 0} 点</dd><dt>使用量</dt><dd>{bytes(status?.byteSize ?? 0)}</dd></dl><h3>アーカイブ</h3><p>リモート素材を通常とアーカイブに分けて管理できます。開発用リモートでは、アーカイブしても使用容量は変わりません。</p></> : null}{settingsPage === 'tools' ? <><p>設定済みテストフォルダの画像をコピーして追加します。登録済みの画像は重複しません。</p><button className="secondary" disabled={uploading} onClick={fixtures}>{uploading ? '追加中…' : 'テスト素材を取り込む'}</button></> : null}{settingsPage === 'backup' ? <><p>アプリの保存処理を止めてから、APIを停止し、データフォルダ全体を退避してください。参照登録した外部フォルダも併せて退避してください。素材情報だけでは原本を復元できません。</p><p className="muted">クラウド保存・端末間同期は未接続です。</p></> : null}</div></section> : <div className="workspace">
        <div className={view === 'search' || view === 'archive' ? 'toolbar search-page-toolbar' : 'toolbar library-toolbar'}>{view === 'search' || view === 'archive' ? <label className="search"><Search size={18} /><input autoFocus placeholder={view === 'archive' ? 'アーカイブ内を検索' : '素材名・タグ・メモで検索'} aria-label="素材を検索" value={search} onChange={e => setSearch(e.target.value)} />{search ? <button className="icon-button" aria-label="検索をクリア" onClick={() => setSearch('')}><X size={16} /></button> : null}</label> : null}<div className="list-controls">{location !== 'local' && (view === 'search' || view === 'favorites' || collection) ? <label className="archive-scope">保管状態<select aria-label="保管状態" value={archiveScope} onChange={e => setArchiveScope(e.target.value)}><option value="normal">通常</option><option value="archived">アーカイブ</option><option value="all">両方</option></select></label> : null}{view !== 'trash' ? <button className="secondary" onClick={() => { setSelecting(!selecting); setSelectedIds([]); }}>{selecting ? '選択を終了' : '複数選択'}</button> : null}<button className="secondary list-settings-trigger" aria-label="フィルターと並び替え" title="フィルターと並び替え" onClick={() => setListDialog('settings')}><SlidersHorizontal size={18} />{kind || tagFilter.length || extensionFilter.length ? <span className="filter-count">{(kind ? 1 : 0) + tagFilter.length + extensionFilter.length}</span> : null}</button></div></div>
        {selecting && view !== 'trash' ? <div className="selection-bar" aria-label="一括操作"><strong>{selectedAssets.length} 点選択</strong><button className="text-button" disabled={bulkBusy} onClick={() => setSelectedIds(page.items.slice(0,100).map(a => a.id))}>表示中を選択（最大100点）</button><button className="text-button" disabled={bulkBusy} onClick={() => setSelectedIds([])}>選択解除</button><button className="secondary" disabled={!selectedAssets.length || bulkBusy} onClick={downloadSelection}><Download size={14} />ZIPでダウンロード</button>{location !== 'local' ? <><button className="secondary" disabled={bulkBusy || !selectedAssets.some(a => a.storageLocation !== 'local' && !a.archivedAt)} onClick={() => setArchiveAction({archived: true, target: {assets: selectedAssets.filter(a => a.storageLocation !== 'local' && !a.archivedAt).map(a => ({id: a.id, revision: a.revision}))}})}><Archive size={14} />アーカイブする</button><button className="secondary" disabled={bulkBusy || !selectedAssets.some(a => a.archivedAt)} onClick={() => setArchiveAction({archived: false, target: {assets: selectedAssets.filter(a => a.archivedAt).map(a => ({id: a.id, revision: a.revision}))}})}>通常に戻す</button></> : null}{(['tags', 'collections'] as const).map(entity => <button className="secondary" key={entity} disabled={!selectedAssets.length || bulkBusy} onClick={() => { setBulkEntity(entity); setBulkItemIds([]); setBulkMode('add'); }}>{entity === 'tags' ? 'タグを設定' : 'コレクションに登録'}</button>)}</div> : null}
        {currentCollection ? <div className="collection-tools"><button className="text-button" onClick={() => { setCollectionName(currentCollection.name); setCollectionDialog('manage'); }}>コレクションを編集</button>{location !== 'local' ? <><button className="secondary" disabled={bulkBusy} onClick={() => setArchiveAction({archived: true, target: {collection: currentCollection}})}><Archive size={14} />リモートをアーカイブ</button><button className="secondary" disabled={bulkBusy} onClick={() => setArchiveAction({archived: false, target: {collection: currentCollection}})}>リモートを通常に戻す</button></> : null}</div> : null}
        {view === 'archive' ? <p className="archive-notice">アーカイブした素材です。原本の取得や編集はそのまま利用できます。</p> : null}
        {message ? <div className="archive-result" role="status">{message}<button className="icon-button" aria-label="操作結果を閉じる" onClick={() => setMessage('')}><X size={14} /></button></div> : null}
        {error ? <div className="error-box" role="alert"><AlertCircle size={18} /><span>{error}</span><button onClick={refresh}>再読み込み</button></div> : null}
        {job ? <section className="import-results" aria-label="追加結果" aria-live="polite"><div><Check size={17} /><strong>{job.items.filter(i => i.state === 'ready').length} 点追加</strong><span>{job.items.filter(i => i.state === 'duplicate').length} 点登録済み</span><span>{job.items.filter(i => i.state === 'failed').length} 点失敗</span><button className="icon-button" aria-label="追加結果を閉じる" onClick={() => setJob(null)}><X size={16} /></button></div>{job.items.filter(i => i.state !== 'ready').map(item => <p key={item.id}>{item.filename}：{item.message}{item.assetId ? <button className="text-button" onClick={() => run(async () => setDetail(await api<Asset>(`/assets/${item.assetId}`)))}>素材を開く</button> : null}</p>)}{job.items.some(i => i.code === 'storage_error') ? <button className="secondary" disabled={uploading} onClick={retryImports}>保存失敗を再試行</button> : null}</section> : null}
        {loading && !page.items.length ? <div className="empty"><span className="spinner" /><p>素材を読み込んでいます…</p></div> : !page.items.length ? <section className="empty"><div className="empty-icon"><ImageIcon size={36} /></div><h2>{activeQuery || kind || collection || tagFilter.length || extensionFilter.length ? '一致する素材がありません' : view === 'trash' ? 'ごみ箱は空です' : view === 'favorites' ? 'この保管状態のお気に入りはありません' : view === 'archive' ? 'アーカイブは空です' : '通常の素材がありません'}</h2><p>{view === 'all' && !collection && !activeQuery && !kind && !tagFilter.length && !extensionFilter.length ? location !== 'local' && status?.archiveCount ? 'アーカイブから通常に戻すか、新しい素材を追加できます。' : '写真や画像をドラッグ＆ドロップして、ライブラリに保管できます。' : 'S3へアップロードした素材は、左メニューの「S3フォルダ」から表示できます。その他の素材は検索条件を変えて探してください。'}</p><button className="secondary" onClick={() => setSettingsPage('cloud-library')}>S3フォルダを開く</button></section> : <><div className="asset-grid" aria-label="素材一覧">{page.items.map(asset => <AssetCard key={`${asset.id}-${asset.revision}`} asset={asset} selecting={selecting && view !== 'trash'} selected={selectedIds.includes(asset.id)} onSelect={() => selectAsset(asset.id)} onOpen={() => selecting && view !== 'trash' ? selectAsset(asset.id) : open(asset)} />)}</div><footer className="list-footer"><span>{page.items.length} / {page.total} 点を表示</span>{page.nextCursor ? <button className="secondary" disabled={loading} onClick={more}>{loading ? '読み込み中…' : 'さらに表示'}</button> : <span>すべて表示しました</span>}</footer></>}
        <p className="drop-hint">JPEG / PNG / WebP / HEIC / MP4 / MOV / WebM / MKV / AVI / M4V<span>·</span>原本をそのまま保管</p>
      </div>}
    </main>
    {dragging ? <div className="drop-overlay"><Upload size={40} /><h2>ここにドロップして追加</h2><p>元のファイルはそのまま残ります</p></div> : null}
    {detail ? <AssetDetail key={detail.id} asset={detail} tags={tags} collections={collections} onClose={() => setDetail(null)} onChanged={() => refresh()} onTagCreated={tag => setTags(previous => previous.some(t => t.id === tag.id) ? previous : [...previous, tag])} /> : null}
    {archiveAction ? <ArchiveDialog action={archiveAction} onReload={() => { setSelectedIds([]); refresh(); }} onClose={() => setArchiveAction(null)} onChanged={result => { setMessage(result); setSelectedIds([]); refresh(); }} /> : null}
    {listDialog ? <Modal title="フィルターと並び替え" onClose={() => setListDialog(null)}><div className="list-settings">
      <section className="list-setting-section"><h3>フィルター</h3><label>種別<select aria-label="素材の種別" value={kind} onChange={e => setKind(e.target.value)}><option value="">すべての種別</option><option value="image">画像</option><option value="photo">写真</option><option value="video">動画</option></select></label><fieldset><legend>タグ（選択したタグすべてに一致）</legend><div className="filter-checks">{tags.map(tag => <label key={tag.id}><input type="checkbox" checked={tagFilter.includes(tag.id)} onChange={() => toggleFilter(tag.id, tagFilter, setTagFilter)} />{tag.name}</label>)}</div>{!tags.length ? <p className="muted">タグがありません</p> : null}</fieldset><fieldset><legend>拡張子（選択したいずれかに一致）</legend><div className="filter-checks">{extensions.map(ext => <label key={ext}><input type="checkbox" checked={extensionFilter.includes(ext)} onChange={() => toggleFilter(ext, extensionFilter, setExtensionFilter)} />.{ext}</label>)}</div></fieldset></section><section className="list-setting-section"><h3>並び替え</h3><label>並び替え項目<select aria-label="並び替え項目" value={sort} onChange={e => setSort(e.target.value)}><option value="added">追加日</option><option value="captured">撮影日</option><option value="updated">更新日</option><option value="name">タイトル</option><option value="size">原本サイズ</option></select></label><label>並び順<select aria-label="並び順" value={order} onChange={e => setOrder(e.target.value)}><option value="desc">降順</option><option value="asc">昇順</option></select></label></section>
      <div className="list-settings-actions"><button className="secondary" onClick={() => { setKind(''); setTagFilter([]); setExtensionFilter([]); }}>条件を解除</button><button className="primary" onClick={() => setListDialog(null)}>完了</button></div>
    </div></Modal> : null}
    {bulkEntity ? <Modal title={bulkEntity === 'tags' ? 'タグを一括設定' : 'コレクションを一括設定'} onClose={() => !bulkBusy && setBulkEntity(null)}><form className="settings-body" onSubmit={e => { e.preventDefault(); setBulkBusy(true); run(async () => { await api<BulkOrganizeResult>('/bulk-organize', 'POST', {assets: selectionEntries, entity: bulkEntity, itemIds: bulkItemIds, mode: bulkMode} satisfies BulkOrganizeRequest); setBulkEntity(null); setSelectedIds([]); refresh(); }).finally(() => setBulkBusy(false)); }}><p>{selectedAssets.length} 点の素材に設定</p>{error ? <div role="alert" className="error-box">{error}</div> : null}<label>設定方法<select value={bulkMode} onChange={e => setBulkMode(e.target.value)}><option value="add">現在の設定に追加</option><option value="replace">選択した設定に置き換え</option></select></label>{bulkMode === 'replace' ? <p>既存の{bulkEntity === 'tags' ? 'タグ' : 'コレクション所属'}を選択内容に置き換えます。未選択ならすべて解除します。</p> : null}<fieldset disabled={bulkBusy}>{(bulkEntity === 'tags' ? tags : collections).map(item => <label className="collection-check" key={item.id}><input type="checkbox" checked={bulkItemIds.includes(item.id)} onChange={() => toggleFilter(item.id, bulkItemIds, setBulkItemIds)} />{item.name}</label>)}</fieldset><button className="primary" disabled={bulkBusy || (bulkMode === 'add' && !bulkItemIds.length)}>{bulkBusy ? '設定中…' : '設定を保存'}</button></form></Modal> : null}
    {settings ? <Modal title="設定" onClose={() => setSettings(false)}><nav className="settings-links" aria-label="設定項目"><a href="#settings/cloud" onClick={e => { e.preventDefault(); setSettings(false); setMyShort(false); setSettingsPage('cloud'); }}><span><strong>S3フォルダアップロード</strong><small>フォルダ階層を保って手動で送信する</small></span><ArrowUpRight size={18} /></a><a href="#settings/sync" onClick={e => { e.preventDefault(); setSettings(false); setMyShort(false); setSettingsPage('sync'); }}><span><strong>フォルダ同期</strong><small>Finder／Explorerの画像を読み込む</small></span><ArrowUpRight size={18} /></a><a href="#settings/storage" onClick={e => { e.preventDefault(); setSettings(false); setMyShort(false); setSettingsPage('storage'); }}><span><strong>保管場所と使用量</strong><small>ローカル画像フォルダ・容量を確認する</small></span><ArrowUpRight size={18} /></a><a href="#settings/backup" onClick={e => { e.preventDefault(); setSettings(false); setMyShort(false); setSettingsPage('backup'); }}><span><strong>バックアップ</strong><small>原本と素材情報の退避方法</small></span><ArrowUpRight size={18} /></a><a href="#settings/tools" onClick={e => { e.preventDefault(); setSettings(false); setMyShort(false); setSettingsPage('tools'); }}><span><strong>テスト用素材</strong><small>開発確認用の素材を追加する</small></span><ArrowUpRight size={18} /></a></nav></Modal> : null}
    {collectionDialog ? <Modal title={collectionDialog === 'create' ? 'コレクションを作成' : 'コレクションを編集'} onClose={() => setCollectionDialog(null)}><form className="settings-body" onSubmit={e => { e.preventDefault(); run(async () => { const item = await api<Collection>(collectionDialog === 'create' ? '/collections' : `/collections/${collection}`, collectionDialog === 'create' ? 'POST' : 'PATCH', { name: collectionName }); refresh(); navigate('all', item.id); setCollectionDialog(null); }); }}>{error ? <div className="error-box" role="alert">{error}</div> : null}<label>名前<input autoFocus required maxLength={100} value={collectionName} onChange={e => setCollectionName(e.target.value)} placeholder="例：部屋づくりの参考" /></label><button className="primary">保存</button>{collectionDialog === 'manage' ? <button type="button" className="danger" onClick={() => { if (window.confirm('コレクションを削除しますか？ 素材はライブラリに残ります。')) run(async () => { await api(`/collections/${collection}`, 'DELETE', {}); navigate('all'); refresh(); setCollectionDialog(null); }); }}>コレクションを削除</button> : null}</form></Modal> : null}
  </div>;
}
