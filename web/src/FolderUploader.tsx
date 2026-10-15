import { useEffect, useState } from 'react';
import type { FolderUpload } from './generated/contracts';
import { api, bytes } from './api';
import { FolderOpen, Upload, ShieldCheck, CheckCircle2, ChevronRight, FileImage, Settings2 } from 'lucide-react';

const labels: Record<string, string> = {planned: '送信前', uploading: '送信中', paused: '停止中', interrupted: '中断', failed: '失敗', complete: '保存完了'};

export function FolderUploader({onOpenLibrary, initialPlan}: {onOpenLibrary?: () => void; initialPlan?: FolderUpload}) {
  const [path, setPath] = useState('');
  const [bucket, setBucket] = useState('photo-hub-storage-bucket-ajgsbh5jtcvp');
  const [profile, setProfile] = useState('photo-hub');
  const [region, setRegion] = useState('ap-northeast-1');
  const [plans, setPlans] = useState<FolderUpload[]>([]);
  const [plan, setPlan] = useState<FolderUpload | null>(initialPlan ?? null);
  const [folderId, setFolderId] = useState<string | null>(initialPlan?.folders.find(f => f.parentId === null)?.id ?? null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [confirmed, setConfirmed] = useState(false);
  useEffect(() => {
    const abort = new AbortController();
    api<FolderUpload[]>('/folder-uploads', 'GET', undefined, abort.signal).then(values => { setPlans(values); if (values[0]) { setBucket(values[0].bucket); setProfile(values[0].profile); setRegion(values[0].region); } }).catch(e => { if (e.name !== 'AbortError') setError(e.message); });
    return () => abort.abort();
  }, []);
  useEffect(() => {
    if (plan?.state !== 'uploading') return;
    const abort = new AbortController();
    const timer = setInterval(() => {
      api<FolderUpload>(`/folder-uploads/${plan.id}`, 'GET', undefined, abort.signal).then(value => {
        setPlan(value); setPlans(previous => previous.map(p => p.id === value.id ? value : p));
      }).catch(e => { if (e.name !== 'AbortError') setError(e.message); });
    }, 2000);
    return () => { clearInterval(timer); abort.abort(); };
  }, [plan?.id, plan?.state]);
  async function run(action: () => Promise<void>) {
    setBusy(true); setError('');
    try { await action(); } catch (e) { setError(e instanceof Error ? e.message : '操作に失敗しました。'); }
    finally { setBusy(false); }
  }
  function select(value: FolderUpload) { setPlan(value); setFolderId(null); setConfirmed(false); }
  const mediaLabel = initialPlan ? '軽量版' : '原本';
  const uploading = plan?.state === 'uploading';
  const storageUSD = (plan?.byteSize ?? 0) / 1024 ** 3 * 0.025;
  const storageYen = storageUSD * 150 * 1.1;
  const folder = plan?.folders.find(f => f.id === folderId);
  const children = plan?.folders.filter(f => f.parentId === folderId) ?? [];
  const items = plan?.items.filter(i => i.folderId === folderId) ?? [];
  const size = (value: number) => value >= 1024 ** 3 ? `${(value / 1024 ** 3).toFixed(2)} GiB` : bytes(value);
  const step = !plan ? 1 : plan.state === 'planned' ? 2 : 3;
  const currentName = path.split(/[\\/]/).filter(Boolean).pop();
  const activeStep = plan?.state === 'complete' ? '保存完了' : uploading ? 'アップロード中' : 'アップロード';
  async function inspect() {
    await run(async () => {
      const value = await api<FolderUpload>('/folder-uploads/scan', 'POST', {path, bucket, profile, region});
      select(value); setFolderId(value.folders.find(f => f.parentId === null)?.id ?? null);
      setPlans(previous => [value, ...previous]);
    });
  }
  async function choose() {
    await run(async () => { const value = await window.photoHub!.chooseDirectory(); if (value) { setPath(value); setPlan(null); setConfirmed(false); } });
  }
  function updatePlan(value: FolderUpload) {
    setPlan(value); setPlans(previous => previous.map(p => p.id === value.id ? value : p));
  }
  const trail = [];
  let ancestor = folder;
  while (ancestor) { trail.unshift(ancestor); ancestor = plan?.folders.find(f => f.id === ancestor!.parentId); }
  return <section className="folder-uploader" aria-label="S3フォルダアップロード">
    <p className="upload-intro">{initialPlan ? '軽量版を、あなただけのクラウドへ。' : 'フォルダをそのまま、あなただけのクラウドへ。'}</p>
    <div className="upload-assurances"><span><ShieldCheck size={16} />非公開で保存</span><span>Macの原本は残ります</span><span>自動同期なし</span></div>
    <ol className="upload-steps" aria-label="アップロードの手順">{['フォルダを選ぶ', '内容を確認', activeStep].map((name, index) => <li key={index} className={step === index + 1 ? 'active' : step > index + 1 ? 'done' : ''} aria-current={step === index + 1 ? 'step' : undefined}><span>{step > index + 1 ? '✓' : index + 1}</span>{name}</li>)}</ol>
    {error ? <p role="alert" className="error-box">{error}</p> : null}
    {!plan ? <div className="upload-panel">
      <div className="upload-folder-picker"><FolderOpen size={42} /><h2>{currentName || 'アップロードするフォルダを選ぶ'}</h2><p>サブフォルダもまとめて取り込めます。</p>
      {window.photoHub ? <button className="primary" disabled={busy} onClick={choose}><FolderOpen size={17} />{path ? '別のフォルダを選ぶ' : 'フォルダを選ぶ'}</button> : <label>フォルダの場所<input value={path} onChange={e => setPath(e.target.value)} placeholder="フォルダの絶対パス" /></label>}
      {path ? <><p className="upload-path">{path}</p><button className="primary" disabled={busy || !bucket.trim()} onClick={inspect}>{busy ? 'フォルダの内容を確認しています…' : '内容を確認する'}<ChevronRight size={17} /></button></> : null}
      </div>
      <details className="upload-details"><summary><Settings2 size={15} />保存先の設定 <span>設定済み · {region === 'ap-northeast-1' ? '東京' : region}</span></summary><p>通常は変更不要です。保存先を変える場合だけ設定してください。</p><fieldset disabled={busy}><label>S3バケット<input value={bucket} onChange={e => setBucket(e.target.value)} /></label><label>AWSプロファイル<input value={profile} onChange={e => setProfile(e.target.value)} /></label><label>リージョン<input value={region} onChange={e => setRegion(e.target.value)} /></label></fieldset></details>
    </div> : <>
      <div className="upload-panel">
        <div className="upload-panel-heading"><div className="upload-folder-icon">{plan.state === 'complete' ? <CheckCircle2 size={28} /> : <FolderOpen size={28} />}</div><div><h2>{plan.name}</h2><span>{labels[plan.state] ?? plan.state}</span></div>{!initialPlan && !uploading ? <button className="text-button" disabled={busy} onClick={() => { setPlan(null); setConfirmed(false); }}>別のフォルダを選ぶ</button> : null}</div>
        <div className="upload-stats"><div><strong>{plan.items.length.toLocaleString()}</strong><span>画像・動画</span></div><div><strong>{size(plan.byteSize)}</strong><span>{mediaLabel}の合計</span></div><div><strong>{plan.folders.length.toLocaleString()}</strong><span>フォルダ</span></div></div>
        {plan.duplicateCount ? <p className="upload-note">内容が同じファイル {plan.duplicateCount}件は送信しません。</p> : null}
        {plan.skipped ? <p className="upload-note">対象外のファイル {plan.skipped}件は送信しません。</p> : null}
        {plan.error ? <p role="alert" className="error-box">{plan.error}</p> : null}
        {step === 3 ? <div className="upload-progress" role="status"><div><strong>{plan.state === 'complete' ? '保存と照合が完了しました' : uploading ? 'アップロードと照合を進めています' : '手動で再開できます'}</strong><span>{plan.completed} / {plan.items.length}件</span></div><progress max={Math.max(plan.items.length, 1)} value={plan.state === 'complete' ? Math.max(plan.items.length, 1) : plan.completed} /><p>{plan.state === 'complete' ? 'Macの原本はそのまま残っています。' : '停止しても、照合済みの原本は再送しません。'}</p></div> : null}
        <div className="upload-destination"><ShieldCheck size={16} /><span>非公開S3 · {plan.region === 'ap-northeast-1' ? '東京' : plan.region}</span><code>{plan.bucket}</code></div>
        <div className="upload-cost"><span>今回の{mediaLabel}の保存料目安</span><strong>{plan.region === 'ap-northeast-1' ? `${storageYen > 0 && storageYen < 0.1 ? '0.1円未満' : `${storageYen.toFixed(1)}円`} / 月` : 'このリージョンは未計算'}</strong><p>リクエスト・閲覧・既存データの費用は別です。予算通知は未接続です。</p><details><summary>計算条件を見る</summary><p>全て新規保存して1か月保持する場合。東京Standard・最初の50TB、2026年10月14日確認。${storageUSD > 0 && storageUSD < 0.0001 ? '0.0001未満' : storageUSD.toFixed(4)}／月。1GiB＝2³⁰ bytes、$0.025/GiB月。為替150円/USD・税10%を仮定。PUT等$0.0047/1,000回、GET／HEAD等$0.00037/1,000回。管理JSON・旧版・再試行・付帯サービスは別。月2,000円以内を保証する見積もりではありません。</p></details></div>
        {plan.state !== 'complete' && !uploading ? <div className="upload-start"><label className="collection-check"><input type="checkbox" checked={confirmed} onChange={e => setConfirmed(e.target.checked)} />このフォルダのメディアとフォルダ名を、上の保存先へ送信する</label><button className="primary" disabled={busy || !confirmed} onClick={() => run(async () => updatePlan(await api<FolderUpload>(`/folder-uploads/${plan.id}/start`, 'POST', {confirmUpload: true})))}><Upload size={18} />{plan.state === 'planned' ? 'アップロードを開始' : 'アップロードを再開'}</button></div> : null}
        {uploading ? <button className="secondary" disabled={busy} onClick={() => run(async () => updatePlan(await api<FolderUpload>(`/folder-uploads/${plan.id}/pause`, 'POST', {})))}>このファイルの完了後に停止</button> : null}
        {plan.state === 'complete' && onOpenLibrary ? <button className="primary" onClick={onOpenLibrary}><FolderOpen size={18} />保存したフォルダを見る</button> : null}
      </div>
      <details className="upload-panel upload-file-list"><summary>フォルダの中身を確認 <span>{plan.items.length}件</span></summary><nav className="upload-breadcrumbs" aria-label="フォルダ階層"><button onClick={() => setFolderId(null)}>すべて</button>{trail.map(part => <span key={part.id}><ChevronRight size={12} /><button onClick={() => setFolderId(part.id)}>{part.name}</button></span>)}</nav><ul>{children.map(child => <li key={child.id}><button onClick={() => setFolderId(child.id)}><FolderOpen size={18} /><span>{child.name}</span><ChevronRight size={16} /></button></li>)}{items.map(item => <li key={item.id}><FileImage size={17} /><span>{item.name}</span><small>{size(item.byteSize)}</small>{item.state === 'verified' ? <CheckCircle2 size={16} aria-label="照合済み" /> : null}</li>)}</ul>{folderId && !children.length && !items.length ? <p>このフォルダは空です。</p> : null}</details>
    </>}
    {!initialPlan ? <details className="upload-details upload-history"><summary>これまでのアップロード <span>{plans.length}件</span></summary>{plans.length ? <ul>{plans.map(value => <li key={value.id}><button disabled={busy || uploading} onClick={() => { select(value); setFolderId(value.folders.find(f => f.parentId === null)?.id ?? null); }}><FolderOpen size={18} /><span>{value.name}<small>{value.items.length}件 · {size(value.byteSize)}</small></span><em>{labels[value.state] ?? value.state}</em><ChevronRight size={16} /></button></li>)}</ul> : <p>まだアップロードはありません。</p>}</details> : null}
    <p className="upload-limits">1ファイル5GiB・1回20GiB・10,000件まで。隠しファイル・リンク・対象外形式は送信しません。一時コピー用の空き容量が必要です。</p>
  </section>;
}
