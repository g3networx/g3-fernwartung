"""Declarative Windows Installer packages; no shell/script installation actions."""
import hashlib,json,re,shutil,subprocess,uuid,os
from pathlib import Path
import xml.etree.ElementTree as E

ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT.parent
WIX=Path(os.environ['WIX'])/'bin'
NS='http://schemas.microsoft.com/wix/2006/wi';FW='http://schemas.microsoft.com/wix/FirewallExtension';UTIL='http://schemas.microsoft.com/wix/UtilExtension'
E.register_namespace('',NS);E.register_namespace('fire',FW);E.register_namespace('util',UTIL)
def tag(parent,name,**attrs):return E.SubElement(parent,'{'+NS+'}'+name,{k:str(v) for k,v in attrs.items()})
def guid(value):return str(uuid.uuid5(uuid.NAMESPACE_URL,'https://g3networx.de/fernwartung/msi/'+value)).upper()
version='1.5.0-g3.29'
payload=ROOT/'flutter/build/windows/x64/runner/Release'
build_date=re.search(r'pub const BUILD_DATE: &str = "([^"]+)";', (ROOT/'src/version.rs').read_text(encoding='utf-8')).group(1)
results={}
(payload/'g3-update-session.lock').touch(exist_ok=True)
for kind,app,title in [('windows','g3Fernwartung','g3 OpsLinX'),('host','g3Host','g3 OpsLinX Host')]:
    folder=ROOT/'g3-build/msi'/kind;folder.mkdir(parents=True,exist_ok=True)
    exe=folder/(app+'.exe')
    shutil.copy2(ROOT/'outputs/g3Host.exe' if kind=='host' else payload/'rustdesk.exe',exe)
    if kind=='host':shutil.copy2(payload/'rustdesk.exe',folder/'g3Host-ui.exe')
    wix=E.Element('{'+NS+'}Wix')
    product=tag(wix,'Product',Id=guid(kind+'/'+version),Name=title,Language=1031,Version='1.5.29',Manufacturer='g3 NetworX UG & Co. KG',UpgradeCode=guid(kind+'/upgrade'))
    tag(product,'Package',Id='*',InstallerVersion=500,Compressed='yes',InstallScope='perMachine',Platform='x64',Description=title)
    tag(product,'MajorUpgrade',DowngradeErrorMessage='Eine neuere Version ist bereits installiert.',Schedule='afterInstallInitialize')
    tag(product,'MediaTemplate',EmbedCab='yes',CompressionLevel='medium')
    tag(product,'Property',Id='ARPCOMMENTS',Value=title+' – Installation, Reparatur und Entfernung über Windows Installer.')
    tag(product,'Property',Id='ARPURLINFOABOUT',Value='https://rust.g3nx.net/client')
    tag(product,'Property',Id='REBOOT',Value='ReallySuppress')
    tag(product,'Property',Id='MSIRESTARTMANAGERCONTROL',Value='Disable')
    tag(product,'Property',Id='G3_BOOTSTRAP_CLOSED',Secure='yes')
    tag(product,'Condition',Message='Bitte das g3-Installationsprogramm (.exe) verwenden. Es schützt laufende Fernwartungen.').text='REMOVE~=\"ALL\" OR G3_BOOTSTRAP_CLOSED = 1'

    tag(product,'Property',Id='REINSTALLMODE',Value='amus')
    tag(product,'Condition',Message='64-Bit Windows erforderlich.').text='VersionNT64'
    target=tag(product,'Directory',Id='TARGETDIR',Name='SourceDir')
    pf=tag(target,'Directory',Id='ProgramFiles64Folder');install=tag(pf,'Directory',Id='INSTALLDIR',Name=app)
    tag(target,'Directory',Id='System64Folder')
    programs=tag(target,'Directory',Id='ProgramMenuFolder');menu=tag(programs,'Directory',Id='ApplicationProgramsFolder',Name=title)
    feature=tag(product,'Feature',Id='Complete',Title=title,Level=1)
    dirs={Path('.'):install}
    def directory(rel):
        if rel in dirs:return dirs[rel]
        parent=directory(rel.parent);item=tag(parent,'Directory',Id='D'+hashlib.sha256((kind+'/'+rel.as_posix()).encode()).hexdigest()[:24],Name=rel.name);dirs[rel]=item;return item
    for file in sorted(payload.rglob('*')):
        if not file.is_file() or file.suffix.lower() in ('.pdb','.exp','.lib') or file.name in ('rustdesk.exe','meta.toml'):continue
        relative=file.relative_to(payload)
        cid='C'+hashlib.sha256((kind+'/'+relative.as_posix()).encode()).hexdigest()[:24]
        comp=tag(directory(relative.parent),'Component',Id=cid,Guid=guid(kind+'/file/'+relative.as_posix()),Win64='yes')
        if file.name == 'g3-update-session.lock':comp.set('Permanent','yes');comp.set('NeverOverwrite','yes')
        tag(comp,'File',Id='F'+cid[1:],Source=str(file),KeyPath='yes')
        tag(feature,'ComponentRef',Id=cid)
    main=tag(install,'Component',Id='MainExe',Guid=guid(kind+'/main'),Win64='yes')
    mainfile=tag(main,'File',Id='MainExeFile',Source=str(exe),Name=app+'.exe',KeyPath='yes')
    tag(mainfile,'Shortcut',Id='StartMenuShortcut',Directory='ApplicationProgramsFolder',Name=title,Advertise='yes',WorkingDirectory='INSTALLDIR')
    tag(main,'RemoveFolder',Id='MenuFolderRemove',Directory='ApplicationProgramsFolder',On='uninstall')
    service=tag(main,'ServiceInstall',Id='HostService',Name=app,DisplayName=title,Description='Autorisierte Fernwartung und automatische Sitzungsprotokollierung.',Type='ownProcess',Start='auto',ErrorControl='normal',Account='LocalSystem',Arguments='--service')
    E.SubElement(service,'{'+UTIL+'}ServiceConfig',{'FirstFailureActionType':'restart','SecondFailureActionType':'restart','ThirdFailureActionType':'restart','RestartServiceDelayInSeconds':'60','ResetPeriodInDays':'1'})
    tag(main,'ServiceControl',Id='ServiceLifecycle',Name=app,Start='install',Stop='both',Remove='uninstall',Wait='yes')
    for proto in ('tcp','udp'):
        E.SubElement(main,'{'+FW+'}FirewallException',{'Id':'Firewall'+proto.upper(),'Name':title+' – '+proto.upper(),'File':'MainExeFile','Protocol':proto,'Scope':'any','Profile':'all','IgnoreFailure':'no','Description':'Nur die installierte Fernwartungsanwendung; dynamische Peer-Verbindungsports.'})
    tag(feature,'ComponentRef',Id='MainExe')
    if kind=='host':
        gui=tag(install,'Component',Id='HostUI',Guid=guid(kind+'/gui'),Win64='yes')
        tag(gui,'File',Id='HostUIFile',Source=str(folder/'g3Host-ui.exe'),Name='g3Host-ui.exe',KeyPath='yes')
        tag(feature,'ComponentRef',Id='HostUI')
    registry=tag(install,'Component',Id='InstallRegistration',Guid=guid(kind+'/registration'),Win64='yes')
    state='Software\\'+app+'\\InstallState\\'+app
    key=tag(registry,'RegistryKey',Root='HKLM',Key=state)
    for name,typ,value in [('InstallLocation','string','[INSTALLDIR]'),('WindowsInstaller','integer','1'),('BuildDate','string',build_date),('MsiProductCode','string','[ProductCode]')]:
        tag(key,'RegistryValue',Name=name,Type=typ,Value=value,KeyPath='yes' if name=='InstallLocation' else 'no')
    tag(registry,'RemoveRegistryKey',Root='HKLM',Key='Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\'+app,Action='removeOnInstall')
    protocol=tag(registry,'RegistryKey',Root='HKLM',Key='Software\\Classes\\'+app.lower())
    tag(protocol,'RegistryValue',Type='string',Value='URL:'+title)
    tag(protocol,'RegistryValue',Name='URL Protocol',Type='string',Value='')
    command=tag(protocol,'RegistryKey',Key='shell\\open\\command');tag(command,'RegistryValue',Type='string',Value='"[INSTALLDIR]'+app+'.exe" "%1"')
    tag(registry,'CopyFile',Id='BrokerCopy',SourceDirectory='System64Folder',SourceName='RuntimeBroker.exe',DestinationDirectory='INSTALLDIR',DestinationName='RuntimeBroker_rustdesk.exe')
    tag(registry,'RegistryValue',Root='HKLM',Key='Software\\Microsoft\\Windows\\CurrentVersion\\Run',Name=app+'Tray',Type='string',Value='"[INSTALLDIR]'+app+'.exe" --tray')
    tag(registry,'RemoveFile',Id='BrokerRemove',Name='RuntimeBroker_rustdesk.exe',On='uninstall')
    tag(feature,'ComponentRef',Id='InstallRegistration')
    enrollment=tag(install,'Component',Id='EnrollmentSource',Guid=guid(kind+'/source'),Win64='yes',NeverOverwrite='yes')
    tag(enrollment,'RegistryValue',Root='HKLM',Key=state,Name='EnrollmentSource',Type='string',Value='[OriginalDatabase]',KeyPath='yes')
    tag(feature,'ComponentRef',Id='EnrollmentSource')
    sas=tag(install,'Component',Id='SecureAttention',Guid=guid(kind+'/sas'),Win64='yes',NeverOverwrite='yes',Permanent='yes')
    tag(sas,'RegistryValue',Root='HKLM',Key='Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System',Name='SoftwareSASGeneration',Type='integer',Value=1,KeyPath='yes')
    tag(feature,'ComponentRef',Id='SecureAttention')
    tag(product,'UIRef',Id='WixUI_InstallDir');tag(product,'Property',Id='WIXUI_INSTALLDIR',Value='INSTALLDIR')
    tag(product,'WixVariable',Id='WixUILicenseRtf',Value=str(ROOT/'g3-build/msi/license.rtf'))
    if kind!='host':
        tag(product,'Property',Id='WIXUI_EXITDIALOGOPTIONALCHECKBOXTEXT',Value='g3 OpsLinX öffnen')
        tag(product,'Property',Id='WIXUI_EXITDIALOGOPTIONALCHECKBOX',Value=1)
        tag(product,'Property',Id='WixShellExecTarget',Value='[#MainExeFile]')
        tag(product,'CustomAction',Id='LaunchClient',BinaryKey='WixCA',DllEntry='WixShellExec',Impersonate='yes')
        ui=tag(product,'UI');tag(ui,'Publish',Dialog='ExitDialog',Control='Finish',Event='DoAction',Value='LaunchClient').text='WIXUI_EXITDIALOGOPTIONALCHECKBOX = 1 AND NOT Installed'
    (ROOT/'g3-build/msi/license.rtf').write_text(r'{\rtf1\ansi\deff0 {\fonttbl {\f0 Segoe UI;}}\f0\fs20 g3 OpsLinX\par\par Client: GNU Affero General Public License v3.\par Der vollstaendige Lizenztext liegt der Installation als LICENCE bei.\par Quellcode und weitere Lizenzen: https://rust.g3nx.net/licenses\par}',encoding='ascii')
    wxs=folder/'Product.wxs';E.ElementTree(wix).write(wxs,encoding='utf-8',xml_declaration=True)
    obj=folder/'Product.wixobj';output=ROOT/'outputs'/('g3-OpsLinX-Host-'+version+'-host-install.msi' if kind=='host' else 'g3-OpsLinX-'+version+'-install.msi')
    subprocess.run([str(WIX/'candle.exe'),'-nologo','-arch','x64','-ext',str(WIX/'WixFirewallExtension.dll'),'-ext',str(WIX/'WixUtilExtension.dll'),'-out',str(obj),str(wxs)],check=True)
    subprocess.run([str(WIX/'light.exe'),'-nologo','-ext',str(WIX/'WixFirewallExtension.dll'),'-ext',str(WIX/'WixUIExtension.dll'),'-ext',str(WIX/'WixUtilExtension.dll'),'-out',str(output),str(obj)],check=True)
    results[kind]={'file':output.name,'size':output.stat().st_size,'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'product_code':guid(kind+'/'+version)}
print(json.dumps(results))
