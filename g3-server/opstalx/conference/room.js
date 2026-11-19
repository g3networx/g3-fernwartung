(() => {
  'use strict';
  const code = new URL(location.href).searchParams.get('room')?.toLowerCase();
  if (!/^[a-f0-9]{32}$/.test(code || '')) return;
  const jwt = new URLSearchParams(location.hash.slice(1)).get('jwt');
  if (jwt) history.replaceState(null, '', location.pathname + location.search);
  const get = id => document.getElementById(id);
  get('join').hidden = true;
  get('controls').hidden = false;
  const status = text => { get('status').textContent = text; };
  status('Raumcode: ' + code);
  const api = new JitsiMeetExternalAPI(location.host,{
    parentNode:get('call'),roomName:code,jwt,
    configOverwrite:{disableDeepLinking:true,constraints:{video:{facingMode:{ideal:jwt?'user':'environment'},height:{ideal:720}}}}
  });
  let self, host=false, channel=false, scene, incoming, author;
  let queue=Promise.resolve();
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
  api.on('videoConferenceJoined',e=>{ self=e.id; });
  api.on('participantRoleChanged',e=>{
    if (e.id===self || (jwt && !self && e.role==='moderator')) {
      host=Boolean(jwt && e.role==='moderator'); render();
    }
  });
  api.on('dataChannelOpened',()=>{channel=true;render();});
  api.on('participantLeft',e=>{
    if(e.id===author){scene=undefined;incoming=undefined;author=undefined;render();}
  });
  api.on('videoConferenceLeft',()=>{
    self=undefined;host=false;channel=false;scene=undefined;incoming=undefined;author=undefined;
    status('Video-Hilfe beendet');render();
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
    if(!id||typeof text!=='string'||text.length>6200||host)return;
    let m;
    try{m=JSON.parse(text);}catch(_){return;}
    if(m?.ar!==1||typeof m.id!=='string'||!/^[a-f0-9-]{36}$/.test(m.id))return;
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
  api.on('endpointTextMessageReceived', e => {
    queue=queue.then(()=>receive(e.data || e)).catch(()=>{});
  });
})();
