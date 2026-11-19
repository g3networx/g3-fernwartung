(async () => {
  'use strict';
  const code = new URL(location.href).searchParams.get('room')?.toLowerCase();
  if (!/^[a-f0-9]{32}$/.test(code || '')) return;
  const jwt = new URLSearchParams(location.hash.slice(1)).get('jwt');
  const twoCoreSupporter = Boolean(jwt) && navigator.hardwareConcurrency <= 2;
  const lightSupporterVideo = Boolean(jwt)
    && (navigator.hardwareConcurrency <= 4 || navigator.deviceMemory <= 4);
  const supporterCamera = lightSupporterVideo
    ? {facingMode:{ideal:'user'},height:{ideal:180,max:180},width:{ideal:320,max:320},frameRate:{ideal:20,max:20}}
    : {facingMode:{ideal:'user'},height:{ideal:360,max:540},width:{ideal:640,max:960},frameRate:{ideal:20,max:24}};
  if (jwt) history.replaceState(null, '', location.pathname + location.search);
  const get = id => document.getElementById(id);
  get('join').hidden = true;
  get('controls').hidden = false;
  const status = text => { get('status').textContent = text; };
  status('Raumcode: ' + code);
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
    parentNode:get('call'),roomName:code,jwt,
    interfaceConfigOverwrite:twoCoreSupporter ? {DISABLE_VIDEO_BACKGROUND:true} : undefined,
    configOverwrite:{
      disableDeepLinking:true,
      startWithVideoMuted:Boolean(jwt),
      ...(codecPreferenceOrder && {
        videoQuality:{codecPreferenceOrder},
        p2p:{codecPreferenceOrder},
      }),
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
  const localVideoTrack=()=>{
    const frame=api.getIFrame().contentDocument;
    return [...(frame?.querySelectorAll('video') || [])]
      .filter(video=>!/^remoteVideo_/i.test(video.id))
      .flatMap(video=>video.srcObject?.getVideoTracks?.() || [])
      .find(track=>track.readyState==='live' && track.getCapabilities?.().torch);
  };
  function resetLight(){
    const track=lightTrack;
    lightTrack=undefined;
    lightController=undefined;
    if (track?.readyState==='live') {
      void track.applyConstraints({advanced:[{torch:false}]}).catch(()=>{});
    }
  }
  const sendTo=(peer,data)=>api.executeCommand(
    'sendEndpointTextMessage',peer,JSON.stringify({ar:1,...data})
  );
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
      api.executeCommand('sendEndpointTextMessage','',JSON.stringify({ar:1,...data}));
      await new Promise(resolve=>setTimeout(resolve,180));
    });
  };
  const render = () => {
    get('freeze').hidden=!host;
    get('cameraLight').hidden=!host;
    get('cameraLight').disabled=!channel || Boolean(lightRequest);
    get('cameraLight').textContent=lightOn?'Kameralicht ausschalten':'Kameralicht einschalten';
    get('lightNotice').hidden=Boolean(jwt)||Boolean(self);
    get('freeze').disabled=!channel;
    get('invite').hidden=!host;
    get('annotation').hidden=!scene;
    get('resume').hidden=!scene||!host;
    get('noteForm').hidden=!scene||!host;
    get('marker').hidden=!scene?.mark;
    if (!scene) { get('snapshot').removeAttribute('src'); return; }
    const src='data:image/jpeg;base64,'+scene.image;
    if(get('snapshot').getAttribute('src')!==src) get('snapshot').src=src;
    if(scene.mark) {
      const {x,y,text}=scene.mark;
      get('marker').style.left=x*100+'%';
      get('marker').style.top=y*100+'%';
      get('caption').textContent=text;
    }
  };
  api.on('videoConferenceJoined',e=>{
    self=e.id;
    if (twoCoreSupporter) {
      api.executeCommand('setVideoQuality',360);
      stopBackgroundBudget?.();
      startBackgroundBudget();
    }
    render();
  });
  api.on('participantRoleChanged',e=>{
    if (e.id===self || (jwt && !self && e.role==='moderator')) {
      host=Boolean(jwt && e.role==='moderator'); render();
    }
  });
  api.on('dataChannelOpened',()=>{channel=true;render();});
  api.on('participantLeft',e=>{
    if (e.id===lightController) resetLight();
    if (e.id===lightPeer) {
      clearTimeout(lightRequest?.timeout);
      lightRequest=undefined;lightPeer=undefined;lightOn=false;render();
    }
    if(e.id===author){scene=undefined;incoming=undefined;author=undefined;render();}
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
  });
  get('invite').onclick=async()=>{
    try{await navigator.clipboard.writeText(location.origin+'/vas/?room='+code);status('Einladung kopiert. Raumcode: '+code);}
    catch(_){status('Raumcode: '+code);}
  };
  get('freeze').onclick=()=>{
    if(!host||!channel)return;
    const remote=Array.from(api.getIFrame().contentDocument.querySelectorAll('video'))
      .find(v=>/^remoteVideo_/i.test(v.id)&&v.videoWidth&&v.readyState>=2);
    if(!remote){status('Das Kamerabild des Gastes ist noch nicht verfügbar.');return;}
    const canvas=document.createElement('canvas');
    const scale=Math.min(1,480/Math.max(remote.videoWidth,remote.videoHeight));
    canvas.width=Math.round(remote.videoWidth*scale);canvas.height=Math.round(remote.videoHeight*scale);
    canvas.getContext('2d').drawImage(remote,0,0,canvas.width,canvas.height);
    const image=canvas.toDataURL('image/jpeg',.62).split(',')[1];
    if(!image||image.length>90000){status('Standbild konnte nicht geteilt werden.');return;}
    scene={id:crypto.randomUUID(),image};
    const parts=Math.ceil(image.length/5000);
    for(let i=0;i<parts;i++) send({type:'image',id:scene.id,i,parts,data:image.slice(i*5000,(i+1)*5000)});
    render();
  };
  get('frame').onclick=e=>{
    if(!host||!scene)return;
    const box=get('snapshot').getBoundingClientRect();
    const clamp=n=>Math.max(0,Math.min(1,n));
    scene.mark={x:clamp((e.clientX-box.left)/box.width),y:clamp((e.clientY-box.top)/box.height),text:get('note').value.trim()};
    send({type:'mark',id:scene.id,mark:scene.mark});render();
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
    if(!id||typeof text!=='string'||text.length>6200)return;
    let m;
    try{m=JSON.parse(text);}catch(_){return;}
    if(m?.ar!==1||typeof m.id!=='string'||!/^[a-f0-9-]{36}$/.test(m.id))return;
    if(host){
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
        const track=localVideoTrack();
        if(!track){result='unsupported';}
        else try {
          lightTrack=track;lightController=id;
          await track.applyConstraints({advanced:[{torch:true}]});
          if(!self || lightController!==id){
            await track.applyConstraints({advanced:[{torch:false}]});
            result='consent';
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
    if(m.type==='image'&&Number.isInteger(m.parts)&&m.parts>0&&m.parts<=18&&Number.isInteger(m.i)&&m.i>=0&&m.i<m.parts&&typeof m.data==='string'&&m.data.length<=5000&&/^[A-Za-z0-9+/=]+$/.test(m.data)){
      if(m.i===0)incoming={id:m.id,parts:m.parts,pieces:[]};
      if(!incoming||incoming.id!==m.id||incoming.parts!==m.parts||incoming.pieces.length!==m.i)return;
      incoming.pieces.push(m.data);
      if(incoming.pieces.length===incoming.parts){scene={id:m.id,image:incoming.pieces.join('')};incoming=undefined;render();}
    }
    if(scene?.id!==m.id)return;
    const p=m.mark;
    if(m.type==='mark'&&p&&Number.isFinite(p.x)&&p.x>=0&&p.x<=1&&Number.isFinite(p.y)&&p.y>=0&&p.y<=1&&typeof p.text==='string'&&p.text.length<=160){scene.mark=p;render();}
    if(m.type==='clear'){scene=undefined;render();}
  }
  render();
  api.on('endpointTextMessageReceived', e => {
    queue=queue.then(()=>receive(e.data || e)).catch(()=>{});
  });
})();
