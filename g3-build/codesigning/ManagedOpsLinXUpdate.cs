using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal static class ManagedOpsLinXUpdate
{
    private static readonly Uri Cluster = new Uri("https://linx.g3nx.net/");
    private const int Failed = 1603;
    private const int Busy = 1618;

    public sealed class Job
    {
        public ulong id { get; set; }
        public string receipt { get; set; }
        public string variant { get; set; }
        public string operation { get; set; }
    }

    public sealed class Release
    {
        public string release_version { get; set; }
    }

    internal static int Run()
    {
        if (!WindowsIdentity.GetCurrent().IsSystem)
            return 740;
        return RunInDirectory(AppDomain.CurrentDomain.BaseDirectory, Cluster);
    }

    // The installed command always supplies the fixed production origin. The
    // laboratory harness uses the same worker against an isolated portal.
    internal static int RunInDirectory(string directory, Uri origin)
    {
        string pending = Path.Combine(directory, "pending.json");
        if (!File.Exists(pending)) return 0;
        FileStream lease;
        try { lease = new FileStream(Path.Combine(directory, "worker.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { return Busy; }
        using (lease)
        {
            if (!File.Exists(pending)) return 0;
            var json = new JavaScriptSerializer();
            var job = json.Deserialize<Job>(File.ReadAllText(pending));
            if (job == null || job.id == 0 || job.receipt == null || !Regex.IsMatch(job.receipt, "\\A[A-Za-z0-9_-]{43}\\z")
                || (job.variant != "full" && job.variant != "host")
                || (job.operation != null && job.operation != "update" && job.operation != "uninstall")) return Failed;

            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            string resultFile = Path.Combine(directory, "result.txt");
            string prefix = job.id.ToString(CultureInfo.InvariantCulture) + ":" + job.receipt + ":";
            string stored = File.Exists(resultFile) ? File.ReadAllText(resultFile) : "";
            int exitCode;
            if (!stored.StartsWith(prefix, StringComparison.Ordinal) || !Int32.TryParse(stored.Substring(prefix.Length), out exitCode))
            {
                try
                {
                    exitCode = job.operation == "uninstall" ? Uninstall(directory, origin, job.variant)
                                                            : Install(directory, origin, job.variant, json);
                }
                catch (Exception error)
                {
                    File.WriteAllText(Path.Combine(directory, "update-error.txt"), error.Message);
                    exitCode = Failed;
                }
                if (exitCode < 0 || exitCode > UInt16.MaxValue) exitCode = Failed;
                string temporary = resultFile + ".tmp";
                File.WriteAllText(temporary, prefix + exitCode.ToString(CultureInfo.InvariantCulture));
                if (File.Exists(resultFile)) File.Replace(temporary, resultFile, null);
                else File.Move(temporary, resultFile);
            }

            // The service cannot retry the final response once it has been removed.
            // Keep the worker alive for transient network or server failures.
            bool removed = job.operation == "uninstall" && (exitCode == 0 || exitCode == 3010);
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    Report(origin, job, json, exitCode);
                    break;
                }
                catch (WebException error)
                {
                    if (!removed || attempt >= 29 || !CanRetryReport(error)) throw;
                    Thread.Sleep(TimeSpan.FromSeconds(10));
                }
            }
            File.Delete(pending);
            File.Delete(resultFile);
            return exitCode;
        }
    }

    private static bool CanRetryReport(WebException error)
    {
        using (var response = error.Response as HttpWebResponse)
            return response == null || (int)response.StatusCode >= 500 || (int)response.StatusCode == 429;
    }

    private static void Report(Uri origin, Job job, JavaScriptSerializer json, int exitCode)
    {
        string state = exitCode == Busy ? "busy" : exitCode == 0 || exitCode == 3010 ? "complete" : "failed";
        var request = Request(origin, "client-management/operations/" + job.id.ToString(CultureInfo.InvariantCulture) + "/result");
        request.Method = "POST";
        request.ContentType = "application/json";
        request.Headers[HttpRequestHeader.Authorization] = "Bearer " + job.receipt;
        byte[] body = Encoding.UTF8.GetBytes(json.Serialize(new { result = state, exit_code = exitCode }));
        request.ContentLength = body.Length;
        using (var output = request.GetRequestStream()) output.Write(body, 0, body.Length);
        using (var response = (HttpWebResponse)request.GetResponse())
            if (response.StatusCode != HttpStatusCode.OK) throw new IOException("Portal did not acknowledge the result.");
    }

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiGetProductInfo(string product, string property,
        StringBuilder value, ref uint length);

    private static Version InstalledPackageVersion(string app)
    {
        using (var localMachine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        using (var state = localMachine.OpenSubKey(@"SOFTWARE\" + app + @"\InstallState\" + app))
        {
            var code = state == null ? null : state.GetValue("MsiProductCode") as string;
            Guid product;
            if (!Guid.TryParseExact(code, "B", out product)) return null;
            var value = new StringBuilder(32);
            uint length = (uint)value.Capacity;
            Version version;
            if (MsiGetProductInfo(product.ToString("B").ToUpperInvariant(), "VersionString", value, ref length) != 0
                || !Version.TryParse(value.ToString(), out version)
                || version.Major != 1 || version.Minor < 60 || version.Minor > 62
                || version.Build < 0 || version.Build > UInt16.MaxValue || version.Revision != -1)
                return null;
            return version;
        }
    }

    private static int Uninstall(string directory, Uri origin, string variant)
    {
        bool host = variant == "host";
        string app = host ? "g3Host" : "g3Fernwartung";
        string installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), app, app + ".exe");
        if (!File.Exists(installed)) return Failed;
        var current = InstalledPackageVersion(app);
        if (current == null) return Failed;
        string version = "1.5.3-g3." + current.Minor.ToString(CultureInfo.InvariantCulture)
            + "." + current.Build.ToString(CultureInfo.InvariantCulture);
        string kind = host ? "host" : "windows";
        string name = "g3-OpsLinX-" + (host ? "Host-" : "") + version + (host ? "-host-install.exe" : "-install.exe");
        string launcher = Path.Combine(directory, name);
        try
        {
            Download(origin, "client/releases/" + version + "/" + kind, launcher, 4 * 1024 * 1024);
            var info = new ProcessStartInfo(launcher, "--g3-uninstall-worker") {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory
            };
            using (var installer = Process.Start(info))
            {
                installer.WaitForExit();
                return installer.ExitCode;
            }
        }
        finally
        {
            File.Delete(launcher);
        }
    }

    private static int Install(string directory, Uri origin, string variant, JavaScriptSerializer json)
    {
        bool host = variant == "host";
        string app = host ? "g3Host" : "g3Fernwartung";
        string installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), app, app + ".exe");
        if (!File.Exists(installed)) return Failed;

        Release release;
        using (var response = Open(origin, "client/update-v2.json"))
        using (var contents = new MemoryStream())
        {
            CopyBounded(response, contents, 65536);
            release = json.Deserialize<Release>(Encoding.UTF8.GetString(contents.ToArray()));
        }
        var version = Regex.Match(release.release_version ?? "", "\\A[0-9]+\\.[0-9]+\\.[0-9]+-g3\\.(60|61|62)\\.([0-9]{1,5})\\z");
        Version target;
        if (!version.Success || !Version.TryParse("1." + version.Groups[1].Value + "." + version.Groups[2].Value, out target)
            || target.Build > UInt16.MaxValue) return Failed;
        var current = InstalledPackageVersion(app);
        if (current == null) return Failed;
        if (current >= target)
        {
            using (var service = new ServiceController(app))
                return service.Status == ServiceControllerStatus.Running ? 0 : Failed;
        }

        string kind = host ? "host" : "windows";
        string basename = "g3-OpsLinX-" + (host ? "Host-" : "") + release.release_version + (host ? "-host-install" : "-install");
        string route = "client/releases/" + release.release_version + "/" + kind;
        string launcher = Path.Combine(directory, basename + ".exe");
        string msi = Path.Combine(directory, basename + ".msi");
        try
        {
            Download(origin, route, launcher, 4 * 1024 * 1024);
            Download(origin, route + "_msi", msi, 150 * 1024 * 1024);
            var info = new ProcessStartInfo(launcher, "--g3-install-worker \"" + msi + "\"") {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory
            };
            using (var installer = Process.Start(info))
            {
                installer.WaitForExit();
                return installer.ExitCode;
            }
        }
        finally
        {
            File.Delete(launcher);
            File.Delete(msi);
        }
    }

    private static HttpWebRequest Request(Uri origin, string path)
    {
        var request = (HttpWebRequest)WebRequest.Create(new Uri(origin, path));
        request.AllowAutoRedirect = false;
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        return request;
    }

    private static HttpWebResponse Open(Uri origin, string path)
    {
        var response = (HttpWebResponse)Request(origin, path).GetResponse();
        if (response.StatusCode == HttpStatusCode.OK) return response;
        response.Dispose();
        throw new IOException("OpsLinX download did not return HTTP 200.");
    }

    private static void Download(Uri origin, string path, string file, int limit)
    {
        byte[] signature;
        using (var response = Open(origin, path))
        {
            string encoded = response.Headers["X-OpsLinX-Signature"];
            if (String.IsNullOrEmpty(encoded) || encoded.Length > 5464)
                throw new IOException("Missing or oversized OpsLinX package signature.");
            signature = Convert.FromBase64String(encoded);
            using (var stream = File.Create(file)) CopyBounded(response, stream, limit);
        }
        OpsLinXPackageSignature.Verify(file, Path.GetFileName(file), signature);
    }

    private static void CopyBounded(HttpWebResponse response, Stream output, int limit)
    {
        if (response.ContentLength > limit) throw new IOException("OpsLinX download exceeds its size limit.");
        var buffer = new byte[65536];
        int total = 0;
        using (var input = response.GetResponseStream())
        {
            int count;
            while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                total += count;
                if (total > limit) throw new IOException("OpsLinX download exceeds its size limit.");
                output.Write(buffer, 0, count);
            }
        }
        if (response.ContentLength >= 0 && total != response.ContentLength)
            throw new IOException("Incomplete OpsLinX download.");
    }
}
