using JetBrains.Annotations;
using YamlDotNet.Serialization;

namespace GhostProPlugin;

[UsedImplicitly(ImplicitUseKindFlags.Assign, ImplicitUseTargetFlags.WithMembers)]
public class GhostProConfiguration
{
    [YamlMember(Description = "Enable the plugin")]
    public bool Enabled { get; init; } = true;

    [YamlMember(Description = "Server decides who may pass through. Turn off to let every client decide for itself (GhostPassive v25 behaviour)")]
    public bool Authoritative { get; init; } = true;

    [YamlMember(Description = "Both the requester and the driver being passed through must have ghost mode enabled")]
    public bool RequireConsent { get; init; } = true;

    [YamlMember(Description = "Only administrators may use ghost mode")]
    public bool AdminsOnly { get; init; } = false;

    [YamlMember(Description = "Allow ghosting AI/traffic cars")]
    public bool AllowBots { get; init; } = false;

    [YamlMember(Description = "Tell all clients whenever the ghost set changes")]
    public bool BroadcastGhostState { get; init; } = true;

    [YamlMember(Description = "Let players send their car colour to other drivers")]
    public bool AllowRemotePaint { get; init; } = true;

    [YamlMember(Description = "Reject colours darker than this (0-1). 0 disables the floor")]
    public float MinBrightness { get; init; } = 0f;

    [YamlMember(Description = "Personal time-of-day and weather, applied per driver")]
    public bool PersonalTime { get; init; } = true;

    [YamlMember(Description = "An admin's time/weather choice applies to the WHOLE server instead of only themselves. Off means even an admin gets a personal override, which is what a private-practice server usually wants")]
    public bool AdminChangeIsGlobal { get; init; } = false;

    [YamlMember(Description = "Push the bundled ghostpro.lua to every client. Off = the plugin only does server-side work (personal time/weather) and the players keep using their own client script. Turning this on pushes a second online script, which older CSP builds refuse and then drop the connection")]
    public bool PushScript { get; init; } = false;

    [YamlMember(Description = "Split the per-second weather broadcast per client while someone uses personal time, so their sky is not overwritten a second later. Off = personal time is pushed once and lost on the next tick (only useful as a fallback if the split misbehaves)")]
    public bool PersonalWeatherSplit { get; init; } = true;

    [YamlMember(Description = "Time/weather features require EnableWeatherFx on the server")]
    public bool WeatherFx { get; init; } = true;

    [YamlMember(Description = "Restrict the weather menu to this list (WeatherFxType names). Empty = all the server supports")]
    public string[] WeatherAllowList { get; init; } = [];

    [YamlMember(Description = "Seconds between the client's ghost-state announcement (0.5-10)")]
    public int AnnounceIntervalSeconds { get; init; } = 4;

    [YamlMember(Description = "Drop a car's ghost state after this many seconds of silence")]
    public int StateTtlSeconds { get; init; } = 14;
}