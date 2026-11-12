$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out=Join-Path $root 'outputs/bootstrap-process-exit-tests';New-Item -ItemType Directory -Path $out -Force|Out-Null
$test=@'
using System;using System.Diagnostics;using System.IO;
internal static class G3ProcessExitRegressionTests {
 static void Require(bool okay,string name){if(!okay)throw new Exception(name);Console.WriteLine("PASS "+name);}
 static Process Start(string command){return Process.Start(new ProcessStartInfo(Environment.GetEnvironmentVariable("SystemRoot")+@"\System32\cmd.exe","/c "+command){UseShellExecute=false,CreateNoWindow=true});}
 static int ProbeSetupInstance(string mutexName){
  using(var child=Process.Start(new ProcessStartInfo(typeof(G3ProcessExitRegressionTests).Assembly.Location,"--probe-setup-instance "+mutexName){
   UseShellExecute=false,CreateNoWindow=true})){
   if(!child.WaitForExit(5000)){child.Kill();throw new Exception("Duplicate launcher did not exit promptly");}
   return child.ExitCode;
  }
 }
 public static int Main(string[] args){
  if(args.Length==2&&args[0]=="--probe-setup-instance"){
   using(var instance=new SetupInstance(args[1],false))return instance.Acquired?0:1618;
  }
  string mutexName=@"Global\g3NetworX.OpsLinX.Test."+Guid.NewGuid().ToString("N");
  using(var instance=new SetupInstance(mutexName,false)){
   Require(instance.Acquired,"first launcher acquires the lock");
   Require(ProbeSetupInstance(mutexName)==1618,"a second launcher process exits while the first is active");
  }
  Require(ProbeSetupInstance(mutexName)==0,"launcher can start again after the first exits");
  using(var live=Start("ping -n 3 127.0.0.1 >nul")){var held=live.Handle;Require(SetupForm.ProcessCouldBeActive(live.Id),"live process remains busy");live.WaitForExit();}
  foreach(int code in new[]{0,7,259})using(var exited=Start("exit /b "+code)){var held=exited.Handle;exited.WaitForExit();Require(!SetupForm.ProcessCouldBeActive(exited.Id),"confirmed exited process "+code+" does not block");}
  Require(SetupForm.ProcessCouldBeActive(int.MaxValue),"unreadable process state remains busy");
  var parked=new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,"cmd.exe"),"/c pause >nul"){
   UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true};
  using(var live=Process.Start(parked)){
   var executable=Path.Combine(Environment.SystemDirectory,"cmd.exe");
   Require(!SetupForm.InstalledProcessRemains(live.Id,Path.Combine(Path.GetTempPath(),"cmd.exe"),true),
    "a process with the same name from a different path is ignored");
   Require(SetupForm.InstalledProcessRemains(live.Id,executable,false),
    "inspection leaves the matching process running");
   Require(!SetupForm.InstalledProcessRemains(live.Id,executable,true),
    "matching process releases the files after termination");
   live.WaitForExit();
  }
  return 0;
 }
}
'@
$file=Join-Path $out 'ProcessExitTests.cs';[IO.File]::WriteAllText($file,$test,[Text.UTF8Encoding]::new($false))
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe=Join-Path $out 'ProcessExitTests.exe'
& $compiler /nologo /target:exe /main:G3ProcessExitRegressionTests (('/out:')+$exe) /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.ServiceProcess.dll /r:System.Security.dll (Join-Path $PSScriptRoot 'codesigning/OpsLinXPackageSignature.cs') (Join-Path $PSScriptRoot 'SetupBootstrap.cs') $file
if($LASTEXITCODE -ne 0){throw 'Bootstrap process-state regression compilation failed'}
& $exe|Tee-Object (Join-Path $out 'result.txt')
if($LASTEXITCODE -ne 0){throw 'Bootstrap process-state regression failed'}
