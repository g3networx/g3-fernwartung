"""Headless production-form regression. Never starts an installer or changes a service."""
from pathlib import Path
import os,subprocess,json
root=Path(__file__).resolve().parents[1]
folder=root/'work/setup-progress-test';folder.mkdir(parents=True,exist_ok=True)
(folder/'Harness.cs').write_text(r'''using System;using System.IO;using System.Reflection;using System.Windows.Forms;using System.Drawing;using System.Text;using System.Threading.Tasks;
class ProgressAcceptance {
 static void Check(bool value,string name){if(!value)throw new Exception(name);Console.WriteLine("PASS: "+name);}
 static void Render(Form form,string path){using(var bitmap=new Bitmap(form.ClientSize.Width,form.ClientSize.Height)){
  using(var graphics=Graphics.FromImage(bitmap)){graphics.Clear(form.BackColor);foreach(Control control in form.Controls)using(var child=new Bitmap(control.Width,control.Height)){control.DrawToBitmap(child,new Rectangle(0,0,child.Width,child.Height));graphics.DrawImageUnscaled(child,control.Left,control.Top);}}
  bitmap.Save(path);
 }}
 [STAThread]static int Main(string[] args){try{
  string dir=Path.GetFullPath(args[0]);Directory.CreateDirectory(dir);
  string de="Aktion gestartet um 10:32:10: InstallValidate.\r\n";
  string en="Action start 10:35:40: InstallFiles.\r\n";
  Check(SetupProgress.Phase(de).Contains("mehrere Minuten"),"long Windows validation is named");
  Check(SetupProgress.Phase(de+en).Contains("kopiert"),"current phase advances from validation to copy");
  Check(SetupProgress.Phase("Action start 10:35:40: PrivateCustomerToken.\n")==null,"unknown log content is never displayed");
  string log=Path.Combine(dir,"fixture.log");File.WriteAllText(log,new string('x',70000)+"\r\n"+de,Encoding.Unicode);
  Check(SetupProgress.ReadPhase(log,DateTime.UtcNow.AddMinutes(-1)).Contains("vorhandene Dateien"),"UTF16 bounded log tail identifies the phase");
  Check(SetupProgress.ReadPhase(log,DateTime.UtcNow.AddMinutes(1))==null,"previous installer log cannot appear as current progress");
  Application.EnableVisualStyles();using(var form=new SetupForm(0)){
   var flags=BindingFlags.Instance|BindingFlags.NonPublic;var type=typeof(SetupForm);
   type.GetField("working",flags).SetValue(form,true);
   var button=(Button)type.GetField("start",flags).GetValue(form);button.Enabled=false;button.Text="Installation läuft …";
   var label=(Label)type.GetField("stepLabel",flags).GetValue(form);var status=(Label)type.GetField("status",flags).GetValue(form);
   var bar=(ProgressBar)type.GetField("progress",flags).GetValue(form);
   type.GetMethod("ShowStep",flags).Invoke(form,new object[]{1,"Installationspaket wird heruntergeladen …",true});
   type.GetMethod("ShowPercent",flags).Invoke(form,new object[]{42,"Download · 11,2 / 26,6 MB"});
   Check(label.Text.Contains("42 %")&&label.Text.Contains("1 von 5")&&bar.Value==42,"download displays numeric percent and named stage");
   Render(form,Path.Combine(dir,"download.png"));
   type.GetMethod("ShowStep",flags).Invoke(form,new object[]{3,SetupProgress.Phase(de),false});
   Check(bar.Style==ProgressBarStyle.Marquee&&!label.Text.Contains("%")&&status.Text.Contains("mehrere Minuten"),"MSI validation is explained without fabricated percentage");
   ((Task)type.GetMethod("Install",flags).Invoke(form,null)).GetAwaiter().GetResult();
   Check(status.Text.Contains("mehrere Minuten"),"repeat install action cannot launch another worker");
   Render(form,Path.Combine(dir,"validation.png"));
  }
  return 0;
 }catch(Exception error){Console.Error.WriteLine(error);return 1;}}
}''',encoding='utf-8')
(folder/'payload.tsv').write_text('',encoding='utf-8')
exe=folder/'ProgressAcceptance.exe'
subprocess.run([str(Path(os.environ['SystemRoot'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'),'/nologo','/target:exe','/main:ProgressAcceptance','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.ServiceProcess.dll','/resource:'+str(folder/'payload.tsv')+',g3.payload','/out:'+str(exe),str(root/'g3-build/SetupBootstrap.cs'),str(folder/'Harness.cs')],check=True)
result=subprocess.run([str(exe),str(folder)],check=True,capture_output=True,text=True)
print(result.stdout)
out=root/'outputs';out.mkdir(exist_ok=True)
(out/'setup-progress-acceptance.json').write_text(json.dumps({'passed':True,'no_installation':True,'no_service_mutation':True,'checks':result.stdout.splitlines(),'rendered_states':['download','validation']},indent=2),encoding='utf-8')
