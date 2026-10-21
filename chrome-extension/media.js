/*
 * Purpose: Browse authenticated phone media and open audio/video in dedicated Lanvi players.
 * Integration: media.html; all requests go through the loopback-only Lanvi PC bridge.
 * Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294.
 * Changelog: Adds encrypted range-stream playback, music queue, movie seeking, volume, speed, PiP and VTT subtitle controls.
 */
'use strict';
const CONTROL = 'http://127.0.0.1:8788';
const $ = (id) => document.getElementById(id);
const state = { targets: [], selectedDeviceId: '', catalogSessionId: '', device: null, items: [], filter: 'all', folder: '', query: '', musicQueue: [], musicIndex: -1, currentStreamSessionId: '', currentMediaId: '', subtitleUrl: '' };
const audio = $('audioPlayer');
const video = $('videoPlayer');

function icon(name, className = 'icon') {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', className); svg.setAttribute('aria-hidden', 'true');
  const use = document.createElementNS('http://www.w3.org/2000/svg', 'use'); use.setAttribute('href', `#ph-${name}`); svg.append(use); return svg;
}
function formatBytes(v) { const bytes = Number(v || 0); if (bytes < 1024) return `${bytes} B`; const units = ['KB','MB','GB','TB']; let n = bytes / 1024, i = 0; while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; } return `${n.toFixed(n >= 100 ? 0 : 1)} ${units[i]}`; }
function timeLabel(value) { if (!Number.isFinite(value) || value < 0) return '0:00'; const s = Math.floor(value); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; }
function setNotice(message, type = 'info') { const n = $('notice'); n.textContent = message; n.className = `notice ${type}`; n.hidden = !message; }
async function api(path, options = {}) { const response = await fetch(`${CONTROL}${path}`, { cache: 'no-store', ...options }); const text = await response.text(); let body = {}; try { body = text ? JSON.parse(text) : {}; } catch { body = {}; } if (!response.ok) throw new Error(body.error || `Bridge returned HTTP ${response.status}`); return body; }
async function post(path, data = {}) { return api(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }); }
function setBridgeStatus(online, label) { const el = $('bridgeState'); el.className = `state-pill ${online ? 'online' : ''}`; el.replaceChildren(); const dot = document.createElement('i'); const text = document.createTextNode(label); el.append(dot, text); }

async function loadTargets() {
  try {
    const status = await api('/api/status');
    setBridgeStatus(true, 'Bridge online');
    const result = await api('/api/media/targets');
    state.targets = Array.isArray(result.targets) ? result.targets : [];
    const select = $('deviceSelect'); const old = state.selectedDeviceId || select.value;
    select.replaceChildren();
    if (!state.targets.length) {
      const option = document.createElement('option'); option.value = ''; option.textContent = 'No Lanvi phone discovered'; select.append(option);
      $('libraryStatus').textContent = 'Open Lanvi on your Android phone and keep it running on the same reachable LAN.';
      state.selectedDeviceId = '';
      state.catalogSessionId = '';
      state.device = null;
      state.items = [];
      state.folder = '';
      renderMediaList();
      return;
    }
    for (const target of state.targets) {
      const option = document.createElement('option'); option.value = target.deviceId; option.textContent = `${target.name} · ${Array.isArray(target.addresses) ? target.addresses[0] || 'LAN' : 'LAN'}`; select.append(option);
    }
    state.selectedDeviceId = state.targets.some((t) => t.deviceId === old) ? old : state.targets[0].deviceId;
    select.value = state.selectedDeviceId;
    $('libraryStatus').textContent = `${state.targets.length} nearby phone${state.targets.length === 1 ? '' : 's'} · discovery is not authorization`;
    if (status.ownDevice) $('libraryStatus').textContent += ` · Streaming to ${status.pcName || 'this PC'}`;
  } catch (error) {
    setBridgeStatus(false, 'Bridge unavailable');
    $('libraryStatus').textContent = 'Start node bridge.js, then refresh.';
    setNotice(error.message, 'error');
  }
}
async function loadCatalog() {
  const deviceId = $('deviceSelect').value;
  if (!deviceId) { setNotice('No compatible phone was discovered. Keep Lanvi open on Android and refresh.', 'error'); return; }
  state.selectedDeviceId = deviceId;
  $('refreshBtn').disabled = true;
  $('libraryStatus').textContent = 'Requesting encrypted media catalog…';
  setNotice('');
  try {
    const catalog = await api(`/api/media/catalog?deviceId=${encodeURIComponent(deviceId)}`);
    state.catalogSessionId = catalog.sessionId;
    state.device = catalog.device;
    state.items = Array.isArray(catalog.items) ? catalog.items : [];
    state.folder = '';
    $('libraryStatus').textContent = `${state.items.length} audio/video files · ${state.device?.name || 'Phone'} · local encrypted streaming`;
    renderMediaList();
    setNotice(state.items.length ? 'Phone media library loaded. Choose music or a movie to start streaming.' : 'No supported audio/video files were found on that phone.', state.items.length ? 'success' : 'info');
  } catch (error) {
    $('libraryStatus').textContent = 'Could not read phone media library.';
    setNotice(`${error.message} Open Lanvi → Media on the phone, enable media sharing, and scan the PC QR code again if pairing has expired.`, 'error');
    state.items = []; renderMediaList();
  } finally { $('refreshBtn').disabled = false; }
}
async function refreshAll() { await loadTargets(); if (state.selectedDeviceId) await loadCatalog(); }
function renderFolders(items) {
  const wrap = $('folderChips'); wrap.replaceChildren();
  const folders = [...new Set(items.map((item) => String(item.folder || '').trim()).filter(Boolean))].sort((a,b)=>a.localeCompare(b));
  if (!folders.length) return;
  const all = document.createElement('button'); all.className = `folder-chip ${state.folder === '' ? 'active' : ''}`; all.textContent = 'All folders'; all.addEventListener('click',()=>{state.folder='';renderMediaList();}); wrap.append(all);
  for (const folder of folders.slice(0, 36)) { const b=document.createElement('button');b.className=`folder-chip ${state.folder===folder?'active':''}`;b.textContent=folder;b.title=folder;b.addEventListener('click',()=>{state.folder=folder;renderMediaList();});wrap.append(b); }
}
function renderMediaList() {
  const list = $('mediaList'); list.replaceChildren();
  let items = state.items.filter((item) => state.filter === 'all' || item.kind === state.filter);
  if (state.folder) items = items.filter((item) => item.folder === state.folder || String(item.relativePath || '').startsWith(`${state.folder}/`));
  const q = state.query.trim().toLowerCase();
  if (q) items = items.filter((item) => `${item.name} ${item.relativePath} ${item.folder}`.toLowerCase().includes(q));
  $('itemCount').textContent = `${items.length} item${items.length === 1 ? '' : 's'}`;
  renderFolders(state.items.filter((item) => state.filter === 'all' || item.kind === state.filter));
  if (!items.length) { const empty=document.createElement('div');empty.className='empty-state';const glyph=document.createElement('span');glyph.className='empty-glyph';glyph.append(icon('folder-open'));const title=document.createElement('strong');title.textContent=state.items.length?'No matches in this view':'Connect and enable phone media';const p=document.createElement('p');p.textContent=state.items.length?'Try another category, folder or search query.':'Open Lanvi → Media on your phone and enable media sharing.';empty.append(glyph,title,p);list.append(empty);return; }
  for (const item of items) {
    const row=document.createElement('article');row.className='media-row';
    const glyph=document.createElement('span');glyph.className=`media-glyph ${item.kind==='video'?'video':''}`;glyph.append(icon(item.kind==='video'?'film-slate':'music-notes'));
    const copy=document.createElement('div');copy.className='media-copy';const title=document.createElement('strong');title.textContent=item.name;title.title=item.name;const sub=document.createElement('small');sub.textContent=item.relativePath||item.folder||item.kind;sub.title=sub.textContent;copy.append(title,sub);
    const size=document.createElement('span');size.className='media-size';size.textContent=formatBytes(item.size);
    const play=document.createElement('button');play.type='button';play.className='play-item';play.title=item.kind==='video'?'Play in Lanvi Cinema':'Play in Lanvi Music';play.append(icon('play'));play.addEventListener('click',()=>openMedia(item));
    row.append(glyph,copy,size,play);row.addEventListener('dblclick',()=>openMedia(item));list.append(row);
  }
}
async function openMedia(item) {
  if (!state.catalogSessionId) { setNotice('Refresh the phone media catalog first.','error'); return; }
  try {
    setNotice(`Opening ${item.name}…`,'info');
    const opened = await post('/api/media/open',{catalogSessionId:state.catalogSessionId,mediaId:item.id});
    await closeCurrentSession();
    state.currentStreamSessionId = opened.sessionId; state.currentMediaId = item.id;
    if (item.kind === 'music') await openMusic(item,opened.streamUrl);
    else await openVideo(item,opened.streamUrl);
    setNotice('Streaming encrypted media from your phone over the local network.','success');
  } catch(error) { setNotice(error.message,'error'); }
}
function showView(name) { $('browseView').hidden=name!=='browse'; $('musicView').hidden=name!=='music'; $('videoView').hidden=name!=='video'; }
async function closeCurrentSession() {
  if (state.currentStreamSessionId) {
    const id=state.currentStreamSessionId;state.currentStreamSessionId='';
    post('/api/media/close',{sessionId:id}).catch(()=>{});
  }
  try { audio.pause(); audio.removeAttribute('src'); audio.load(); } catch {}
  try { video.pause(); video.removeAttribute('src'); video.load(); } catch {}
  if(state.subtitleUrl){URL.revokeObjectURL(state.subtitleUrl);state.subtitleUrl='';}
  state.currentMediaId='';
}
async function openMusic(item,url) {
  state.musicQueue = state.items.filter((entry)=>entry.kind==='music');
  state.musicIndex = state.musicQueue.findIndex((entry)=>entry.id===item.id);
  $('musicTitle').textContent=item.name;$('musicPath').textContent=item.relativePath||'Phone music library';
  audio.src=url;audio.volume=Number($('musicVolume').value);audio.load();showView('music');renderQueue();
  try { await audio.play(); } catch { setNotice('Track is loaded. Press Play to start audio; Chrome may block autoplay until a user gesture.','info'); }
  syncMusicButton();
}
function renderQueue(){const wrap=$('queueList');wrap.replaceChildren();$('queueCount').textContent=`${state.musicQueue.length} track${state.musicQueue.length===1?'':'s'}`;state.musicQueue.forEach((item,index)=>{const row=document.createElement('div');row.className=`queue-row ${index===state.musicIndex?'active':''}`;row.tabIndex=0;row.setAttribute('role','button');const n=document.createElement('span');n.className='queue-number';n.textContent=index===state.musicIndex?'♫':String(index+1);const copy=document.createElement('div');copy.className='queue-copy';const title=document.createElement('strong');title.textContent=item.name;const sub=document.createElement('small');sub.textContent=item.relativePath||'Phone library';copy.append(title,sub);const size=document.createElement('span');size.className='queue-duration';size.textContent=formatBytes(item.size);row.append(n,copy,size);row.addEventListener('click',()=>playQueueIndex(index));row.addEventListener('keydown',(e)=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();playQueueIndex(index);}});wrap.append(row);});}
async function playQueueIndex(index){if(index<0||index>=state.musicQueue.length)return;await openMedia(state.musicQueue[index]);}
function syncMusicButton(){const use=$('musicPlayBtn').querySelector('use');if(use)use.setAttribute('href',audio.paused?'#ph-play':'#ph-pause');}
function syncVideoButton(){const use=$('videoPlayBtn').querySelector('use');if(use)use.setAttribute('href',video.paused?'#ph-play':'#ph-pause');$('videoOverlay').classList.toggle('hidden',!video.paused&&video.readyState>=2);}
async function openVideo(item,url){$('videoTitle').textContent=item.name;$('videoPath').textContent=item.relativePath||'Phone videos';if(state.subtitleUrl){URL.revokeObjectURL(state.subtitleUrl);state.subtitleUrl='';}const oldTracks=video.querySelectorAll('track');oldTracks.forEach(track=>track.remove());video.src=url;video.volume=Number($('videoVolume').value);video.playbackRate=Number($('videoSpeed').value);video.load();showView('video');$('videoOverlay').classList.remove('hidden');syncVideoButton();}
function seekMedia(media,range){if(!Number.isFinite(media.duration)||media.duration<=0)return;media.currentTime=(Number(range.value)/1000)*media.duration;}
function updateTimeline(media,range,current,duration){current.textContent=timeLabel(media.currentTime);duration.textContent=timeLabel(media.duration);if(Number.isFinite(media.duration)&&media.duration>0&&!range.matches(':active'))range.value=String(Math.round(media.currentTime/media.duration*1000));}
function togglePlay(media){if(media.paused)media.play().catch(()=>setNotice('The browser could not start playback. Try Play again or check the media format.','error'));else media.pause();}

$('refreshBtn').addEventListener('click',refreshAll);
$('deviceSelect').addEventListener('change',()=>{state.selectedDeviceId=$('deviceSelect').value;loadCatalog();});
$('searchInput').addEventListener('input',(e)=>{state.query=e.target.value;renderMediaList();});
document.querySelectorAll('.category-tab').forEach((btn)=>btn.addEventListener('click',()=>{document.querySelectorAll('.category-tab').forEach((b)=>b.classList.toggle('active',b===btn));state.filter=btn.dataset.filter||'all';state.folder='';renderMediaList();}));
$('musicBackBtn').addEventListener('click',async()=>{await closeCurrentSession();showView('browse');});
$('videoBackBtn').addEventListener('click',async()=>{await closeCurrentSession();showView('browse');});
$('musicPlayBtn').addEventListener('click',()=>togglePlay(audio));
$('previousBtn').addEventListener('click',()=>playQueueIndex(state.musicIndex-1));
$('nextBtn').addEventListener('click',()=>{let next=state.musicIndex+1;if($('repeatBtn').classList.contains('active'))next=state.musicIndex;if($('shuffleBtn').classList.contains('active')&&state.musicQueue.length>1){do{next=Math.floor(Math.random()*state.musicQueue.length);}while(next===state.musicIndex);}if(next>=state.musicQueue.length)next=0;playQueueIndex(next);});
$('shuffleBtn').addEventListener('click',()=>{$('shuffleBtn').classList.toggle('active');});
$('repeatBtn').addEventListener('click',()=>{$('repeatBtn').classList.toggle('active');audio.loop=$('repeatBtn').classList.contains('active');});
$('musicVolume').addEventListener('input',()=>{audio.volume=Number($('musicVolume').value);$('musicVolumeLabel').textContent=`${Math.round(audio.volume*100)}%`;});
$('musicSeek').addEventListener('input',()=>seekMedia(audio,$('musicSeek')));
audio.addEventListener('timeupdate',()=>updateTimeline(audio,$('musicSeek'),$('musicCurrent'),$('musicDuration')));
audio.addEventListener('durationchange',()=>updateTimeline(audio,$('musicSeek'),$('musicCurrent'),$('musicDuration')));
audio.addEventListener('play',syncMusicButton);audio.addEventListener('pause',syncMusicButton);audio.addEventListener('waiting',()=>{if(!$('musicView').hidden)setNotice('Buffering audio from the phone over your local network…','info');});audio.addEventListener('playing',()=>{if(!$('musicView').hidden)setNotice('Streaming music directly from your phone.','success');});audio.addEventListener('ended',()=>{if(!$('repeatBtn').classList.contains('active'))$('nextBtn').click();});audio.addEventListener('error',()=>{if(!$('musicView').hidden)setNotice('Chrome could not decode this audio format. The file remains unchanged on your phone.','error');});
$('videoOverlayPlay').addEventListener('click',()=>togglePlay(video));$('videoPlayBtn').addEventListener('click',()=>togglePlay(video));$('videoFrame').addEventListener('dblclick',()=>{if(document.fullscreenElement)document.exitFullscreen?.();else $('videoFrame').requestFullscreen?.();});
$('videoBack10').addEventListener('click',()=>{video.currentTime=Math.max(0,video.currentTime-10);});$('videoForward10').addEventListener('click',()=>{video.currentTime=Math.min(video.duration||Infinity,video.currentTime+10);});
$('videoSeek').addEventListener('input',()=>seekMedia(video,$('videoSeek')));video.addEventListener('timeupdate',()=>updateTimeline(video,$('videoSeek'),$('videoCurrent'),$('videoDuration')));video.addEventListener('durationchange',()=>updateTimeline(video,$('videoSeek'),$('videoCurrent'),$('videoDuration')));video.addEventListener('play',syncVideoButton);video.addEventListener('pause',syncVideoButton);video.addEventListener('loadedmetadata',syncVideoButton);video.addEventListener('waiting',()=>{if(!$('videoView').hidden)setNotice('Buffering video from the phone over your local network…','info');});video.addEventListener('playing',()=>{if(!$('videoView').hidden)setNotice('Streaming video directly from your phone.','success');});video.addEventListener('error',()=>{if(!$('videoView').hidden){syncVideoButton();setNotice('Chrome could not decode this movie. MP4/H.264 and WebM are generally the safest formats; some MKV/AVI codecs require a later transcoding feature.','error');}});
$('videoVolume').addEventListener('input',()=>{video.volume=Number($('videoVolume').value);video.muted=video.volume===0;const use=$('videoMuteBtn').querySelector('use');if(use)use.setAttribute('href',video.muted?'#ph-volume-mute':'#ph-volume-high');});$('videoMuteBtn').addEventListener('click',()=>{video.muted=!video.muted;const use=$('videoMuteBtn').querySelector('use');if(use)use.setAttribute('href',video.muted?'#ph-volume-mute':'#ph-volume-high');});$('videoSpeed').addEventListener('change',()=>{video.playbackRate=Number($('videoSpeed').value);});
$('fullscreenBtn').addEventListener('click',()=>{if(document.fullscreenElement)document.exitFullscreen?.();else $('videoFrame').requestFullscreen?.();});$('pipBtn').addEventListener('click',async()=>{try{if(document.pictureInPictureElement)await document.exitPictureInPicture();else await video.requestPictureInPicture();}catch{setNotice('Picture-in-picture is not available for this playback session.','info');}});
$('captionsBtn').addEventListener('click',()=>{const tracks=video.textTracks;if(!tracks.length){setNotice('Load a WebVTT (.vtt) subtitle file first.','info');return;}let showing=false;for(let i=0;i<tracks.length;i++){if(tracks[i].mode==='showing')showing=true;}for(let i=0;i<tracks.length;i++)tracks[i].mode=showing?'disabled':'showing';$('captionsBtn').classList.toggle('active',!showing);});
$('subtitleFile').addEventListener('change',()=>{const file=$('subtitleFile').files?.[0];if(!file)return;if(!file.name.toLowerCase().endsWith('.vtt')){setNotice('Use a WebVTT (.vtt) subtitle file. SRT conversion can be added later.','error');return;}if(state.subtitleUrl)URL.revokeObjectURL(state.subtitleUrl);state.subtitleUrl=URL.createObjectURL(file);const track=document.createElement('track');track.kind='subtitles';track.label='Local subtitles';track.srclang='en';track.src=state.subtitleUrl;track.default=true;video.append(track);setNotice('Subtitle track loaded. Use CC to toggle it.','success');});
document.addEventListener('keydown',(event)=>{const target=event.target;if(target instanceof HTMLInputElement||target instanceof HTMLSelectElement||target?.isContentEditable)return;if($('videoView').hidden)return;if(event.code==='Space'){event.preventDefault();togglePlay(video);}if(event.key==='ArrowLeft'){video.currentTime=Math.max(0,video.currentTime-10);}if(event.key==='ArrowRight'){video.currentTime=Math.min(video.duration||Infinity,video.currentTime+10);}if(event.key.toLowerCase()==='f')$('fullscreenBtn').click();});
window.addEventListener('beforeunload',()=>{if(state.currentStreamSessionId)post('/api/media/close',{sessionId:state.currentStreamSessionId}).catch(()=>{});if(state.subtitleUrl)URL.revokeObjectURL(state.subtitleUrl);});
refreshAll();
