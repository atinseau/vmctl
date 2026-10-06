// Used only in tests, at the front of that test process's PATH. No network access.
using System;
using System.IO;
class NativeStub {
    static int Main(string[] args) {
        if (Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]).Equals("scp", StringComparison.OrdinalIgnoreCase)) {
            Console.Write(String.Join("\u001e", args));
        } else {
            Console.InputEncoding = new System.Text.UTF8Encoding(false);
            Console.OutputEncoding = new System.Text.UTF8Encoding(false);
            Console.Write(Console.In.ReadToEnd());
        }
        string error = Environment.GetEnvironmentVariable("VMCTL_TEST_STDERR");
        if (!String.IsNullOrEmpty(error)) Console.Error.Write(error);
        string code = Environment.GetEnvironmentVariable("VMCTL_TEST_EXITCODE");
        return String.IsNullOrEmpty(code) ? 0 : Int32.Parse(code);
    }
}
