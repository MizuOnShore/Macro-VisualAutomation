using System.Text.Json;
using System.Text.Json.Serialization;

namespace Macro.Core;

public sealed class JsonStorage
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        AllowTrailingCommas = true
    };

    static JsonStorage() => Options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));

    public string DirectoryPath { get; }
    public string MacrosPath => Path.Combine(DirectoryPath, "Macros.json");
    public string AutomationsPath => Path.Combine(DirectoryPath, "Automations.json");

    public JsonStorage(string? directory = null)
    {
        DirectoryPath = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Macro");
    }

    public List<MacroDefinition> LoadMacros() => LoadWithBackup<List<MacroDefinition>>(MacrosPath) ?? [];
    public List<AutomationDefinition> LoadAutomations() =>
        LoadWithBackup<List<AutomationDefinition>>(AutomationsPath) ?? [];

    public void SaveMacros(IReadOnlyList<MacroDefinition> macros) => SaveAtomic(MacrosPath, macros);
    public void SaveAutomations(IReadOnlyList<AutomationDefinition> automations) => SaveAtomic(AutomationsPath, automations);

    public T? Import<T>(string path) => JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options);
    public void Export<T>(string path, T value) => File.WriteAllText(path, JsonSerializer.Serialize(value, Options));

    private T? LoadWithBackup<T>(string path)
    {
        if (!File.Exists(path)) return default;
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options); }
        catch when (File.Exists(BackupPath(path)))
        {
            return JsonSerializer.Deserialize<T>(File.ReadAllText(BackupPath(path)), Options);
        }
    }

    private static void SaveAtomic<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var json = JsonSerializer.Serialize(value, Options);
        var temp = path + ".tmp";
        File.WriteAllText(temp, json);
        if (File.Exists(path)) File.Copy(path, BackupPath(path), true);
        File.Move(temp, path, true);
    }

    private static string BackupPath(string path) => Path.ChangeExtension(path, ".backup.json");
}
