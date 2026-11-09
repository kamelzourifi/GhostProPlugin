using AssettoServer.Network.ClientMessages;

namespace GhostProPlugin.Packets;

// Wire format shared with lua/ghostpro.lua. Keys and field NAMES must match the
// Lua ac.OnlineEvent layouts exactly.
//
// AssettoServer derives the layout from these attributes (OnlineEventGenerator),
// not from the C# field order, and it REORDERS fields for packing using the same
// algorithm as CSP's ac_struct_item.lua. Declaration order here is therefore for
// readability only.
//
// Every packet below is small: the stock AC server caps OnlineEvent messages at
// 175 bytes, so budget widths, not strings.

// Client -> server: a ghost request. The client never asserts that it is
// already ghost; it asks, and the reply decides.
[OnlineEvent(Key = "ghostProReq")]
public class GhostProRequestPacket : OnlineEvent<GhostProRequestPacket>
{
    // "ask" or "revoke". A string, matching HardBrain's SetTime/SetWeather
    // convention, so both sides read the same shape.
    [OnlineEventField(Name = "mode", Size = 4)]
    public string Mode = "";

    [OnlineEventField(Name = "bots", Size = 1)]
    public bool Bots;
}

// Server -> client: the decision. Sent on every request so the client learns the
// answer instead of assuming its request was honoured.
[OnlineEvent(Key = "ghostProGrant")]
public class GhostProGrantPacket : OnlineEvent<GhostProGrantPacket>
{
    [OnlineEventField(Name = "passive", Size = 1)]
    public bool Passive;

    [OnlineEventField(Name = "allowBots", Size = 1)]
    public bool AllowBots;

    // 1 = server decides, 0 = permissive.
    [OnlineEventField(Name = "mode", Size = 1)]
    public byte Mode;

    // Brightness floor scaled 0..255. The client clamps its own picker too, but
    // only the server-side check cannot be bypassed by a modified client.
    [OnlineEventField(Name = "minBrightness", Size = 1)]
    public byte MinBrightness;
}

// Server -> all clients: bitmask of car indices that are passable. One packet
// covers a full grid. Bit 0 is never set, so a client cannot grant itself.
[OnlineEvent(Key = "ghostProState")]
public class GhostProStatePacket : OnlineEvent<GhostProStatePacket>
{
    [OnlineEventField(Name = "granted", Size = 4)]
    public uint Granted;
}

// Server -> clients, relaying a paint one player chose. The entry index travels
// explicitly: a receiver cannot map a session id to its own view of car indices.
[OnlineEvent(Key = "ghostProPaintRelay")]
public class GhostProPaintRelayPacket : OnlineEvent<GhostProPaintRelayPacket>
{
    [OnlineEventField(Name = "carIndex", Size = 1)]
    public byte CarIndex;

    [OnlineEventField(Name = "part", Size = 1)]
    public byte Part;

    [OnlineEventField(Name = "r", Size = 1)]
    public byte R;

    [OnlineEventField(Name = "g", Size = 1)]
    public byte G;

    [OnlineEventField(Name = "b", Size = 1)]
    public byte B;

    [OnlineEventField(Name = "reset", Size = 1)]
    public bool Reset;
}

// Client -> server: a paint the sender wants mirrored. The server enforces the
// brightness floor and decides whether to relay, so a client cannot bypass it by
// talking to peers directly.
[OnlineEvent(Key = "ghostProPaint")]
public class GhostProPaintPacket : OnlineEvent<GhostProPaintPacket>
{
    [OnlineEventField(Name = "part", Size = 1)]
    public byte Part;

    [OnlineEventField(Name = "r", Size = 1)]
    public byte R;

    [OnlineEventField(Name = "g", Size = 1)]
    public byte G;

    [OnlineEventField(Name = "b", Size = 1)]
    public byte B;

    [OnlineEventField(Name = "reset", Size = 1)]
    public bool Reset;
}

[OnlineEvent(Key = "ghostProTime")]
public class GhostProSetTimePacket : OnlineEvent<GhostProSetTimePacket>
{
    [OnlineEventField(Name = "mode", Size = 4)]
    public string Mode = "";

    [OnlineEventField(Name = "seconds", Size = 8)]
    public string Seconds = "";
}

[OnlineEvent(Key = "ghostProTimeAck")]
public class GhostProTimeAckPacket : OnlineEvent<GhostProTimeAckPacket>
{
    // The hour the server actually applied, so the client can tell "the server
    // took my request" from "my clock moved". Comparing clocks on the client is
    // unreliable: CSP renders the timestamp in a timezone, so the two rarely
    // agree to the minute.
    [OnlineEventField(Name = "seconds", Size = 8)]
    public string Seconds = "";

    // 0 = personal (only this driver), 1 = server-wide (an administrator).
    [OnlineEventField(Name = "scope", Size = 1)]
    public byte Scope;
}

[OnlineEvent(Key = "ghostProWeather")]
public class GhostProSetWeatherPacket : OnlineEvent<GhostProSetWeatherPacket>
{
    [OnlineEventField(Name = "mode", Size = 4)]
    public string Mode = "";

    // Name, not index. Numeric enum values shift between AssettoServer versions
    // and a shifted value would silently apply the wrong weather. Parsed server
    // side with Enum.TryParse, which fails closed on an unknown name.
    [OnlineEventField(Name = "type", Size = 24)]
    public string Type = "";
}