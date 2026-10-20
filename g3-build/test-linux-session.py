"""Exercise an authenticated live desktop between disposable Linux containers."""
from pathlib import Path
import subprocess,hashlib,json,secrets,time,re,os
root=Path.cwd();inputs=root/'input';out=root/'session-evidence';out.mkdir(exist_ok=True)
record=json.loads((inputs/'validation.json').read_text());package=inputs/record['files'][0]['file'];assert hashlib.sha256(package.read_bytes()).hexdigest()==record['files'][0]['sha256']
name='g3-session-'+secrets.token_hex(5);image=name+'-image';target=name+'-target';viewer=name+'-viewer';password=secrets.token_urlsafe(24)
print('::add-mask::'+password,flush=True)
def run(args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def execute(container,args,**kwargs):return run(['docker','exec',*(['-i'] if 'input' in kwargs else []),container,*args],**kwargs)
docker=root/'session-container';docker.mkdir(exist_ok=True)
(docker/'Dockerfile').write_text("FROM ubuntu:22.04\nCOPY client.deb /tmp/client.deb\nRUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/client.deb xvfb xauth dbus-x11 imagemagick x11-xserver-utils xdotool openbox libegl1-mesa libgles2-mesa && rm /tmp/client.deb\nENV DISPLAY=:99 XDG_RUNTIME_DIR=/tmp/g3-runtime\nCOPY start.sh /start.sh\nCMD [\"bash\",\"/start.sh\"]\n")
import shutil
shutil.copy2(package,docker/'client.deb')
(docker/'start.sh').write_text("#!/bin/bash\nset -e\nmkdir -p /tmp/g3-runtime; chmod 700 /tmp/g3-runtime\nXvfb :99 -screen 0 1280x1024x24 >/tmp/xvfb.log 2>&1 &\nsleep 2\nexec dbus-run-session -- bash -ec 'openbox >/tmp/wm.log 2>&1 & /usr/bin/g3fernwartung >/tmp/gui.log 2>&1 & wait'\n")
result={'architecture':record['arch'],'package_sha256':record['files'][0]['sha256'],'passed':False,'customer_devices_used':False}
try:
 run(['docker','build','-t',image,str(docker)],stdout=subprocess.DEVNULL)
 for container in [target,viewer]:run(['docker','run','-d','--name',container,image],stdout=subprocess.DEVNULL)
 time.sleep(12)
 response=execute(target,['/usr/bin/g3fernwartung','--password-stdin'],input=password+'\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30);assert 'confirmed' in response.stdout.lower(),'Permanent password confirmation missing'
 peer=execute(target,['/usr/bin/g3fernwartung','--get-id'],text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30).stdout.strip();assert re.fullmatch(r'[0-9]{9,10}',peer),'Target ID unavailable';print('Target generated its own test identity',flush=True)
 # Hide the target's client window so the transmitted desktop contains no credentials.
 execute(target,['bash','-c','for w in $(xdotool search --class g3fernwartung 2>/dev/null || xdotool search --class rustdesk 2>/dev/null); do xdotool windowunmap "$w" || true; done'])
 execute(viewer,['bash','-c','/usr/bin/g3fernwartung --connect "$1" --password "$2" >/tmp/connect.log 2>&1 &','g3-test',peer,password])
 def color_fraction(color):
  screenshot=out/'frame.png';execute(viewer,['import','-window','root','/tmp/frame.png']);run(['docker','cp',viewer+':/tmp/frame.png',str(screenshot)],stdout=subprocess.DEVNULL)
  pixels=subprocess.check_output(['convert',str(screenshot),'-depth','8','RGB:-']);matches=sum(1 for i in range(0,len(pixels),3) if all(abs(pixels[i+j]-color[j])<=12 for j in range(3)));return matches/(len(pixels)/3)
 fractions=[]
 for hexcolor,color in [('#6541ac',(101,65,172)),('#1a9c44',(26,156,68))]:
  execute(target,['xsetroot','-solid',hexcolor]);fraction=0
  for attempt in range(18):
   time.sleep(3);fraction=color_fraction(color)
   if fraction>.12:break
  fractions.append(round(fraction,4));assert fraction>.12,'Authenticated live desktop frame not received'
 result.update(passed=True,checks=['separate native clients and identities','permanent password confirmed by target service','authenticated connection via configured rendezvous','two changed desktop frames received'],frame_fractions=fractions)
 print('PASS: authenticated connection and two live desktop changes',flush=True)
finally:
 # Do not publish screenshots or test credentials, including temporary UI passwords.
 (out/'frame.png').unlink(missing_ok=True)
 (out/'session-result.json').write_text(json.dumps(result,indent=2))
 for container in [target,viewer]:subprocess.run(['docker','rm','-f',container],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 subprocess.run(['docker','rmi','-f',image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
