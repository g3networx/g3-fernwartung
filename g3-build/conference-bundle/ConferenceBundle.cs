using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class ConferenceBundle
{
    private const int Busy = 1618;
    private const int RestartRequired = 3010;
    private static readonly string ProgramFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);

    [STAThread]
    private static int Main(string[] args)
    {
        bool interactive = args.Length == 1 && args[0] == "--interactive";
        bool quiet = interactive || (args.Length == 1 && args[0] == "--quiet");
        if (args.Length != 0 && !quiet) return 87;
        try
        {
            using (var metadata = new StreamReader(Resource("bundle.metadata")))
            using (var mutex = new Mutex(false, @"Global\g3NetworX-OpsLinX-OpsTalX-Setup"))
            {
                bool acquired;
                try { acquired = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) return Report(quiet, Busy, "Ein Sammelinstaller ist bereits geöffnet.");
                try { return Run(quiet, interactive, metadata); }
                finally { mutex.ReleaseMutex(); }
            }
        }
        catch (Exception)
        {
            return Report(quiet, 1603, "Die Installation konnte nicht abgeschlossen werden. Prüfe die installierten Versionen und starte den Sammelinstaller erneut.");
        }
    }

    private static int Run(bool quiet, bool interactive, StreamReader metadata)
    {
        string variant = metadata.ReadLine();
        if (variant != "g3Fernwartung" && variant != "g3Host") throw new InvalidDataException();
        string productName = variant == "g3Host" ? "OpsLinX Host" : "OpsLinX Vollclient";
        var linxVersion = Version.Parse(metadata.ReadLine());
        var talxVersion = Version.Parse(metadata.ReadLine());
        string linxExe = Path.Combine(ProgramFiles, variant, variant + ".exe");
        string talxExe = Path.Combine(ProgramFiles, "OpsTalX Labor", "OpsTalX.exe");
        bool updateLinx = NeedsLinxUpdate(variant, linxExe, linxVersion);
        bool updateTalx = NeedsUpdate(talxExe, talxVersion);
        if (updateTalx && TalxRunning()) return Report(quiet, Busy, "OpsTalX ist geöffnet. Beende OpsTalX und starte das Update erneut.");
        if (!updateLinx && !updateTalx) return Report(quiet, 0, productName + " und OpsTalX sind aktuell.");

        string folder = CreateStagingDirectory();
        string linxSetup = Path.Combine(folder, "OpsLinX-Setup.exe");
        string linxMsi = Path.Combine(folder, "OpsLinX.msi");
        string talxMsi = Path.Combine(folder, "OpsTalX.msi");
        try
        {
            // Verify both product payloads before any installer is allowed to change the machine.
            Extract("bundle.linx.exe", linxSetup, metadata.ReadLine());
            Extract("bundle.linx.msi", linxMsi, metadata.ReadLine());
            Extract("bundle.talx.msi", talxMsi, metadata.ReadLine());

            int linxExit = 0;
            if (updateLinx)
            {
                // Delegate session state and any disconnect consent to the existing installer.
                linxExit = Execute(linxSetup, (interactive ? "--g3-install-interactive " : "--g3-install-worker ") + Quote(linxMsi));
                if (linxExit == Busy)
                    return Report(quiet, Busy, productName + " hat das Update zurückgestellt. OpsTalX wurde noch nicht aktualisiert.");
                if (linxExit != 0 && linxExit != RestartRequired)
                    return Report(quiet, linxExit, productName + " konnte nicht aktualisiert werden. OpsTalX wurde noch nicht aktualisiert.");
                if (NeedsLinxUpdate(variant, linxExe, linxVersion))
                    return Report(quiet, linxExit == RestartRequired ? RestartRequired : 1603,
                        productName + " ist noch nicht einsatzbereit. Prüfe den Installationsstatus und starte den Sammelinstaller erneut.");
            }

            int talxExit = 0;
            if (updateTalx)
            {
                if (TalxRunning())
                    return Report(quiet, Busy, productName + " ist aktuell. OpsTalX ist geöffnet. Beende es und starte den Sammelinstaller erneut.");
                string msiexec = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "msiexec.exe");
                talxExit = Execute(msiexec, "/i " + Quote(talxMsi) +
                    " /qn /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable MSIDISABLERMRESTART=1");
                if (talxExit != 0 && talxExit != RestartRequired)
                    return Report(quiet, talxExit, productName + " ist aktuell. Die Installation von OpsTalX wurde zurückgestellt oder ist fehlgeschlagen.");
                if (talxExit == 0 && NeedsUpdate(talxExe, talxVersion))
                    return Report(quiet, 1603, productName + " ist aktuell. Die installierte OpsTalX-Version konnte nicht bestätigt werden.");
            }

            if (linxExit == RestartRequired || talxExit == RestartRequired)
                return Report(quiet, RestartRequired, "Die Pakete wurden installiert. Windows meldet einen ausstehenden Neustart.");
            return Report(quiet, 0, productName + " und OpsTalX sind aktuell.");
        }
        finally
        {
            // Installed programs and scanners may still be releasing file handles.
            for (int attempt = 0; attempt < 5; attempt++)
            {
                try
                {
                    foreach (string path in new[] { linxSetup, linxMsi, talxMsi }) File.Delete(path);
                    Directory.Delete(folder);
                    break;
                }
                catch (IOException) { if (attempt < 4) Thread.Sleep(250); }
                catch (UnauthorizedAccessException) { break; }
            }
        }
    }

    private static bool NeedsUpdate(string path, Version version)
    {
        if (!File.Exists(path)) return true;
        var info = FileVersionInfo.GetVersionInfo(path);
        return new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart) < version;
    }

    private static bool TalxRunning()
    {
        var processes = Process.GetProcessesByName("OpsTalX");
        try { return processes.Length != 0; }
        finally { foreach (Process process in processes) process.Dispose(); }
    }

    private static bool NeedsLinxUpdate(string variant, string path, Version version)
    {
        if (!File.Exists(path)) return true;
        const string machine = @"HKEY_LOCAL_MACHINE\SOFTWARE\";
        var productCode = Registry.GetValue(machine + variant + @"\InstallState\" + variant, "MsiProductCode", null) as string;
        Guid product;
        if (!Guid.TryParse(productCode, out product)) throw new InvalidDataException("OpsLinX MSI product");
        var displayVersion = Registry.GetValue(machine + @"Microsoft\Windows\CurrentVersion\Uninstall\" +
            product.ToString("B").ToUpperInvariant(), "DisplayVersion", null) as string;
        Version installed;
        if (!Version.TryParse(displayVersion, out installed)) throw new InvalidDataException("OpsLinX MSI version");
        return installed < version;
    }

    private static string CreateStagingDirectory()
    {
        string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "g3-Conference-Setup-" + Guid.NewGuid().ToString("N"));
        if (Directory.Exists(folder) || File.Exists(folder)) throw new IOException();
        var acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false);
        foreach (WellKnownSidType type in new[] { WellKnownSidType.BuiltinAdministratorsSid, WellKnownSidType.LocalSystemSid })
        {
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(type, null), FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        }
        Directory.CreateDirectory(folder, acl);
        if ((File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) throw new IOException();
        return folder;
    }

    private static Stream Resource(string name)
    {
        var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
        if (stream == null) throw new InvalidDataException(name);
        return stream;
    }

    private static void Extract(string name, string path, string expected)
    {
        using (var input = Resource(name))
        using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
        using (var sha = SHA256.Create())
        {
            input.CopyTo(output);
            output.Position = 0;
            string actual = BitConverter.ToString(sha.ComputeHash(output)).Replace("-", "");
            if (!String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException(name);
        }
    }

    private static string Quote(string value) { return "\"" + value + "\""; }

    private static int Execute(string file, string arguments)
    {
        using (var process = Process.Start(new ProcessStartInfo(file, arguments) { UseShellExecute = false, CreateNoWindow = true }))
        {
            if (process == null) throw new IOException();
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static int Report(bool quiet, int code, string message)
    {
        if (!quiet) MessageBox.Show(message, "OpsLinX und OpsTalX", MessageBoxButtons.OK,
            code == 0 || code == RestartRequired ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
        return code;
    }
}
