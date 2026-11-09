// Verifies a built plugin's assembly references against the ones the server
// assemblies it will load into actually declare.
//
// The failure this catches is invisible at build time. ACPluginLoader calls
// assembly.GetTypes(), so ONE unresolvable reference aborts the whole plugin with
// ReflectionTypeLoadException, and the message names the missing assembly rather
// than the plugin at fault.
//
// Compared against the freshly built AssettoServer DLLs, not against csproj
// PackageReference versions and not against another plugin:
//   * a package version is not an assembly version (YamlDotNet 16.2.1 ships an
//     assembly stamped 16.0.0.0), so csproj comparison reports false conflicts
//   * a third-party plugin may target a different server commit entirely
//
//   dotnet run -- <plugin.dll> <AssettoServer.dll> [more provider DLLs...]
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: asmrefs <plugin.dll> <provider.dll> [more providers...]");
    return 1;
}

static Dictionary<string, Version> ReadRefs(string path)
{
    using var fs = File.OpenRead(path);
    using var pe = new PEReader(fs);
    var md = pe.GetMetadataReader();
    var refs = new Dictionary<string, Version>(StringComparer.Ordinal);
    foreach (var handle in md.AssemblyReferences)
    {
        var reference = md.GetAssemblyReference(handle);
        refs[md.GetString(reference.Name)] = reference.Version;
    }
    return refs;
}

var ours = ReadRefs(args[0]);
Console.WriteLine($"{Path.GetFileName(args[0])}: {ours.Count} assembly refs");
foreach (var (name, version) in ours.OrderBy(r => r.Key, StringComparer.Ordinal))
{
    Console.WriteLine($"  {name,-48} {version}");
}

// Union of what the host assemblies reference. That is the closest thing to the
// runtime's resolution set that can be read statically.
var provided = new Dictionary<string, Version>(StringComparer.Ordinal);
foreach (var provider in args.Skip(1))
{
    foreach (var (name, version) in ReadRefs(provider))
    {
        provided[name] = version;
    }
}

Console.WriteLine();
Console.WriteLine($"host assemblies declare {provided.Count} refs");

var problems = 0;
foreach (var (name, version) in ours.OrderBy(r => r.Key, StringComparer.Ordinal))
{
    // 0.0.0.0 means "any version" to the loader and always binds.
    if (version == new Version(0, 0, 0, 0))
    {
        Console.WriteLine($"  wildcard  {name} (binds to anything)");
        continue;
    }

    if (!provided.TryGetValue(name, out var theirs))
    {
        // Not referenced by the host assemblies at all. Usually a shared-runtime
        // assembly, which is fine; anything else is a genuine gap.
        Console.WriteLine($"  NOT IN HOST  {name} {version}");
        problems++;
        continue;
    }

    if (theirs == new Version(0, 0, 0, 0) || version == theirs)
    {
        Console.WriteLine($"  ok        {name} {version}");
        continue;
    }

    // A lower request is satisfied by a higher host assembly; a higher request
    // is not. That asymmetry is the whole failure mode.
    if (theirs >= version)
    {
        Console.WriteLine($"  ok        {name} wants {version}, host has {theirs} (roll-forward)");
    }
    else
    {
        Console.WriteLine($"  MISMATCH  {name}: plugin wants {version}, host has {theirs}");
        problems++;
    }
}

Console.WriteLine();
if (problems == 0)
{
    Console.WriteLine("all references satisfiable by the host");
    return 0;
}

Console.WriteLine($"{problems} unsatisfiable reference(s). This plugin WILL fail to load.");
Console.WriteLine("Rebuild against the exact commit your server runs");
Console.WriteLine("(first line of the server log: 'AssettoServer 0.0.55+<sha>').");
return 1;