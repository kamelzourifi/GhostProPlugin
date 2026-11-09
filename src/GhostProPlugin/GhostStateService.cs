using AssettoServer.Network.Tcp;
using AssettoServer.Server;
using AssettoServer.Server.Weather;
using AssettoServer.Shared.Network.Packets.Outgoing;
using AssettoServer.Shared.Weather;
using GhostProPlugin.Packets;
using NodaTime;
using Serilog;

namespace GhostProPlugin;

/// <summary>
/// Authoritative ghost state, paint relay, and per-driver time/weather.
/// </summary>
/// <remarks>
/// API PORTABILITY. Only members present in every AssettoServer build this plugin
/// supports are used. Two convenient ones are NOT:
///
///   EntryCarManager.ConnectedCars  is internal or absent depending on commit.
///   ACTcpClient.SendPacketUdp       is internal or absent depending on commit.
///
/// Both compile fine against a newer checkout and then fail to load on an older
/// server, because ACPluginLoader calls assembly.GetTypes() and a single
/// unresolvable reference aborts the whole load with ReflectionTypeLoadException.
/// EntryCars and SendPacket exist in both, so those are used instead.
/// </remarks>
public class GhostStateService
{
    private sealed class PlayerState
    {
        public bool WantsGhost;
        public bool IsPassive;

        public byte BodyR, BodyG, BodyB;
        public byte RimR, RimG, RimB;

        public bool PersonalTime;

        /// <summary>
        /// Signed shift from the server clock, in seconds, wrapped to
        /// [-43200, 43200). A shift rather than an absolute hour so the
        /// personal clock keeps running instead of standing still at 12:00.
        /// </summary>
        public int TimeOffsetSeconds;

        public bool PersonalWeather;
        public WeatherFxType WeatherType = WeatherFxType.Clear;
    }

    private readonly Dictionary<byte, PlayerState> _states = new();
    private readonly IWeatherTypeProvider _weatherTypeProvider;
    private readonly EntryCarManager _entryCarManager;
    private readonly WeatherManager _weatherManager;

    // Not readonly: Configure() injects it after construction. The default is the
    // safe one (nothing granted) so a request arriving before Configure cannot
    // grant anything.
    private GhostProConfiguration _config = new();

    public string LastReason { get; private set; } = "";

    public GhostStateService(
        IWeatherTypeProvider weatherTypeProvider,
        EntryCarManager entryCarManager,
        WeatherManager weatherManager)
    {
        _weatherTypeProvider = weatherTypeProvider;
        _entryCarManager = entryCarManager;
        _weatherManager = weatherManager;

        _entryCarManager.ClientConnected += OnClientConnected;
        _entryCarManager.ClientDisconnected += OnDisconnected;
    }

    public void Configure(GhostProConfiguration config) => _config = config;

    public bool IsPassive(byte sessionId) =>
        _states.TryGetValue(sessionId, out var state) && state.IsPassive;

    /// <summary>Entry cars that currently have a usable client attached.</summary>
    private IEnumerable<EntryCar> LiveCars =>
        _entryCarManager.EntryCars.Where(car => car.Client is not null);

    /// <summary>
    /// Decide whether a ghost request is honoured. The caller echoes the result
    /// to the client so a denial is visible instead of silent.
    ///
    /// Policies, in order:
    ///   revoke      the player turned it off
    ///   AdminsOnly  only staff may ghost
    ///   consent     requester AND the nearest consenting driver must both want
    ///               it — nobody gets to pass through someone who has not opted in
    ///   permissive  the requester's toggle is enough (GhostPassive v25)
    /// </summary>
    public bool Evaluate(ACTcpClient client, GhostProRequestPacket packet)
    {
        var state = GetState(client.SessionId);

        if (packet.Mode == "revoke")
        {
            state.WantsGhost = false;
            state.IsPassive = false;
            LastReason = "self-disabled";
            return false;
        }

        if (packet.Mode != "ask")
        {
            LastReason = $"unknown mode '{packet.Mode}'";
            return false;
        }

        state.WantsGhost = true;

        if (_config.AdminsOnly)
        {
            state.IsPassive = client.IsAdministrator;
            LastReason = client.IsAdministrator ? "admin" : "admins only";
            return state.IsPassive;
        }

        if (_config.RequireConsent)
        {
            // The client is projected out once and null-checked there. Filtering
            // on `car.Client is not null` and dereferencing `car.Client` in a
            // later clause re-reads the property, which nullable analysis cannot
            // prove safe.
            var neighbour = LiveCars
                .Select(car => (Car: car, Client: car.Client!))
                .Where(x => x.Client.SessionId != client.SessionId)
                .Where(x => IsPassive(x.Client.SessionId) || WantsGhost(x.Client.SessionId))
                .Select(x => (Car: x.Car, Dist: Distance(client, x.Car)))
                .OrderBy(x => x.Dist)
                .FirstOrDefault();

            if (neighbour.Car is null)
            {
                state.IsPassive = false;
                LastReason = "no consenting driver on track";
                return false;
            }

            state.IsPassive = true;
            LastReason = $"consent with {neighbour.Car.Client!.Name} at {neighbour.Dist:F0}m";
            return true;
        }

        state.IsPassive = true;
        LastReason = "permissive";
        return true;
    }

    private bool WantsGhost(byte sessionId) =>
        _states.TryGetValue(sessionId, out var state) && state.WantsGhost;

    private static double Distance(ACTcpClient a, EntryCar b)
    {
        var pa = a.EntryCar.Status.Position;
        var pb = b.Status.Position;
        var dx = pa.X - pb.X;
        var dy = pa.Y - pb.Y;
        var dz = pa.Z - pb.Z;
        return Math.Sqrt(dx * dx + dy * dy + dz * dz);
    }

    /// <summary>
    /// Push the grant bitmask to everyone.
    ///
    /// Index 0 is skipped on purpose: a client must never pass through itself,
    /// and since the mask is per-recipient, leaving bit 0 clear is what enforces
    /// that rather than trusting the sender.
    /// </summary>
    public void BroadcastState()
    {
        var mask = BuildGrantMask();
        foreach (var car in LiveCars)
        {
            Send(car.Client!, new GhostProStatePacket { Granted = mask });
        }
    }

    private uint BuildGrantMask()
    {
        uint mask = 0;
        foreach (var car in LiveCars)
        {
            var index = car.SessionId;
            if (index == 0 || index >= 32) continue;
            if (IsPassive(car.Client!.SessionId))
            {
                mask |= 1u << index;
            }
        }
        return mask;
    }

    public void RememberPaint(ACTcpClient client, GhostProPaintPacket packet)
    {
        var state = GetState(client.SessionId);
        if (packet.Part == 1)
        {
            state.RimR = packet.R; state.RimG = packet.G; state.RimB = packet.B;
        }
        else
        {
            state.BodyR = packet.R; state.BodyG = packet.G; state.BodyB = packet.B;
        }
    }

    /// <summary>
    /// Relay a paint to everyone except its author.
    ///
    /// EntryCar.SessionId IS the entry index the client's car index refers to,
    /// so no extra lookup is needed.
    /// </summary>
    public void BroadcastPaint(ACTcpClient actor, GhostProPaintPacket packet)
    {
        if (!_config.PushScript) return;

        var index = actor.EntryCar.SessionId;
        foreach (var car in LiveCars)
        {
            var client = car.Client!;
            if (client.SessionId == actor.SessionId) continue;
            Send(client, new GhostProPaintRelayPacket
            {
                CarIndex = index,
                Part = packet.Part,
                R = packet.R, G = packet.G, B = packet.B,
                Reset = packet.Reset,
            });
        }
    }

    private static void Send(ACTcpClient client, IOutgoingNetworkPacket packet)
    {
        try
        {
            client.SendPacket(packet);
        }
        catch (Exception ex)
        {
            Log.Debug(ex, "[GhostPro] send failed for {Name}", client.Name);
        }
    }

    // --- personal time / weather ------------------------------------------
    public void Clear(byte sessionId) => _states.Remove(sessionId);

    /// <summary>
    /// True while at least one driver is looking at a sky of their own. The
    /// weather stream is only split per client while this holds.
    /// </summary>
    public bool HasPersonalWeatherOverrides() =>
        _states.Values.Any(state => state.PersonalTime || state.PersonalWeather);

    /// <summary>
    /// Build this driver's personal weather packet, or fail when they have not
    /// asked for one. Called once per client per server weather tick so an
    /// override is not overwritten a second later by the global broadcast.
    /// </summary>
    public bool TryBuildPersonalPacket(
        byte sessionId, WeatherData baseWeather, ZonedDateTime baseDateTime,
        out CSPWeatherUpdate packet) =>
        TryBuildPacket(sessionId, baseWeather, baseDateTime, out packet);

    /// <summary>Seconds since midnight, whole seconds, of the server clock.</summary>
    private static int SecondsOfDay(ZonedDateTime dateTime) =>
        (int)(dateTime.TimeOfDay.TickOfDay / 1_000_000_000L);

    /// <summary>
    /// Fold a shift into (-12h, +12h] so asking for 23:00 at 22:00 means one
    /// hour forward, not twenty-three hours back.
    /// </summary>
    private static int WrapOffset(int seconds)
    {
        const int day = 86400;
        var wrapped = ((seconds % day) + day) % day;
        if (wrapped > day / 2) wrapped -= day;
        return wrapped;
    }

    public void SetPersonalTime(ACTcpClient client, int seconds)
    {
        var state = GetState(client.SessionId);
        state.PersonalTime = true;
        state.TimeOffsetSeconds = WrapOffset(seconds - SecondsOfDay(_weatherManager.CurrentDateTime));
        PushPersonal(client);
    }

    public void SetPersonalWeather(ACTcpClient client, WeatherFxType type)
    {
        var state = GetState(client.SessionId);
        state.PersonalWeather = true;
        state.WeatherType = type;
        PushPersonal(client);
    }

    public void SyncTime(byte sessionId)
    {
        if (_states.TryGetValue(sessionId, out var state)) state.PersonalTime = false;
    }

    public void SyncWeather(byte sessionId)
    {
        if (_states.TryGetValue(sessionId, out var state)) state.PersonalWeather = false;
    }

    // An admin's choice is server-wide; everyone else's is personal.
    public void SetGlobalTime(int seconds)
    {
        _weatherManager.SetTime(seconds);
        foreach (var car in LiveCars)
        {
            try { _weatherManager.SendWeather(car.Client); }
            catch (Exception ex) { Log.Debug(ex, "[GhostPro] weather push failed"); }
        }
    }

    public void SetGlobalWeather(WeatherFxType type)
    {
        _weatherManager.SetCspWeather(type, 8);
        foreach (var car in LiveCars)
        {
            try { _weatherManager.SendWeather(car.Client); }
            catch (Exception ex) { Log.Debug(ex, "[GhostPro] weather push failed"); }
        }
    }

    private void PushPersonal(ACTcpClient client)
    {
        if (!TryBuildPacket(client.SessionId,
                _weatherManager.CurrentWeather,
                _weatherManager.CurrentDateTime,
                out CSPWeatherUpdate packet))
        {
            return;
        }
        Send(client, packet);
    }

    /// <summary>
    /// Build a weather packet differing from the server's only where this driver
    /// asked for a difference. Everything else is copied from the live server
    /// weather, so a personal override cannot freeze their simulation either.
    /// </summary>
    private bool TryBuildPacket(
        byte sessionId, WeatherData baseWeather, NodaTime.ZonedDateTime baseDateTime,
        out CSPWeatherUpdate packet)
    {
        packet = default;

        if (!_states.TryGetValue(sessionId, out var state)) return false;
        if (!state.PersonalTime && !state.PersonalWeather) return false;

        WeatherType weatherType;
        WeatherType upcomingType;
        float rainIntensity;
        float rainWetness;
        float rainWater;
        float humidity;
        ushort transitionValue;

        if (state.PersonalWeather)
        {
            weatherType = _weatherTypeProvider.GetWeatherType(state.WeatherType);
            upcomingType = weatherType;
            rainIntensity = weatherType.RainIntensity;
            rainWetness = weatherType.RainWetness;
            rainWater = weatherType.RainWater;
            humidity = weatherType.Humidity;
            // MaxValue means "fully transitioned": without it the client eases in
            // from the server weather and the change visibly flickers.
            transitionValue = ushort.MaxValue;
        }
        else
        {
            weatherType = baseWeather.Type;
            upcomingType = baseWeather.UpcomingType;
            rainIntensity = baseWeather.RainIntensity;
            rainWetness = baseWeather.RainWetness;
            rainWater = baseWeather.RainWater;
            humidity = baseWeather.Humidity;
            transitionValue = baseWeather.TransitionValue;
        }

        var dateTime = baseDateTime;
        if (state.PersonalTime)
        {
            dateTime = baseDateTime.PlusSeconds(state.TimeOffsetSeconds);
        }

        packet = new CSPWeatherUpdate
        {
            UnixTimestamp = (ulong)dateTime.ToInstant().ToUnixTimeSeconds(),
            WeatherType = (byte)weatherType.WeatherFxType,
            UpcomingWeatherType = (byte)upcomingType.WeatherFxType,
            TransitionValue = transitionValue,
            TemperatureAmbient = (Half)baseWeather.TemperatureAmbient,
            TemperatureRoad = (Half)baseWeather.TemperatureRoad,
            TrackGrip = (Half)baseWeather.TrackGrip,
            WindDirectionDeg = (Half)baseWeather.WindDirection,
            WindSpeed = (Half)baseWeather.WindSpeed,
            Humidity = (Half)humidity,
            Pressure = (Half)baseWeather.Pressure,
            RainIntensity = (Half)rainIntensity,
            RainWetness = (Half)rainWetness,
            RainWater = (Half)rainWater,
        };

        return true;
    }

    // --- lifecycle ----------------------------------------------------------
    private void OnClientConnected(ACTcpClient client, EventArgs args)
    {
        // These three messages exist for the bundled client script. Sending them
        // to a client that never loaded it means online events with keys nobody
        // is listening for, and CSP reacts to that by dropping the connection a
        // few seconds in — with nothing in the server log but the disconnect.
        if (!_config.PushScript) return;

        // A newcomer cannot compute the grant mask or know existing paints, so
        // both are pushed now rather than waiting for the next change.
        Send(client, new GhostProStatePacket { Granted = BuildGrantMask() });
        Send(client, new GhostProGrantPacket
        {
            Passive = IsPassive(client.SessionId),
            AllowBots = _config.AllowBots,
            Mode = _config.Authoritative ? (byte)1 : (byte)0,
            MinBrightness = ToByte(_config.MinBrightness),
        });

        BroadcastPaintsTo(client);
    }

    private void BroadcastPaintsTo(ACTcpClient target)
    {
        if (!_config.PushScript) return;

        foreach (var car in LiveCars)
        {
            var source = car.Client!;
            if (!_states.TryGetValue(source.SessionId, out var state)) continue;

            if (state.BodyR != 0 || state.BodyG != 0 || state.BodyB != 0)
            {
                Send(target, new GhostProPaintRelayPacket
                {
                    CarIndex = car.SessionId, Part = 0,
                    R = state.BodyR, G = state.BodyG, B = state.BodyB,
                });
            }
            if (state.RimR != 0 || state.RimG != 0 || state.RimB != 0)
            {
                Send(target, new GhostProPaintRelayPacket
                {
                    CarIndex = car.SessionId, Part = 1,
                    R = state.RimR, G = state.RimG, B = state.RimB,
                });
            }
        }
    }

    private void OnDisconnected(ACTcpClient sender, EventArgs args)
    {
        var wasGhost = IsPassive(sender.SessionId);
        Clear(sender.SessionId);
        // A departing ghost must not leave its bit set for the next car in that
        // slot, so recompute and re-broadcast without them.
        if (wasGhost)
        {
            BroadcastState();
        }
    }

    public void Reset()
    {
        _states.Clear();
        LastReason = "";
    }

    private static byte ToByte(float fraction) =>
        (byte)Math.Clamp(Math.Round(fraction * 255f), 0, 255);

    private PlayerState GetState(byte sessionId)
    {
        if (!_states.TryGetValue(sessionId, out var state))
        {
            state = new PlayerState();
            _states[sessionId] = state;
        }
        return state;
    }
}