import { useEffect, useState } from 'react';
import { Film, FolderOpen } from 'lucide-react';
import type { LightVideo, FolderUpload } from './generated/contracts';
import { api, bytes } from './api';
import { FolderUploader } from './FolderUploader';

const labels: Record<string, string> = { planned: '作成前', creating: '作成中', complete: '作成完了', cancelled: '停止', failed: '失敗', interrupted: '中断' };
export function LightVideoMaker() {
  const [jobs, setJobs] = useState<LightVideo[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [path, setPath] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [upload, setUpload] = useState<{jobId: string; plan: FolderUpload} | null>(null);
  const job = jobs.find(value => value.id === selected);
  const creating = jobs.some(value => value.state === 'creating');
  async function refresh(signal?: AbortSignal) { setJobs(await api<LightVideo[]>('/light-videos', 'GET', undefined, signal)); }
  useEffect(() => { const abort = new AbortController(); refresh(abort.signal).catch(e => { if (e.name !== 'AbortError') setError(e.message); }); return () => abort.abort(); }, []);
  useEffect(() => {
    if (!creating) return;
    const abort = new AbortController();
    const timer = setInterval(() => { refresh(abort.signal).catch(e => { if (e.name !== 'AbortError') setError(e.message); }); }, 2000);
    return () => { clearInterval(timer); abort.abort(); };
  }, [creating]);
  async function run(action: () => Promise<void>) { setBusy(true); setError(''); try { await action(); } catch (e) { setError(e instanceof Error ? e.message : '操作に失敗しました。'); } finally { setBusy(false); } }
  async function inspect(value: string) { const result = await api<LightVideo>('/light-videos/inspect', 'POST', {path: value}); setJobs(previous => [result, ...previous.filter(old => old.id !== result.id)]); setSelected(result.id); }
  return <section aria-label="軽量版を作る" className="folder-uploader">
    <p className="upload-intro">見るための動画を、軽く。</p>
    <div className="upload-assurances"><span>原本はそのまま</span><span>Mac内で作成</span><span>S3へは確認して手動送信</span></div>
    {error && <p role="alert" className="error-box">{error}</p>}
    <div className="upload-panel"><div className="upload-folder-picker"><Film size={42}/><h2>動画を選ぶだけ</h2><p>1080pまで・動きは60fpsまで維持。音声込み約3Mbpsを目標にします。</p>
      {window.photoHub ? <button className="primary" disabled={busy || creating} onClick={() => run(async () => { const value = await window.photoHub!.chooseVideo(); if (value) await inspect(value); })}><FolderOpen size={17}/>動画を選ぶ</button> : <><label>動画の場所<input value={path} onChange={event => setPath(event.target.value)}/></label><button disabled={busy || creating || !path.trim()} onClick={() => run(() => inspect(path))}>動画を確認</button></>}
    </div></div>
    {job && <div className="upload-panel"><h2>{job.name}</h2><p>{labels[job.state]}</p><div className="upload-stats"><div><strong>{bytes(job.originalBytes)}</strong><span>原本</span></div><div><strong>{bytes(job.outputBytes || job.estimatedBytes)}</strong><span>{job.outputBytes ? '作成した軽量版' : '軽量版の目安'}</span></div><div><strong>{Math.ceil(job.durationSeconds / 60)}分</strong><span>動画の長さ</span></div></div>
      {job.warning && <p role="status">{job.warning}</p>}{job.error && <p role="alert" className="error-box">{job.error}</p>}
      {job.state === 'creating' ? <><progress aria-label="軽量版の作成" max={100} value={job.progress}/><p>{job.progress}% · Macの電力と空き容量を使います。</p><button disabled={busy} onClick={() => run(async () => { await api(`/light-videos/${job.id}/cancel`, 'POST'); await refresh(); })}>作成を停止</button></> : job.state === 'complete' ? <><video controls preload="none" style={{width: '100%', maxHeight: 440}} src={`/api/v1/light-videos/${job.id}/content`}/><p><a href={`/api/v1/light-videos/${job.id}/content?download=true`} download>軽量版を取り出す</a></p><p>取り出すとMac内にコピーが増えます。S3への送信は下の確認画面から行います。</p><button className="primary" disabled={busy} onClick={() => run(async () => { const plan = await api<FolderUpload>(`/light-videos/${job.id}/prepare-upload`, 'POST'); setUpload({jobId: job.id, plan}); })}>S3へアップロード · 内容を確認</button></> : <button className="primary" disabled={busy || creating} onClick={() => run(async () => { await api(`/light-videos/${job.id}/start`, 'POST'); await refresh(); })}>{busy ? '準備中…' : '軽量版を作る（Mac内）'}</button>}
      <p className="upload-note">画質を確認してから利用してください。作成結果はアプリの作業領域に残ります。自動送信・自動削除は行いません。</p>
    </div>}
    {upload && upload.jobId === selected ? <div className="upload-panel"><h2>軽量版のS3送信</h2><p>原本を置き換えず、軽量版を別フォルダで保存します。送信内容と保存先を確認してから開始してください。</p><FolderUploader key={upload.plan.id} initialPlan={upload.plan}/></div> : null}
    <details className="upload-details upload-history"><summary>作成履歴 <span>{jobs.length}件</span></summary><ul>{jobs.map(value => <li key={value.id}><button onClick={() => setSelected(value.id)}><Film size={17}/><span>{value.name}<small>{labels[value.state]} · {bytes(value.outputBytes || value.estimatedBytes)}</small></span></button></li>)}</ul></details>
    <p className="upload-limits">1本ずつ手動作成。原本5GiB・2時間・60fpsまで。HDRは未対応。既に軽い動画では容量が増える場合があります。</p>
  </section>;
}
