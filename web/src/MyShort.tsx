import { useEffect, useRef, useState } from 'react';
import type { Asset, AssetPage, Collection, Tag } from './generated/contracts';
import { api, fileUrl } from './api';

function ShortMedia({ asset, paused }: { asset: Asset; paused: boolean }) {
  const file = asset.files.find(f => f.role === 'display' && f.state === 'ready');
  const video = useRef<HTMLVideoElement>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    const element = video.current;
    function sync() {
      if (!element) return;
      if (paused || document.hidden) element.pause();
      else element.play().catch(() => { setLoading(false); });
    }
    sync();
    document.addEventListener('visibilitychange', sync);
    return () => { element?.pause(); document.removeEventListener('visibilitychange', sync); };
  }, [paused, retry, error]);
  if (!file || error) return <div role="status" className="short-placeholder"><p>{error || asset.files.find(f => f.role === 'display')?.error || 'プレビューを表示できません。'}</p><p>詳細から原本を取得できます。</p>{file ? <button className="secondary" onClick={() => { setError(''); setLoading(true); setRetry(r => r + 1); }}>表示を再試行</button> : null}</div>;
  return <>{loading ? <span role="status" className="short-loading">読み込み中…</span> : null}{file.mimeType.startsWith('video/') ? <video key={retry} ref={video} src={fileUrl(asset, file)} muted controls playsInline loop preload="metadata" onLoadedData={() => setLoading(false)} onError={() => setError('動画を再生できません。')} /> : <img key={retry} src={fileUrl(asset, file)} alt={asset.name} onLoad={() => setLoading(false)} onError={() => setError('画像を表示できません。')} />}</>;
}

export function MyShort({ location, tags, collections, paused, onDetail, onChanged }: { location: string; tags: Tag[]; collections: Collection[]; paused: boolean; onDetail: (asset: Asset) => void; onChanged: () => void }) {
  const [seed, setSeed] = useState(() => crypto.randomUUID());
  const [tag, setTag] = useState('');
  const [collection, setCollection] = useState('');
  const [items, setItems] = useState<Asset[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [index, setIndex] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const wheelEnd = useRef(0);
  const wheelLocked = useRef(false);
  const touch = useRef<{ x: number; y: number } | null>(null);
  const moving = useRef(false);
  const stage = useRef<HTMLDivElement>(null);
  useEffect(() => { stage.current?.focus(); }, []);
  const generation = useRef(0);
  useEffect(() => {
    const element = stage.current;
    const preventScroll = (event: WheelEvent) => event.preventDefault();
    element?.addEventListener('wheel', preventScroll, { passive: false });
    return () => element?.removeEventListener('wheel', preventScroll);
  }, []);
  const params = new URLSearchParams({ sort: 'random', seed, limit: '20', archive: 'normal', collection, location });
  if (tag) params.append('tag', tag);
  const query = params.toString();
  const asset = items[Math.min(index, items.length - 1)];
  useEffect(() => {
    function key(event: KeyboardEvent) {
      if (paused || event.repeat || (event.target as HTMLElement).closest('input,textarea,select,video,[contenteditable=true]')) return;
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault(); void move(event.key === 'ArrowDown' ? 1 : -1);
      }
    }
    document.addEventListener('keydown', key);
    return () => document.removeEventListener('keydown', key);
  }, [paused, loading, busy, index, items, cursor, query]);
  useEffect(() => {
    generation.current++;
    const abort = new AbortController();
    setLoading(true); setError(''); setItems([]); setIndex(0); setCursor(null);
    api<AssetPage>(`/assets?${query}`, 'GET', undefined, abort.signal).then(page => { setItems(page.items); setCursor(page.nextCursor); }).catch(e => { if (!abort.signal.aborted) setError(e.message); }).finally(() => { if (!abort.signal.aborted) setLoading(false); });
    return () => abort.abort();
  }, [query]);
  useEffect(() => {
    if (paused || !asset) return;
    const abort = new AbortController();
    api<Asset>(`/assets/${asset.id}`, 'GET', undefined, abort.signal).then(fresh => {
      setItems(previous => fresh.trashedAt || fresh.archivedAt || fresh.state === 'deleting' || (tag && !fresh.tags.some(t => t.id === tag)) || (collection && !fresh.collections.some(c => c.id === collection)) ? previous.filter(a => a.id !== fresh.id) : previous.map(a => a.id === fresh.id ? fresh : a));
    }).catch(e => {
      if (!abort.signal.aborted) {
        if (e.code === 'not_found') setItems(previous => previous.filter(a => a.id !== asset.id));
        else setError(e.message);
      }
    });
    return () => abort.abort();
  }, [paused, asset?.id]);
  async function move(direction: number) {
    if (paused || loading || busy || moving.current) return;
    if (direction < 0 || index + 1 < items.length) { setIndex(i => Math.max(0, Math.min(items.length - 1, i + direction))); return; }
    if (!cursor) return;
    moving.current = true;
    const version = generation.current;
    setLoading(true); setError('');
    try {
      const page = await api<AssetPage>(`/assets?${query}&cursor=${encodeURIComponent(cursor)}`);
      if (version !== generation.current) return;
      const fresh = page.items.filter(a => !items.some(existing => existing.id === a.id));
      setItems(previous => [...previous, ...fresh]); setCursor(page.nextCursor);
      if (fresh.length) setIndex(i => i + 1);
    } catch (e) { setError(e instanceof Error ? e.message : '読み込みに失敗しました。'); }
    finally { moving.current = false; if (version === generation.current) setLoading(false); }
  }
  async function update(body: Record<string, unknown>) {
    if (!asset || busy) return;
    setBusy(true); setError('');
    try {
      const updated = await api<Asset>(`/assets/${asset.id}`, 'PATCH', { revision: asset.revision, ...body });
      setItems(previous => previous.map(a => a.id === updated.id ? updated : a)); onChanged();
    } catch (e) { setError(e instanceof Error ? e.message : '更新に失敗しました。'); }
    finally { setBusy(false); }
  }
  return <section className="my-short" aria-label="マイショート">
    <header><h1>マイショート</h1><p>上下スワイプ・ホイール・↑↓で、素材を見つけ直す</p>
      <div className="short-filters"><label>タグ<select value={tag} disabled={loading || busy} onChange={e => setTag(e.target.value)}><option value="">すべて</option>{tags.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select></label><label>コレクション<select value={collection} disabled={loading || busy} onChange={e => setCollection(e.target.value)}><option value="">すべて</option>{collections.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label><button className="secondary" disabled={loading || busy} onClick={() => setSeed(crypto.randomUUID())}>新しい順で見る</button></div>
    </header>
    {error ? <div role="alert" className="error-box">{error}<button className="secondary" onClick={() => asset ? move(1) : setSeed(crypto.randomUUID())}>再試行</button></div> : null}
    <div ref={stage} className="short-stage" tabIndex={0} aria-label="素材ビューアー" onWheel={e => {
      if (Math.abs(e.deltaY) < Math.abs(e.deltaX)) return;
      const time = performance.now();
      if (time - wheelEnd.current > 250) wheelLocked.current = false;
      wheelEnd.current = time;
      if (!wheelLocked.current && Math.abs(e.deltaY) > 8) { wheelLocked.current = true; void move(e.deltaY > 0 ? 1 : -1); }
    }} onTouchStart={e => { if ((e.target as HTMLElement).closest('video') && e.touches[0].clientY > e.currentTarget.getBoundingClientRect().bottom - 60) return; touch.current = { x: e.touches[0].clientX, y: e.touches[0].clientY }; }} onTouchCancel={() => { touch.current = null; }} onTouchEnd={e => {
      const start = touch.current; touch.current = null;
      if (!start) return;
      const dx = e.changedTouches[0].clientX - start.x, dy = e.changedTouches[0].clientY - start.y;
      if (Math.abs(dy) > 60 && Math.abs(dy) > Math.abs(dx)) void move(dy < 0 ? 1 : -1);
    }}>
      {asset ? <ShortMedia key={asset.id} asset={asset} paused={paused} /> : <div role="status">{loading ? '素材を読み込んでいます…' : '対象の素材がありません。素材を追加するか、条件を変えてください。'}</div>}
    </div>
    {asset ? <footer><strong>{asset.name}</strong><span aria-live="polite">{index + 1} 点目</span><div className="short-actions"><button className="secondary" disabled={loading || busy || index === 0} onClick={() => move(-1)}>前へ</button><button className="secondary" disabled={loading || busy || (!cursor && index === items.length - 1)} onClick={() => move(1)}>次へ</button><button className="secondary" disabled={busy} aria-pressed={asset.favorite} onClick={() => update({ favorite: !asset.favorite })}>{asset.favorite ? '♥ お気に入り解除' : '♡ お気に入り'}</button><label>コレクションに追加<select value="" disabled={busy} onChange={e => { if (e.target.value) void update({ collectionIds: [...new Set([...asset.collections.map(c => c.id), e.target.value])] }); }}><option value="">選択</option>{collections.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label><button className="secondary" onClick={() => onDetail(asset)}>素材の詳細</button></div>{!cursor && index === items.length - 1 ? <p>このセッションの最後の素材です。</p> : null}</footer> : null}
  </section>;
}
