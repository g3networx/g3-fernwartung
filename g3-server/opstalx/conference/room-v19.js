import {urlKey} from './crypto.js';
import {annotationKey, openAnnotation, sealAnnotation, sealInvitation, verifyInviteKey} from './secure-invite.js';

(async () => {
  'use strict';
  const joinForm=document.getElementById('join');
  joinForm.addEventListener('submit',event=>{
    event.preventDefault();
    const showError=()=>{document.getElementById('joinError').textContent='Bitte den geschützten Einladungslink prüfen.';};
    try {
      const link=new URL(document.getElementById('protectedLink').value.trim());
      const code=/^\/vas\/join\/([0-9]{10})$/.exec(link.pathname)?.[1];
      if(link.origin!==location.origin||link.username||link.password||link.search||!code||!/^#vasKey=[A-Za-z0-9_-]{43}$/.test(link.hash)){
        showError();
        return;
      }
      location.assign('/vas/?room='+code+link.hash);
    } catch (_) {
      showError();
    }
  });
  const joinValue = new URL(location.href).searchParams.get('room')?.toLowerCase().replace(/[\s-]/g,'');
  if (!joinValue) return;
  let code = joinValue;
  const digits = /^[0-9]{10}$/;
  const grant = new URLSearchParams(location.hash.slice(1));
  const androidWebView = navigator.userAgent.includes('OpsLinXAndroidVAS/');
  const jwt = grant.get('jwt');
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);
  const secret = jwt ? urlKey(crypto.getRandomValues(new Uint8Array(32))) : grant.get('vasKey');
  if (!/^[A-Za-z0-9_-]{43}$/.test(secret || '')) {
    document.getElementById('joinError').textContent = 'Bitte die Einladung in der App annehmen oder den geschützten Link öffnen.';
    return;
  }
  let shortCode = jwt ? grant.get('code') : joinValue;
  if (digits.test(joinValue) && !jwt) {
    try {
      const response = await fetch('/vas/redeem', {method:'POST',cache:'no-store',
        headers:{'Content-Type':'application/json'},body:JSON.stringify({code:joinValue})});
      if (!response.ok) throw Error();
      ({room:code} = await response.json());
    } catch (_) {
      document.getElementById('joinError').textContent = 'Der Raumcode ist ungültig oder abgelaufen.';
      return;
    }
  }
  if (!/^[a-f0-9]{32}$/.test(code || '')) {
    document.getElementById('joinError').textContent = 'Bitte den Raumcode prüfen.';
    return;
  }
  if (!digits.test(shortCode || '')) shortCode = undefined;
  const twoCoreSupporter = Boolean(jwt) && navigator.hardwareConcurrency <= 2;
  const lightSupporterVideo = Boolean(jwt)
    && (navigator.hardwareConcurrency <= 4 || navigator.deviceMemory <= 4);
  const supporterCamera = lightSupporterVideo
    ? {facingMode:{ideal:'user'},height:{ideal:180,max:180},width:{ideal:320,max:320},frameRate:{ideal:20,max:20}}
    : {facingMode:{ideal:'user'},height:{ideal:360,max:540},width:{ideal:640,max:960},frameRate:{ideal:20,max:24}};
  const annotation = await annotationKey(secret,code);
  const receivedNonces=new Set();
  const rawKey=atob(secret.replaceAll('-','+').replaceAll('_','/')+'=');
  const mediaKey=Array.from(rawKey,char=>char.charCodeAt(0).toString(16).padStart(2,'0')).join('');
  let secure=false, stopEncryptionWatch, encryptionDeadline, readyTimer, transportWatch;
  const imageChunkSize=3900;
  const get = id => document.getElementById(id);
  get('join').hidden = true;
  get('controls').hidden = false;
  const status = text => { get('status').textContent = text; };
  const displayedCode = shortCode ? shortCode.replace(/^(\d{3})(\d{3})(\d{4})$/, '$1 $2 $3') : code;
  if (jwt) get('fallbackCode').textContent = 'Geschützte Einladung für Raum ' + displayedCode;
  let codecPreferenceOrder;
  if (jwt) {
    const video = {contentType:'video/H264',width:640,height:360,bitrate:600000,framerate:20};
    const capabilities = navigator.mediaCapabilities;
    const efficientH264 = capabilities?.decodingInfo && capabilities?.encodingInfo
      && await Promise.race([
        Promise.all([
          capabilities.decodingInfo({type:'webrtc',video}),
          capabilities.encodingInfo({type:'webrtc',video}),
        ]).then(results=>results.every(info=>info.supported && info.powerEfficient)).catch(()=>false),
        new Promise(resolve=>setTimeout(()=>resolve(false),500)),
      ]);
    codecPreferenceOrder = efficientH264 ? ['H264','VP8','VP9','AV1'] : ['VP8','H264','VP9','AV1'];
  }
  const api = new JitsiMeetExternalAPI(location.host,{
    parentNode:get('call'),roomName:code,jwt,e2eeKey:mediaKey,
    interfaceConfigOverwrite:twoCoreSupporter ? {DISABLE_VIDEO_BACKGROUND:true} : undefined,
    configOverwrite:{
      disableDeepLinking:true,
      ...(androidWebView && {
        websocket:null,
        bosh:location.origin+'/http-bind',
      }),
      startSilent:true,
      startWithAudioMuted:true,
      disableAudioLevels:true,
      subject:'Video-Hilfe',
      startWithVideoMuted:true,
      prejoinConfig:{enabled:false},
      disableThirdPartyRequests:true,
      testing:{enableEncodedTransformSupport:true},
      e2ee:{externallyManagedKey:true},
      toolbarButtons:['camera','hangup','settings','select-background','tileview','fullscreen'],
      p2p:{enabled:false},
      ...(codecPreferenceOrder && {videoQuality:{codecPreferenceOrder}}),
      virtualBackground:{
        disabled:!jwt,
        ...(lightSupporterVideo && {
          advanced:{tierOverride:'low',targetFps:20,inferenceStride:twoCoreSupporter ? 4 : 2},
        }),
      },
      disableVirtualBackground:!jwt,
      constraints:{video:jwt
        ? supporterCamera
        : {facingMode:{ideal:'environment'},height:{ideal:720}}}
    }
  });
  const meetingFrame=api.getIFrame();
  meetingFrame.inert=true;
  const stopUnprotected=()=>{
    secure=false;
    clearTimeout(encryptionDeadline);
    clearTimeout(readyTimer);
    clearInterval(transportWatch);
    stopEncryptionWatch?.();
    meetingFrame.inert=true;
    get('controls').hidden=true;
    get('join').hidden=false;
    get('joinError').textContent='Die Ende-zu-Ende-Verschlüsselung konnte nicht sichergestellt werden.';
    api.dispose();
  };
  let stopBackgroundBudget;
  function startBackgroundBudget() {
    const meeting = api.getIFrame().contentWindow;
    const advanced = meeting?.APP?.store?.getState()['features/base/config']?.virtualBackground?.advanced;
    // Jitsi's background processor reads the same options object for every frame.
    if (!advanced || Object.isFrozen(advanced)) return;
    let stride = 4;
    let relaxedSamples = 0;
    let last = performance.now();
    let cpuPressure;
    const observer = typeof PressureObserver === 'function'
      ? new PressureObserver(records => { cpuPressure = records.at(-1)?.state; })
      : undefined;
    observer?.observe('cpu',{sampleInterval:1000}).catch(()=>{observer.disconnect();});
    const timer = setInterval(()=>{
      const now = performance.now();
      const late = now-last > 1100;
      last = now;
      if (document.hidden) return;
      if (cpuPressure==='critical' || late) {
        stride=8;
        relaxedSamples=0;
      } else if (cpuPressure==='serious') {
        stride=6;
        relaxedSamples=0;
      } else if (++relaxedSamples >= 5) {
        stride=4;
      }
      advanced.inferenceStride=stride;
    },1000);
    stopBackgroundBudget=()=>{
      clearInterval(timer);
      observer?.disconnect();
      advanced.inferenceStride=4;
    };
  }
  let self, host=false, channel=false, scene, incoming, author;
  let queue=Promise.resolve();
  let lightTrack, lightOn=false, lightPeer, lightRequest;
  let lightController;
  let switchingCamera=false;
  const mobileGuest=!jwt && (/Android|iPhone|iPad/i.test(navigator.userAgent)
    || navigator.maxTouchPoints>1);
  const localVideoTrack=()=>{
    const iframe=api.getIFrame();
    const tracks=iframe.contentWindow?.APP?.store?.getState()['features/base/tracks'];
    const nativeTracks=Array.isArray(tracks) ? tracks
      .filter(track=>track.local && track.mediaType==='video' && track.videoType!=='desktop')
      .map(track=>track.jitsiTrack?.getTrack?.()) : [];
    return [...nativeTracks, ...[...(iframe.contentDocument?.querySelectorAll('video') || [])]
      .filter(video=>!/^remoteVideo_/i.test(video.id))
      .flatMap(video=>video.srcObject?.getVideoTracks?.() || [])]
      .find(track=>track?.readyState==='live');
  };
  function resetLight(){
    const track=lightTrack;
    lightTrack=undefined;
    lightController=undefined;
    if (track?.readyState==='live') {
      void track.applyConstraints({advanced:[{torch:false}]}).catch(()=>{});
    }
  }
  const binding=(sender,target)=>JSON.stringify([code,sender,target]);
  const sendTo=async(peer,data)=>{
    if(!secure||!self)return;
    try {
      const sealed=await sealAnnotation(annotation,binding(self,peer),{ar:1,...data});
      if(secure)api.executeCommand('sendEndpointTextMessage',peer,JSON.stringify({to:peer,...sealed}));
    } catch (_) {
      status('Der geschützte Hinweis konnte nicht gesendet werden.');
    }
  };
  async function selectCamera(facingMode){
    if (!self || switchingCamera) return;
    const report=get('guestCameraStatus');
    const activeLabel=facingMode==='environment'?'Rückkamera aktiv.':'Frontkamera aktiv.';
    const before=localVideoTrack();
    if (before?.getSettings?.().facingMode===facingMode) {
      report.textContent=activeLabel;
      return;
    }
    switchingCamera=true;
    render();
    const controller=lightController;
    resetLight();
    if (controller) sendTo(controller,{type:'torch-reset',id:crypto.randomUUID()});
    report.textContent='Kamera wird gewechselt …';
    try{
      const {videoInput}=await api.getAvailableDevices();
      const cameraLabel=facingMode==='environment'
        ? /back|rear|environment|rück|hinter/i
        : /front|user|vorder/i;
      const camera=videoInput?.find(device=>cameraLabel.test(device.label));
      if(camera){
        await api.setVideoInputDevice(camera.label,camera.deviceId);
      }else{
        api.executeCommand('toggleCamera',facingMode);
      }
      for(let attempt=0;attempt<24 && self;attempt++){
        await new Promise(resolve=>setTimeout(resolve,250));
        const track=localVideoTrack();
        const active=track?.getSettings?.();
        if(active?.facingMode===facingMode || (camera && active?.deviceId===camera.deviceId)){
          report.textContent=activeLabel;
          return;
        }
      }
      report.textContent='Kamerawechsel fehlgeschlagen. Bitte Kamera und Berechtigung prüfen.';
    }catch(_){
      report.textContent='Kamerawechsel fehlgeschlagen. Bitte Kamera und Berechtigung prüfen.';
    }finally{
      switchingCamera=false;
      render();
    }
  }
  get('rearCamera').onclick=()=>selectCamera('environment');
  get('frontCamera').onclick=()=>selectCamera('user');
  addEventListener('pagehide',resetLight);
  get('cameraLight').onclick=async()=>{
    if(!host||!channel||lightRequest)return;
    const {rooms}=await api.getRoomsInfo();
    const guests=rooms.find(room=>room.isMainRoom)?.participants.filter(
      person=>person.id!==self && person.role!=='moderator'
    ) || [];
    if(guests.length!==1){status('Kameralicht ist bei einer Video-Hilfe mit genau einem Gast verfügbar.');return;}
    lightPeer=guests[0].id;
    const id=crypto.randomUUID();
    const timeout=setTimeout(()=>{
      if(lightRequest?.id===id){lightRequest=undefined;status('Keine Antwort vom Kameralicht.');render();}
    },6000);
    lightRequest={id,timeout};
    sendTo(lightPeer,{type:'torch',id,on:!lightOn});
    render();
  };
  let outbound=Promise.resolve();
  const send = data => {
    outbound=outbound.then(async()=>{
      if (!host || !channel) return;
      await sendTo('',data);
      await new Promise(resolve=>setTimeout(resolve,180));
    });
  };
  const frame=get('frame'),ink=get('ink'),textBox=get('textBox');
  const tools=[...get('annotationTools').querySelectorAll('[data-tool]')];
  const clamp=(value,max=1)=>Math.max(0,Math.min(max,value));
  const maxStrokes=64,maxPoints=160;
  let tool='arrow',drawingScene,draft,textDrag;
  const newStroke=kind=>document.createElementNS('http://www.w3.org/2000/svg',
    kind==='ellipse'?'ellipse':'polyline');
  function paintStroke(path,kind,points){
    if(kind==='ellipse'){
      const [[x0,y0],[x1,y1]]=points;
      path.setAttribute('cx',(x0+x1)/2);
      path.setAttribute('cy',(y0+y1)/2);
      path.setAttribute('rx',Math.abs(x1-x0)/2);
      path.setAttribute('ry',Math.abs(y1-y0)/2);
    }else{
      path.setAttribute('points',points.map(point=>point.join(',')).join(' '));
    }
  }
  function markPosition(event){
    const box=get('snapshot').getBoundingClientRect();
    return [clamp((event.clientX-box.left)/box.width),clamp((event.clientY-box.top)/box.height)];
  }
  function renderTextBox(){
    const note=scene?.textBox;
    textBox.hidden=!note?.text;
    get('moveTextBox').hidden=!host;
    if(!note?.text){
      get('textBoxContent').textContent='';
      return;
    }
    const left=note.x*100,top=note.y*100;
    textBox.style.left='clamp(0px,calc('+left+'% - min(37.5%,140px)),calc(100% - min(75%,280px)))';
    textBox.style.top=top+'%';
    textBox.style.transform='translateY(-'+top+'%)';
    get('textBoxContent').textContent=note.text;
  }
  function resetAnnotations(){
    draft=undefined;textDrag=undefined;ink.replaceChildren();
    delete scene.mark;delete scene.textBox;
    get('note').value='';get('textBoxInput').value='';
    render();
  }
  function sendTextBox(){
    send({type:'text-box',id:scene.id,note:scene.textBox});
    renderTextBox();
  }
  const render = () => {
    get('freeze').hidden=!host;
    get('cameraLight').hidden=!host;
    get('cameraLight').disabled=!channel || Boolean(lightRequest);
    get('cameraLight').textContent=lightOn?'Kameralicht ausschalten':'Kameralicht einschalten';
    get('lightNotice').hidden=Boolean(jwt)||Boolean(self);
    get('guestCameras').hidden=!(mobileGuest && self);
    get('rearCamera').disabled=switchingCamera;
    get('frontCamera').disabled=switchingCamera;
    get('freeze').disabled=!secure || !channel;
    get('annotation').hidden=!scene;
    get('resume').hidden=!scene||!host;
    get('annotationTools').hidden=!scene||!host;
    get('noteForm').hidden=!scene||!host||tool!=='arrow';
    get('textBoxForm').hidden=!scene||!host||tool!=='text';
    get('marker').hidden=!scene?.mark;
    frame.toggleAttribute('data-drawing',Boolean(scene&&host&&tool!=='arrow'));
    if(drawingScene!==scene?.id){
      drawingScene=scene?.id;draft=undefined;textDrag=undefined;ink.replaceChildren();
    }
    renderTextBox();
    if (!scene) {
      get('snapshot').removeAttribute('src');
      get('note').value='';
      get('textBoxInput').value='';
    }
    if (!scene?.mark) get('caption').textContent='';
    if (!scene) return;
    const src='data:image/jpeg;base64,'+scene.image;
    if(get('snapshot').getAttribute('src')!==src) get('snapshot').src=src;
    if(scene.mark) {
      const {x,y,text}=scene.mark;
      get('marker').style.left=x*100+'%';
      get('marker').style.top=y*100+'%';
      get('caption').textContent=text;
    }
  };
  async function syncModerator(){
    if(!jwt||!self)return;
    try{
      const {rooms}=await api.getRoomsInfo();
      const participant=rooms.find(room=>room.isMainRoom)?.participants.find(person=>person.id===self);
      if(participant){
        host=participant.role==='moderator';
        render();
      }
    }catch(_){}
  }
  api.on('videoConferenceJoined',e=>{
    self=e.id;
    const app=meetingFrame.contentWindow.APP;
    const room=app?.conference?._room;
    if(!room?.isE2EESupported?.() || !app?.store){stopUnprotected();return;}
    const connected=()=>room.getMediaSessions().some(session=>
      session.peerconnection.peerconnection.connectionState==='connected');
    const requiresSettledMedia=androidWebView&&!jwt;
    const stateReady=()=>Boolean(room.isE2EEEnabled() && app.store.getState()['features/e2ee']?.enabled
        && (!requiresSettledMedia || connected()));
    const verifyEncryption=()=>{
      if (secure) {
        if (!room.isE2EEEnabled()) stopUnprotected();
        return;
      }
      if (!stateReady()) {
        clearTimeout(readyTimer);
        readyTimer=undefined;
        return;
      }
      if (readyTimer) return;
      // The WebView joins before all Jitsi conference state listeners have settled.
      // Keep the devices muted until that transition has completed.
      readyTimer=setTimeout(()=>{
        readyTimer=undefined;
        if(!stateReady())return;
        clearTimeout(encryptionDeadline);
        clearInterval(transportWatch);
        secure=true;
        meetingFrame.inert=false;
        channel=Boolean(room.rtc?._channel?.isOpen?.());
        if(!jwt) void api.isVideoMuted().then(muted=>{
          if(muted&&secure&&room.isE2EEEnabled())api.executeCommand('toggleVideo');
        }).catch(()=>status('Die Kamera konnte nicht automatisch gestartet werden.'));
        render();
      },750);
    };
    stopEncryptionWatch=app.store.subscribe(verifyEncryption);
    encryptionDeadline=setTimeout(()=>{if(!secure)stopUnprotected();},requiresSettledMedia?18000:8000);
    if (requiresSettledMedia) {
      // Older WebViews replace the peer connection when enabling encoded streams.
      // Let Jicofo acknowledge the initial muted session before requesting the replacement.
      const sessionStarted='conference.media_session.started';
      let requested=false;
      const begin=()=>{
        if(requested)return;
        requested=true;
        room.off(sessionStarted,begin);
        if (!secure) api.executeCommand('toggleE2EE',true);
      };
      room.on(sessionStarted,begin);
      const unsubscribe=stopEncryptionWatch;
      stopEncryptionWatch=()=>{room.off(sessionStarted,begin);unsubscribe();};
      const checkTransport=()=>{
        // The session event may have fired before the iframe reported that it joined.
        if(connected())begin();
        verifyEncryption();
      };
      transportWatch=setInterval(checkTransport,200);
      checkTransport();
    } else {
      api.executeCommand('toggleE2EE',true);
    }
    verifyEncryption();
    if (twoCoreSupporter) {
      api.executeCommand('setVideoQuality',360);
      stopBackgroundBudget?.();
      startBackgroundBudget();
    }
    render();
    void syncModerator();
  });
  api.on('participantRoleChanged',e=>{
    if (e.id===self || (jwt && !self && e.role==='moderator')) {
      host=Boolean(jwt && e.role==='moderator'); render();
    }
  });
  api.on('dataChannelOpened',()=>{channel=true;render();void syncModerator();});
  api.on('dataChannelClosed',()=>{channel=false;render();});
  api.on('participantLeft',e=>{
    if (e.id===lightController) resetLight();
    if (e.id===lightPeer) {
      clearTimeout(lightRequest?.timeout);
      lightRequest=undefined;lightPeer=undefined;lightOn=false;render();
    }
    if(e.id===author || e.id===scene?.peerId){
      scene=undefined;incoming=undefined;author=undefined;render();
    }
  });
  api.on('videoConferenceLeft',()=>{
    stopBackgroundBudget?.();
    stopBackgroundBudget=undefined;
    resetLight();
    clearTimeout(lightRequest?.timeout);
    lightRequest=undefined;lightOn=false;lightPeer=undefined;
    get('lightNotice').hidden=true;
    self=undefined;host=false;channel=false;scene=undefined;incoming=undefined;author=undefined;
    status('Video-Hilfe beendet');render();get('lightNotice').hidden=true;
    get('sendInvitation').hidden=true;
  });
  if (navigator.userAgent.includes(' OpsLinXAndroidVAS/1')) {
    api.once('readyToClose', () => location.replace('/vas/return-to-app'));
  }
  get('invite').onclick=async()=>{
    const link=location.origin+'/vas/join/'+(shortCode || code)+'#vasKey='+secret;
    try{await navigator.clipboard.writeText(link);get('inviteStatus').textContent='Handy-Link kopiert.';}
    catch(_){get('inviteStatus').textContent=link;}
  };
  get('deviceInvitation').onsubmit=async event=>{
    event.preventDefault();
    if (!secure || !jwt || !shortCode || get('sendInvitation').hidden) return;
    const device=get('inviteDevice').value.replace(/[\s\u200b\u2060\ufeff]/g,'');
    const result=get('inviteStatus'),button=get('sendInvite');
    if(!/^[A-Za-z0-9_-]{6,40}$/.test(device)){
      result.textContent='Bitte die Geräte-ID vom Kundenhandy eingeben.';
      return;
    }
    button.disabled=true;
    try {
      const sendRequest=body=>fetch('/vas/invite',{method:'POST',cache:'no-store',
        headers:{'Content-Type':'application/json','Authorization':'Bearer '+jwt},
        body:JSON.stringify({id:device,purpose:'vas',...body}),signal:AbortSignal.timeout(8000)});
      const lookup=await sendRequest({action:'key'});
      const registration=await lookup.json();
      if(!lookup.ok || !registration.key_certificate) {
        result.textContent='Die App am Kundenhandy öffnen und erneut senden.';
        return;
      }
      const publicKey=await verifyInviteKey(registration.key_certificate,device,'vas');
      const sealed=await sealInvitation(secret,device,'vas',shortCode,publicKey);
      if(!secure)return;
      const response=await sendRequest({sealed});
      const reply=await response.json();
      const reasons={
        offline:'Auf dem Handy bitte g3 OpsLinX öffnen und erneut senden.',
        busy:'Auf dem Handy wartet bereits eine andere Video-Hilfe.',
        rate:'Bitte kurz warten, bevor du eine weitere Einladung sendest.',
      };
      result.textContent=response.ok && reply.queued
        ? 'Einladung gesendet. Der Kunde kann in der App beitreten.'
        : reasons[reply.error] || 'Die Einladung konnte nicht gesendet werden.';
    } catch (_) {
      result.textContent='Die Einladung konnte nicht gesendet werden.';
    } finally {
      button.disabled=false;
    }
  };
  get('freeze').onclick=async()=>{
    if(!host||!channel||!secure)return;
    const iframe=api.getIFrame();
    const tracks=iframe.contentWindow?.APP?.store?.getState()['features/base/tracks'] || [];
    const guestCamera=tracks.find(track=>!track.local && track.mediaType==='video'
      && track.videoType!=='desktop' && track.jitsiTrack?.getTrack?.()?.readyState==='live');
    const guestTrack=guestCamera?.jitsiTrack?.getTrack?.();
    const guestId=guestCamera?.participantId ?? guestCamera?.jitsiTrack?.getParticipantId?.();
    if(!guestTrack){status('Das Kamerabild des Gastes ist noch nicht verfügbar.');return;}
    const session=self;
    const remote=document.createElement('video');
    remote.muted=true;
    remote.playsInline=true;
    remote.srcObject=new MediaStream([guestTrack]);
    const canvas=document.createElement('canvas');
    let image;
    let deadline;
    try {
      const playing=await Promise.race([
        remote.play().then(()=>true),
        new Promise(resolve=>{deadline=setTimeout(()=>resolve(false),2500);}),
      ]);
      if(!host||!channel||!secure||self!==session||guestTrack.readyState!=='live')return;
      if(!playing||remote.readyState<2||!remote.videoWidth||!remote.videoHeight){
        status('Das Kamerabild des Gastes ist noch nicht verfügbar.');return;
      }
      for(const limit of [720,480]){
        const scale=Math.min(1,limit/Math.max(remote.videoWidth,remote.videoHeight));
        canvas.width=Math.round(remote.videoWidth*scale);canvas.height=Math.round(remote.videoHeight*scale);
        canvas.getContext('2d').drawImage(remote,0,0,canvas.width,canvas.height);
        image=canvas.toDataURL('image/jpeg',.62).split(',')[1];
        if(image&&image.length<=90000)break;
      }
    } catch (_) {
      if(self===session)status('Standbild konnte nicht aufgenommen werden.');
      return;
    } finally {
      clearTimeout(deadline);
      remote.pause();
      remote.srcObject=null;
      canvas.width=canvas.height=0;
    }
    if(!image||image.length>90000){status('Standbild konnte nicht geteilt werden.');return;}
    scene={id:crypto.randomUUID(),image,peerId:guestId};
    const parts=Math.ceil(image.length/imageChunkSize);
    for(let i=0;i<parts;i++) send({type:'image',id:scene.id,i,parts,data:image.slice(i*imageChunkSize,(i+1)*imageChunkSize)});
    render();
  };
  for(const button of tools) button.onclick=()=>{
    tool=button.dataset.tool;
    for(const option of tools)option.setAttribute('aria-pressed',String(option===button));
    render();
  };
  get('resetAnnotations').onclick=()=>{
    if(!host||!scene)return;
    send({type:'reset-marks',id:scene.id});
    resetAnnotations();
  };
  frame.onclick=event=>{
    if(!host||!scene||textBox.contains(event.target))return;
    const [x,y]=markPosition(event);
    if(tool==='text'){
      const text=get('textBoxInput').value.trim();
      if(!text){get('textBoxInput').focus();return;}
      scene.textBox={x,y,text};
      sendTextBox();
    }else if(tool==='arrow'){
      scene.mark={x,y,text:get('note').value.trim()};
      send({type:'mark',id:scene.id,mark:scene.mark});render();
    }
  };
  get('snapshot').draggable=false;
  frame.onpointerdown=event=>{
    if(!host||!scene||draft||!event.isPrimary||event.button!==0||
        (tool!=='ellipse'&&tool!=='freehand')||textBox.contains(event.target)||
        ink.childElementCount>=maxStrokes)return;
    frame.setPointerCapture(event.pointerId);
    const point=markPosition(event).map(value=>Math.round(value*1000));
    draft={pointer:event.pointerId,kind:tool,points:[point,point],path:newStroke(tool)};
    ink.append(draft.path);
    paintStroke(draft.path,draft.kind,draft.points);
  };
  frame.onpointermove=event=>{
    if(draft?.pointer!==event.pointerId)return;
    const point=markPosition(event).map(value=>Math.round(value*1000));
    const {kind,path}=draft;
    if(kind==='ellipse'){
      draft.points[1]=point;
    }else{
      const [x,y]=draft.points.at(-1);
      if(Math.abs(point[0]-x)+Math.abs(point[1]-y)<4)return;
      if(draft.points.length>=maxPoints)draft.points=draft.points.filter((_,i)=>i%2===0);
      draft.points.push(point);
    }
    paintStroke(path,kind,draft.points);
  };
  frame.onpointerup=event=>{
    if(draft?.pointer!==event.pointerId)return;
    frame.onpointermove(event);
    const {kind,points,path}=draft;
    draft=undefined;
    if(points.every(([x,y])=>x===points[0][0]&&y===points[0][1])){path.remove();return;}
    send({type:'stroke',id:scene.id,kind,points});
  };
  frame.onpointercancel=frame.onlostpointercapture=event=>{
    if(draft?.pointer===event.pointerId){draft.path.remove();draft=undefined;}
  };
  get('textBoxForm').onsubmit=event=>{
    event.preventDefault();
    if(!host||!scene)return;
    const text=get('textBoxInput').value.trim();
    if(!text)return;
    scene.textBox={x:.5,y:.5,...scene.textBox,text};
    sendTextBox();
  };
  const moveTextBox=get('moveTextBox');
  moveTextBox.onpointerdown=event=>{
    if(!host||!scene?.textBox||!event.isPrimary||event.button!==0)return;
    event.stopPropagation();
    moveTextBox.setPointerCapture(event.pointerId);
    textDrag={pointer:event.pointerId,start:markPosition(event),note:{...scene.textBox}};
  };
  moveTextBox.onpointermove=event=>{
    if(textDrag?.pointer!==event.pointerId)return;
    const [x,y]=markPosition(event),[startX,startY]=textDrag.start;
    scene.textBox.x=clamp(textDrag.note.x+x-startX);
    scene.textBox.y=clamp(textDrag.note.y+y-startY);
    renderTextBox();
  };
  moveTextBox.onpointerup=moveTextBox.onpointercancel=moveTextBox.onlostpointercapture=event=>{
    if(textDrag?.pointer!==event.pointerId)return;
    textDrag=undefined;
    sendTextBox();
  };
  get('noteForm').onsubmit=e=>{
    e.preventDefault();
    if(!host||!scene?.mark){status('Setze zuerst einen Pfeil auf das Standbild.');return;}
    scene.mark.text=get('note').value.trim();
    send({type:'mark',id:scene.id,mark:scene.mark});render();
  };
  get('resume').onclick=()=>{
    if(!host||!scene)return;
    send({type:'clear',id:scene.id});scene=undefined;render();
  };
  async function receive({senderInfo,eventData}){
    const id=senderInfo?.id,text=eventData?.text;
    if(!secure||!id||typeof text!=='string'||text.length>6200)return;
    const packet=JSON.parse(text);
    if((packet.to!==''&&packet.to!==self)||receivedNonces.has(packet.iv)||receivedNonces.size>=16384)return;
    const m=await openAnnotation(annotation,binding(id,packet.to),packet);
    receivedNonces.add(packet.iv);
    if(m?.ar!==1||typeof m.id!=='string'||!/^[a-f0-9-]{36}$/.test(m.id))return;
    if(host){
      if(m.type==='torch-reset' && id===lightPeer){
        clearTimeout(lightRequest?.timeout);lightRequest=undefined;lightOn=false;render();
      }
      if(m.type==='torch-status'&&id===lightPeer&&m.id===lightRequest?.id){
        clearTimeout(lightRequest.timeout);lightRequest=undefined;
        lightOn=m.on===true;
        const messages={ok:lightOn?'Kameralicht eingeschaltet.':'Kameralicht ausgeschaltet.',
          consent:'Der Gast muss zuerst der Video-Hilfe beitreten.',
          unsupported:'Das Kameralicht steht auf dieser Kamera nicht zur Verfügung.',
          failed:'Das Kameralicht konnte nicht umgeschaltet werden.'};
        status(messages[m.result]||messages.failed);render();
      }
      return;
    }
    if (m.type==='torch' && typeof m.on==='boolean'){
      const {rooms}=await api.getRoomsInfo();
      if(!rooms.find(r=>r.isMainRoom)?.participants.some(p=>p.id===id&&p.role==='moderator'))return;
      let result='ok', on=false;
      if(!m.on){resetLight();}
      else if(!self || jwt){result='consent';}
      else {
        const track=switchingCamera?undefined:localVideoTrack();
        const torch=track?.getCapabilities?.().torch;
        if(!track || !(torch===true || (Array.isArray(torch) && torch.includes(true)))){result='unsupported';}
        else try {
          lightTrack=track;lightController=id;
          await track.applyConstraints({advanced:[{torch:true}]});
          if(!self || lightController!==id){
            await track.applyConstraints({advanced:[{torch:false}]});
            result='consent';
          }else if(track.getSettings?.().torch===false){
            resetLight();result='failed';
          }else{
            on=true;
          }
        }catch(_){resetLight();result='failed';}
      }
      if(result==='ok') status(on?'Kameralicht durch Support eingeschaltet.':'Kameralicht aus.');
      sendTo(id,{type:'torch-status',id:m.id,on,result});
      return;
    }

    if(author!==id){
      const {rooms}=await api.getRoomsInfo();
      if(!rooms.find(r=>r.isMainRoom)?.participants.some(p=>p.id===id&&p.role==='moderator'))return;
      author=id;incoming=undefined;
    }
    if(m.type==='image'&&Number.isInteger(m.parts)&&m.parts>0&&m.parts<=Math.ceil(90000/imageChunkSize)&&Number.isInteger(m.i)&&m.i>=0&&m.i<m.parts&&typeof m.data==='string'&&m.data.length<=imageChunkSize&&/^[A-Za-z0-9+/=]+$/.test(m.data)){
      if(m.i===0)incoming={id:m.id,parts:m.parts,pieces:[]};
      if(!incoming||incoming.id!==m.id||incoming.parts!==m.parts||incoming.pieces.length!==m.i)return;
      incoming.pieces.push(m.data);
      if(incoming.pieces.length===incoming.parts){scene={id:m.id,image:incoming.pieces.join('')};incoming=undefined;render();}
    }
    if(scene?.id!==m.id)return;
    const p=m.mark;
    if(m.type==='mark'&&p&&Number.isFinite(p.x)&&p.x>=0&&p.x<=1&&Number.isFinite(p.y)&&p.y>=0&&p.y<=1&&typeof p.text==='string'&&p.text.length<=160){scene.mark=p;render();}
    if(m.type==='stroke'&&(m.kind==='ellipse'||m.kind==='freehand')&&Array.isArray(m.points)&&
        m.points.length>=2&&m.points.length<=(m.kind==='ellipse'?2:maxPoints)&&
        m.points.every(point=>Array.isArray(point)&&point.length===2&&
          point.every(value=>Number.isInteger(value)&&value>=0&&value<=1000))&&ink.childElementCount<maxStrokes){
      const path=newStroke(m.kind);
      paintStroke(path,m.kind,m.points);
      ink.append(path);
    }
    const note=m.note;
    if(m.type==='text-box'&&note&&Number.isFinite(note.x)&&note.x>=0&&note.x<=1&&
        Number.isFinite(note.y)&&note.y>=0&&note.y<=1&&typeof note.text==='string'&&note.text.length<=600){
      scene.textBox={x:note.x,y:note.y,text:note.text};renderTextBox();
    }
    if(m.type==='reset-marks')resetAnnotations();
    if(m.type==='clear'){scene=undefined;render();}
  }
  render();
  get('sendInvitation').hidden = !jwt;
  api.on('endpointTextMessageReceived', e => {
    queue=queue.then(()=>receive(e.data || e)).catch(()=>{});
  });
})();
