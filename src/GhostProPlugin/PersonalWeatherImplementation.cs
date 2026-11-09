using AssettoServer.Network.Tcp;
using AssettoServer.Server;
using AssettoServer.Server.Weather;
using AssettoServer.Server.Weather.Implementation;
using AssettoServer.Shared.Network.Packets.Outgoing;
using NodaTime;
using Serilog;
using System.Reflection;

namespace GhostProPlugin;

/// <summary>
/// Sits in front of the core weather implementation so a driver's personal
/// time-of-day and weather survive the server's per-second broadcast.
/// </summary>
/// <remarks>
/// <para>
/// The server tells every client what the sky looks like once a second
/// (<c>WeatherManager</c> → <c>SendWeather(weather, dateTime)</c>, i.e. one
/// packet for the whole grid). A personal override sent on its own is therefore
/// undone less than a second later, which reads as the sun snapping back and
/// forth every second rather than as a chosen hour.
/// </para>
/// <para>
/// So when nobody has asked for a private sky this type is a pass-through and
/// the global packet is still sent exactly as before, byte for byte. Once at
/// least one driver has an override, the broadcast is split per client and each
/// one gets either their own packet or the global one, so the override is what
/// keeps arriving for them.
/// </para>
/// <para>
/// Registered last in the container, so Autofac resolves this as
/// <c>IWeatherImplementation</c> instead of the core implementation.
/// </para>
/// </remarks>
public class PersonalWeatherImplementation : IWeatherImplementation
{
    private readonly IWeatherImplementation _inner;
    private readonly EntryCarManager _entryCarManager;

    /// <summary>
    /// Resolved lazily on purpose. GhostStateService needs WeatherManager to read
    /// the server clock, and WeatherManager needs IWeatherImplementation, which is
    /// this class: taking GhostStateService in the constructor closes that loop
    /// and Autofac then refuses to build the container at all
    /// ("Circular component dependency detected"), which stops the server from
    /// starting. Nothing here runs before the first weather tick, by which point
    /// WeatherManager is already built.
    /// </summary>

    /// <summary>
    /// A personal packet is a <c>CSPWeatherUpdate</c>, which only a client
    /// running WeatherFX understands. Without it there is nothing personal to
    /// send and this type stays out of the way.
    /// </summary>
    private readonly bool _canPersonalise;

    private readonly Lazy<GhostStateService> _state;

    public PersonalWeatherImplementation(
        GhostProConfiguration config,
        IWeatherTypeProvider weatherTypeProvider,
        EntryCarManager entryCarManager,
        CSPFeatureManager features,
        Lazy<GhostStateService> state)
    {
        _entryCarManager = entryCarManager;
        _state = state;
        _canPersonalise = config.Enabled && config.PersonalTime && config.WeatherFx
                          && config.PersonalWeatherSplit;

        // This class shadows the core IWeatherImplementation, so the core's own
        // WeatherFxV1Implementation is never built — and its constructor is the
        // only place WEATHERFX_V1 is announced to clients. Without this the
        // server silently stops requiring the feature it depends on.
        if (config.WeatherFx && !features.Features.ContainsKey("WEATHERFX_V1"))
        {
            features.Add(new CSPFeature { Name = "WEATHERFX_V1", Mandatory = true });
        }

        // Built by hand instead of injected: the core implementation is itself
        // registered as IWeatherImplementation, so Autofac would hand this
        // decorator back. A throwaway CSPFeatureManager keeps
        // WeatherFxV1Implementation's constructor from registering its
        // WEATHERFX_V1 feature a second time — CSPFeatureManager.Add throws on
        // a duplicate name, and the real one is already filled by the core.
        _inner = config.WeatherFx
            ? new WeatherFxV1Implementation(entryCarManager, new CSPFeatureManager())
            : new VanillaWeatherImplementation(weatherTypeProvider, entryCarManager);
    }

    public void SendWeather(WeatherData weather, ZonedDateTime dateTime, ACTcpClient? client = null)
    {
        if (client is not null)
        {
            SendOne(weather, dateTime, client);
            return;
        }

        if (!_canPersonalise || !_state.Value.HasPersonalWeatherOverrides())
        {
            // Nobody is asking for a private sky: unchanged behaviour, including
            // the core's "only send on change" optimisation.
            _inner.SendWeather(weather, dateTime);
            return;
        }

        foreach (var car in _entryCarManager.EntryCars)
        {
            if (car.Client is { } carClient)
            {
                SendOne(weather, dateTime, carClient);
            }
        }
    }

    private void SendOne(WeatherData weather, ZonedDateTime dateTime, ACTcpClient client)
    {
        if (_canPersonalise
            && _state.Value.TryBuildPersonalPacket(client.SessionId, weather, dateTime, out var personal))
        {
            try
            {
                SendPersonal(client, personal);
            }
            catch (Exception ex)
            {
                Log.Debug(ex, "[GhostPro] personal weather push failed for {Name}", client.Name);
            }
            return;
        }

        _inner.SendWeather(weather, dateTime, client);
    }

    /// <summary>
    /// Weather packets have to travel over UDP: that is the channel the core uses
    /// for them, and CSP applies a weather update on the channel it arrived on.
    /// SendPacketUdp is internal on some AssettoServer builds, so it is called by
    /// reflection — that keeps the plugin loadable on every build, and a build
    /// without it only costs the personal sky, not the whole plugin.
    /// </summary>
    private void SendPersonal(ACTcpClient client, CSPWeatherUpdate packet)
    {
        var udp = UdpSender.Value;
        if (udp is not null)
        {
            udp.MakeGenericMethod(typeof(CSPWeatherUpdate)).Invoke(client, new object?[] { packet });
            return;
        }

        Log.Warning(
            "[GhostPro] SendPacketUdp not found on this server build — personal time falls back to TCP, " +
            "and CSP may ignore it");
        client.SendPacket(packet);
    }

    private static readonly Lazy<MethodInfo?> UdpSender = new(() =>
        typeof(ACTcpClient).GetMethod(
            "SendPacketUdp",
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic));
}
