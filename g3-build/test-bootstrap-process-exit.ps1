$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out=Join-Path $root 'outputs/bootstrap-process-exit-tests';New-Item -ItemType Directory -Path $out -Force|Out-Null
$test=@'
using System;using System.Diagnostics;
internal static class G3ProcessExitRegressionTests {
 static void Require(bool okay,string name){if(!okay)throw new Exception(name);Console.WriteLine("PASS "+name);}
 static Process Start(string command){return Process.Start(new ProcessStartInfo(Environment.GetEnvironmentVariable("SystemRoot")+@"\System32\cmd.exe","/c "+command){UseShellExecute=false,CreateNoWindow=true});}
 public static int Main(){
  using(var live=Start("ping -n 3 127.0.0.1 >nul")){var held=live.Handle;Require(SetupForm.ProcessCouldBeActive(live.Id),"live process remains busy");live.WaitForExit();}
  foreach(int code in new[]{0,7})using(var exited=Start("exit /b "+code)){var held=exited.Handle;exited.WaitForExit();Require(!SetupForm.ProcessCouldBeActive(exited.Id),"confirmed exited process "+code+" does not block");}
  Require(SetupForm.ProcessCouldBeActive(int.MaxValue),"unreadable process state remains busy");
  return 0;
 }
}
'@
$file=Join-Path $out 'ProcessExitTests.cs';[IO.File]::WriteAllText($file,$test,[Text.UTF8Encoding]::new($false))
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe=Join-Path $out 'ProcessExitTests.exe'
& $compiler /nologo /target:exe /main:G3ProcessExitRegressionTests (('/out:')+$exe) /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.ServiceProcess.dll (Join-Path $PSScriptRoot 'SetupBootstrap.cs') $file
if($LASTEXITCODE -ne 0){throw 'Bootstrap process-state regression compilation failed'}
& $exe|Tee-Object (Join-Path $out 'result.txt')
if($LASTEXITCODE -ne 0){throw 'Bootstrap process-state regression failed'}
