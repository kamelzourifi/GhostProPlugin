using AssettoServer.Network.Tcp;
using AssettoServer.Server;
using AssettoServer.Shared.Network.Packets.Outgoing;
using AssettoServer.Shared.Weather;
using GhostProPlugin.Packets;
using Microsoft.Extensions.Hosting;
using Serilog;

namespace GhostProPlugin;

public class GhostProPlugin : BackgroundService
{
    private readonly GhostProConfiguration _config;
    private readonly CSPClientMessageTypeManager _messageTypes;
    private readonly GhostStateService _state;

    public GhostProPlugin(
        GhostProConfiguration config,
        CSPClientMessageTypeManager cspClientMessageTypeManager,
        GhostStateService state)
    {
        _config = config;
        _messageTypes = cspClientMessageTypeManager;
        _state = state;

        // RegisterOnlineEvent keys on the message type, so two plugins using the
        // same key would collide here with a duplicate-key throw at startup.
        _messageTypes.RegisterOnlineEvent<GhostProRequestPacket>(OnRequest);
        _messageTypes.RegisterOnlineEvent<GhostProPaintPacket>(OnPaint);
        _messageTypes.RegisterOnlineEvent<GhostProSetTimePacket>(OnSetTime);
        _messageTypes.RegisterOnlineEvent<GhostProTimeAckPacket>(OnTimeAck);
        _messageTypes.RegisterOnlineEvent<GhostProSetWeatherPacket>(OnSetWeather);

        _state.Configure(_config);
    }

    public override Task StartAsync(CancellationToken cancellationToken)
    {
        if (!_config.Enabled)
        {
            Log.Information("[GhostPro] Disabled in configuration");
            return Task.CompletedTask;
        }

        if (_config.PersonalTime && !_config.WeatherFx)
        {
            Log.Warning(
                "[GhostPro] PersonalTime is true but WeatherFx is false — " +
                "time/weather overrides will be computed but not rendered. " +
                "Set EnableWeatherFx: true in extra_cfg.yml.");
        }

        Log.Information(
            "[GhostPro] build for {Framework} — this plugin must match the server's AssettoServer build. " +
            "A DLL built for another one fails at startup with TypeLoadException.",
            BuildTargetFramework());

        Log.Information(
            "[GhostPro] Enabled — authoritative={Auth}, consent={Consent}, adminsOnly={Admins}, " +
            "bots={Bots}, paint={Paint}, brightnessFloor={Floor:F2}",
            _config.Authoritative, _config.RequireConsent, _config.AdminsOnly,
            _config.AllowBots, _config.AllowRemotePaint, _config.MinBrightness);

        return base.StartAsync(cancellationToken);
    }

    // BackgroundService requires this; the plugin is entirely event-driven, so
    // there is no periodic work to do.
    protected override Task ExecuteAsync(CancellationToken stoppingToken) => Task.CompletedTask;

    // Client -> server: "I would like to be passable."
    private void OnRequest(ACTcpClient client, GhostProRequestPacket packet)
    {
        if (!_config.Enabled || !_config.PushScript) return;

        var wasPassive = _state.IsPassive(client.SessionId);
        var granted = _state.Evaluate(client, packet);

        if (granted != wasPassive)
        {
            Log.Information(
                "[GhostPro] {Name} (car {CarId}) ghost {State} — {Reason}",
                client.Name, client.EntryCar.SessionId,
                granted ? "ENABLED" : "disabled", _state.LastReason);
        }

        // Echo the decision. Without this the client must assume success, and an
        // admin denial would look like a broken toggle rather than a decision.
        Send(client, new GhostProGrantPacket
        {
            Passive = granted,
            AllowBots = _config.AllowBots,
            Mode = _config.Authoritative ? (byte)1 : (byte)0,
            MinBrightness = ToByte(_config.MinBrightness),
        });

        if (_config.BroadcastGhostState)
        {
            _state.BroadcastState();
        }
    }

    // Client -> server: a paint colour to mirror on other drivers' screens.
    private void OnPaint(ACTcpClient client, GhostProPaintPacket packet)
    {
        if (!_config.Enabled || !_config.AllowRemotePaint || !_config.PushScript) return;

        // The sender may pick any colour, but the floor is the one rule that has
        // to hold everywhere: a black car is invisible to the drivers behind it.
        // This check lives server-side because a client that ignores the floor
        // must not be able to get a dark colour onto everyone else's screen.
        if (!packet.Reset && _config.MinBrightness > 0)
        {
            var peak = Math.Max(packet.R, Math.Max(packet.G, packet.B)) / 255f;
            if (peak < _config.MinBrightness)
            {
                Log.Debug(
                    "[GhostPro] rejected dark paint from {Name}: peak {Peak:F2} < floor {Floor:F2}",
                    client.Name, peak, _config.MinBrightness);
                Send(client, new GhostProGrantPacket
                {
                    Passive = _state.IsPassive(client.SessionId),
                    AllowBots = _config.AllowBots,
                    Mode = _config.Authoritative ? (byte)1 : (byte)0,
                    MinBrightness = ToByte(_config.MinBrightness),
                });
                return;
            }
        }

        _state.RememberPaint(client, packet);
        _state.BroadcastPaint(client, packet);
    }

    private void OnSetTime(ACTcpClient client, GhostProSetTimePacket packet)
    {
        if (!_config.Enabled || !_config.PersonalTime) return;

        if (packet.Mode == "sync")
        {
            _state.SyncTime(client.SessionId);
            return;
        }

        if (packet.Mode != "set" || !int.TryParse(packet.Seconds, out var seconds)) return;
        seconds = Math.Clamp(seconds, 0, 86399);

        // An admin is normally treated the same as anyone else: a personal
        // override reaches only that client. Setting AdminChangeIsGlobal makes
        // their choice server-wide, which changes everyone's lighting mid-race.
        if (client.IsAdministrator && _config.AdminChangeIsGlobal)
        {
            // Clear the personal override first, or a second conflicting packet
            // would be pushed after the server-wide one.
            _state.SyncTime(client.SessionId);
            _state.SetGlobalTime(seconds);
            Log.Information("[GhostPro] Admin {Name} applied SERVER time {Time}", client.Name, FormatTime(seconds));
            Send(client, new GhostProTimeAckPacket { Seconds = seconds.ToString(), Scope = 1 });
        }
        else
        {
            _state.SetPersonalTime(client, seconds);
            // Information, not Debug: this line is the only proof the request
            // reached the server, and it has to be visible in a normal console.
            Log.Information(
                "[GhostPro] {Name} PERSONAL time {Time} (personalTime={On}, split={Split}, weatherFx={Fx})",
                client.Name, FormatTime(seconds), _config.PersonalTime, _config.PersonalWeatherSplit, _config.WeatherFx);
            Send(client, new GhostProTimeAckPacket { Seconds = seconds.ToString(), Scope = 0 });
        }
    }

    private void OnTimeAck(ACTcpClient client, GhostProTimeAckPacket packet)
    {
        // Nothing to do: the packet is only meant for the client's own UI. It is
        // registered so the client can send it back without falling into the
        // server's "unknown lua message" relay path.
    }

    private static string FormatTime(int seconds) =>
        $"{seconds / 3600:00}:{seconds % 3600 / 60:00}";

    /// <summary>
    /// The framework this DLL was compiled for, so a server log says outright
    /// whether the plugin matches it. Two AssettoServer builds that share the
    /// 0.0.55 version number can target different frameworks, and the mismatch
    /// only shows up as a TypeLoadException at startup.
    /// </summary>
    private static string BuildTargetFramework() =>
        typeof(GhostProPlugin).Assembly
            .GetCustomAttributes(typeof(System.Runtime.Versioning.TargetFrameworkAttribute), false)
            .OfType<System.Runtime.Versioning.TargetFrameworkAttribute>()
            .Select(a => a.FrameworkName)
            .FirstOrDefault() ?? "unknown";

    private void OnSetWeather(ACTcpClient client, GhostProSetWeatherPacket packet)
    {
        if (!_config.Enabled || !_config.PersonalTime) return;

        if (packet.Mode == "sync")
        {
            _state.SyncWeather(client.SessionId);
            return;
        }

        if (packet.Mode != "set") return;

        // Parsed by NAME, not index: WeatherFxType's numeric values shift
        // between AssettoServer versions, so a client and server on different
        // builds would silently apply different weather. TryParse fails closed.
        if (!Enum.TryParse<WeatherFxType>(packet.Type, ignoreCase: true, out var weather))
        {
            Log.Debug("[GhostPro] unknown weather '{Type}' from {Name}", packet.Type, client.Name);
            return;
        }

        if (client.IsAdministrator && _config.AdminChangeIsGlobal)
        {
            _state.SyncWeather(client.SessionId);
            _state.SetGlobalWeather(weather);
            Log.Information("[GhostPro] Admin {Name} applied server weather {Weather}", client.Name, weather);
        }
        else
        {
            _state.SetPersonalWeather(client, weather);
            Log.Debug("[GhostPro] {Name} personal weather {Weather}", client.Name, weather);
        }
    }

    private static byte ToByte(float fraction) =>
        (byte)Math.Clamp(Math.Round(fraction * 255f), 0, 255);

    private void Send(ACTcpClient client, IOutgoingNetworkPacket packet)
    {
        try
        {
            // SendPacket, not SendPacketUdp: the latter is internal on the server
            // builds this plugin supports, and referencing it compiles against a
            // newer checkout then fails to load on an older server.
            client.SendPacket(packet);
        }
        catch (Exception ex)
        {
            Log.Debug(ex, "[GhostPro] grant send failed for {Name}", client.Name);
        }
    }
}