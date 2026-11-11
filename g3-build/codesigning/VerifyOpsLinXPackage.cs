using System;
using System.IO;

internal static class VerifyOpsLinXPackage
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 3 || new FileInfo(args[2]).Length > OpsLinXPackageSignature.MaximumSignatureSize)
                return 2;
            OpsLinXPackageSignature.Verify(args[0], args[1], File.ReadAllBytes(args[2]));
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
