using System.Reflection;
using AssettoServer.Server;
using AssettoServer.Server.Configuration;
using AssettoServer.Shared.Weather;
using Microsoft.Extensions.Hosting;
using Serilog;

namespace GhostProPlugin;

/// <summary>
/// Pushes the client script to every connecting driver.
/// </summary>
public class GhostProScriptPusher : IHostedService
{
    private readonly GhostProConfiguration _config;
    private readonly CSPServerScriptProvider _scriptProvider;
    private readonly ACServerConfiguration _serverConfiguration;

    public GhostProScriptPusher(
        GhostProConfiguration config,
        CSPServerScriptProvider scriptProvider,
        ACServerConfiguration serverConfiguration)
    {
        _config = config;
        _scriptProvider = scriptProvider;
        _serverConfiguration = serverConfiguration;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        if (!_config.Enabled)
        {
            Log.Information("[GhostPro] Disabled in configuration");
            return Task.CompletedTask;
        }

        // Pushing the bundled client script is optional. A client that refuses
        // the script does not fall back to a plain session: CSP gives up on the
        // whole connection a few seconds after "has connected", with no line in
        // the server log beyond the disconnect. So this stays off by default and
        // the players keep using their own client script.
        if (!_config.PushScript)
        {
            Log.Information(
                "[GhostPro] PushScript is off — not sending ghostpro.lua, players keep their own client script");
            return Task.CompletedTask;
        }

        // Without this the server never delivers the script and never routes the
        // client OnlineEvents. Failing loudly beats a server that looks healthy
        // while players see nothing.
        if (!_serverConfiguration.Extra.EnableClientMessages)
        {
            throw new ConfigurationException(
                "GhostProPlugin requires EnableClientMessages: true in extra_cfg.yml");
        }

        if (_config.PersonalTime && !_serverConfiguration.Extra.EnableWeatherFx)
        {
            Log.Warning(
                "[GhostPro] EnableWeatherFx is false — personal time/weather will not render. " +
                "Set EnableWeatherFx: true, or PersonalTime: false to silence this.");
        }

        var luaPath = Path.Combine(
            Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)!,
            "lua",
            "ghostpro.lua");

        if (!File.Exists(luaPath))
        {
            throw new FileNotFoundException("GhostPro Lua script was not found.", luaPath);
        }

        // Tokens are substituted here rather than shipped as a separate config
        // file: one round trip, and a client cannot read or alter server policy.
        var lua = File.ReadAllText(luaPath)
            .Replace("{{ANNOUNCE_INTERVAL}}", _config.AnnounceIntervalSeconds.ToString())
            .Replace("{{STATE_TTL}}", _config.StateTtlSeconds.ToString())
            .Replace("{{ALLOW_REMOTE_PAINT}}", _config.AllowRemotePaint ? "true" : "false")
            .Replace("{{ALLOW_BOTS}}", _config.AllowBots ? "true" : "false")
            .Replace("{{PERSONAL_TIME}}", _config.PersonalTime ? "true" : "false")
            .Replace("{{WEATHER_NAMES}}", BuildWeatherList());

        // The weather list is generated from this build's WeatherFxType, so a
        // name the server cannot parse is never sent to a client.

        if (lua.Contains("{{"))
        {
            // An unsubstituted token becomes `tonumber(nil)` and silently falls
            // back to a default, so the client would run with the wrong policy.
            throw new InvalidOperationException(
                "GhostPro Lua script still contains unsubstituted {{...}} tokens. " +
                "A configuration key was probably renamed.");
        }

        _scriptProvider.AddScript(
            new MemoryStream(System.Text.Encoding.UTF8.GetBytes(lua)),
            "ghostpro.lua");

        Log.Information("[GhostPro] Script pushed to all clients");
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    /// <summary>
    /// Build the Lua table of weather names this server actually understands.
    ///
    /// Generated from the compiled-in WeatherFxType rather than hardcoded, so a
    /// server on a different AssettoServer build cannot offer a name that would
    /// fail Enum.TryParse on the receiving side.
    /// </summary>
    private string BuildWeatherList()
    {
        var allow = _config.WeatherAllowList.Length > 0
            ? new HashSet<string>(_config.WeatherAllowList, StringComparer.OrdinalIgnoreCase)
            : null;

        var names = Enum.GetNames<WeatherFxType>()
            .Where(n => n != "None")
            .Where(n => allow is null || allow.Contains(n))
            .OrderBy(n => n, StringComparer.Ordinal);

        return "{" + string.Join(",", names.Select(n => "'" + n + "'")) + "}";
    }
}