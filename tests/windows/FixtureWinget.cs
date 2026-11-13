// A deterministic CLI boundary, NOT a replacement test for Microsoft's WinGet.
// All package state comes from real MSI registrations; mutations use msiexec.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Web.Script.Serialization;
using Microsoft.Win32;

public static class FixtureWinget {
    static Dictionary<string, object> config;
    static readonly JavaScriptSerializer json = new JavaScriptSerializer();
    static string C(string key) { return (string)config[key]; }
    static string Option(string[] args, string name) {
        int i = Array.IndexOf(args, name);
        return i < 0 || i + 1 >= args.Length ? null : args[i + 1];
    }
    static bool Registered(string scope) {
        foreach (RegistryView view in new[] { RegistryView.Registry64, RegistryView.Registry32 }) {
            using (RegistryKey root = RegistryKey.OpenBaseKey(scope == "machine" ? RegistryHive.LocalMachine : RegistryHive.CurrentUser, view))
            using (RegistryKey key = root.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + C("ProductCode"))) {
                if (key != null) return true;
            }
        }
        return false;
    }
    static int Msi(string arguments) {
        using (Process p = Process.Start(new ProcessStartInfo {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "msiexec.exe"),
            Arguments = arguments, UseShellExecute = false, CreateNoWindow = true
        })) {
            if (!p.WaitForExit(120000)) { p.Kill(); throw new Exception("Fixture MSI timed out"); }
            return p.ExitCode;
        }
    }
    public static int Main(string[] args) {
        try {
            config = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "fixture-config.json")));
            File.AppendAllText(Path.Combine(C("Root"), "winget-invocations.jsonl"), json.Serialize(args) + Environment.NewLine);
            if (args.Length == 0) throw new Exception("No command");
            string id = Option(args, "--id");
            if (id != null && id != C("PackageId")) throw new Exception("Fixture refuses unrelated package ID");
            if (Option(args, "--source") != "winget") throw new Exception("Explicit source required");
            string scope = Option(args, "--scope");
            if (args[0] == "list") {
                if (Option(args, "--name") != null && Option(args, "--name") != C("Name")) return unchecked((int)0x8A150014);
                bool found = scope == "user" ? Registered("user") : scope == "machine" ? Registered("machine") : Registered("user") || Registered("machine");
                if (!found) return unchecked((int)0x8A150014);
                Console.WriteLine(C("Name") + "  " + C("PackageId") + "  1.0.0  winget");
                return 0;
            }
            if (args[0] == "download") {
                if (scope != "machine") throw new Exception("Machine download required");
                string directory = Option(args, "--download-directory");
                Directory.CreateDirectory(directory);
                File.Copy(C("Msi"), Path.Combine(directory, "fixture.msi"), true);
                return 0;
            }
            if (args[0] == "install") {
                if (scope != "machine" || Array.IndexOf(args, "--silent") < 0) throw new Exception("Silent machine install required");
                return Msi("/i \"" + C("Msi") + "\" ALLUSERS=1 MSIINSTALLPERUSER=\"\" INSTALLFOLDER=\"" + C("MachineDir") + "\" /qn /norestart /l*v \"" + Path.Combine(C("Root"), "machine-install.log") + "\"");
            }
            if (args[0] == "uninstall") {
                if (Option(args, "--product-code") != null && Option(args, "--product-code") != C("ProductCode")) throw new Exception("Unexpected product GUID");
                if (scope != "user" && scope != "machine") throw new Exception("Explicit installed scope required");
                return Msi("/x " + C("ProductCode") + (scope == "machine" ? " ALLUSERS=1" : "") + " /qn /norestart /l*v \"" + Path.Combine(C("Root"), "uninstall-" + scope + ".log") + "\"");
            }
            if (args[0] == "export") {
                object[] packages = Registered("user") || Registered("machine")
                    ? new object[] { new Dictionary<string, object> { { "PackageIdentifier", C("PackageId") } } } : new object[0];
                File.WriteAllText(Option(args, "--output"), json.Serialize(new { Sources = new[] { new { Packages = packages } } }));
                return 0;
            }
            if (args[0] == "upgrade" && scope == "machine") return 0;
            throw new Exception("Unsupported fixture command: " + args[0]);
        } catch (Exception e) { Console.Error.WriteLine(e.ToString()); return 1; }
    }
}
