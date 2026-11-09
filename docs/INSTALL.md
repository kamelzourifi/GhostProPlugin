# GhostProPlugin

An AssettoServer plugin that merges GhostPassive v25, Car Customizer's visual
language, and the HardBrain free plugins into one server-pushed CSP script.

## What replaced what

| Source | What was taken |
|---|---|
| `GhostPassive_v25.lua` | Ghost mode, body/rim colour, theme system, spring-animated lock button |
| Car Customizer | Theme tokens, the three appearances, finish/colour-panel layout |
| HardBrain `SpeedoPlugin` | Speedo HUD, drag to move, wheel to resize |
| HardBrain `HardbrainMenuPlugin` | Menu tabs, ghost-on-teleport, skin cycling, time/weather commands |
| HardBrain `PersonalTimePlugin` | Server-side per-driver time and weather, admin-global override |

## How it differs from GhostPassive v25

v25 was peer-to-peer: every client decided for itself, and a modified client
could claim any state. Every client also broadcast to every other client.

Here the server is the only authority:

- A client **asks**; the server **decides** and the decision is sent back.
- Paint relays **through** the server, so the brightness floor cannot be bypassed.
- Collision permission arrives as a bitmask, one packet for a full grid.
- Bit 0 is never granted, so a client cannot grant itself.

With `Authoritative: false` it degrades to v25's behaviour, which is what makes
it safe to test on a server you do not control yet.

## Requirements

- **AssettoServer 0.0.55** — any build; the plugin is built against the exact
  one you run (see Build).
- **CSP 2651+**
- `EnableClientMessages: true` in `cfg/extra_cfg.yml`

The plugin throws at startup if `EnableClientMessages` is false. That is
deliberate: loading successfully but doing nothing looks like a working install.

| AssettoServer | TFM | SDK needed to build |
|---|---|---|
| `0.0.55+503edd87f3` | net9.0 | .NET 9 |
| `0.0.55-pre42` | net11.0 | .NET 11 |

## Build

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Commit pre42
```

The script fetches AssettoServer, builds the plugin, then verifies the result
will load. The sources are not committed (~117 MB of someone else's code) and
cannot be avoided: the types this plugin uses — `CSPClientMessageTypeManager`,
`OnlineEvent<T>`, `EntryCarManager` — live in the server, not in a NuGet package.

`-Commit` takes the version from the first line of your server log. Both forms
work, including the bare suffix, which is resolved through the tags API:

```
AssettoServer 0.0.55-pre42         ->  -Commit pre42
AssettoServer 0.0.55+503edd87f3    ->  -Commit 503edd87f3
```

The **minor version is not enough**. A plugin binds to the exact assembly
versions the sources it was built against declare, and the server only ships the
versions its own build resolved. Building against a newer AssettoServer compiles
cleanly and then fails at startup:

```
ReflectionTypeLoadException: Unable to load one or more of the requested types
System.IO.FileNotFoundException: 'AssettoServer, Version=1.0.0.0'
```

Nothing in the build output mentions it. That is why `build.ps1` finishes by
reading the plugin's assembly-reference table and comparing it against the host
assemblies, and refuses to produce a deployable folder on a mismatch.

The target framework is read from the server's own `.csproj` and passed to the
plugin build, so `net9.0` and `net11.0` both work without editing anything. If
the required SDK is missing the script says which one; a user-local install is
used automatically when present:

```powershell
Invoke-WebRequest https://dot.net/v1/dotnet-install.ps1 -OutFile dotnet-install.ps1
powershell -ExecutionPolicy Bypass -File dotnet-install.ps1 -Channel 11.0
```

### Two files that are deliberately NOT generated

`runtimeconfig.json` and `deps.json` are suppressed, matching AssettoServer's
own `Plugin.props` — the host supplies both when it loads a plugin.

Generating them is not harmless. The generated runtimeconfig pins the exact
runtime version of the **build** machine, so a plugin built with a preview SDK
carries `"version": "11.0.0-rc.1.26425.128"`, and `rollForward: LatestMinor` does
not carry a prerelease requirement onto a stable `11.0.x`. The server then
rejects the plugin with *"You must install or update .NET to run this
application"*, which blames the runtime instead of the plugin.

Deploy exactly two things:

```
GhostProPlugin.dll
lua/ghostpro.lua
```

### Portability constraint

The plugin deliberately uses only the API surface present in every supported
AssettoServer build. Two convenient members are **not** used because they are
internal or absent depending on commit:

| Member | Status |
|---|---|
| `EntryCarManager.ConnectedCars` | internal / absent — use `EntryCars` |
| `ACTcpClient.SendPacketUdp` | internal / absent — use `SendPacket` |

Referencing either compiles against a newer checkout and breaks loading on an
older server, for the same reason as above.

### Output

`src/GhostProPlugin/bin/Release/win-x64/` — `.dll`, `.deps.json`,
`.runtimeconfig.json`, `lua/ghostpro.lua`. Copy the folder to
`<server>/plugins/GhostProPlugin`.

The folder name must match the `EnablePlugins` entry exactly, or the server logs
`No plugin found with name …`.

## Configure

See [`extra_cfg.example.yml`](extra_cfg.example.yml). At minimum:

```yaml
EnableClientMessages: true
MinimumCSPVersion: 2651

EnablePlugins:
  - GhostProPlugin

---
#!GhostProConfiguration
Enabled: true
Authoritative: true
RequireConsent: true
```

## Keys

| Key | Action |
|---|---|
| `M` | Toggle the menu |
| `G` | Toggle ghost mode (asks the server) |
| `C` | Colour picker |
| `P` | Perf mode — hide cars beyond 260 m |
| `H` | Hide all UI |
| `Ctrl+T` | Cycle theme |

Speedo: drag to move, mouse wheel over it to resize. Both persist.

## Two things worth knowing

**Ghost consent is real, not cosmetic.** `RequireConsent: true` means your
request is only granted if the driver being passed through has ghost mode on
too. That is a deliberate departure from v25, where one player's toggle made
everybody passable. If you want the old behaviour, set `RequireConsent: false`
and leave `Authoritative: true`.

**Paint cannot reach a remote Car Customizer.** Car Customizer's backend is
bound to car 0 — every entry point is literal:

```lua
cc/csp.lua:36   ac.findNodes('carRoot:0')
cc/csp.lua:42   ac.INIConfig.carConfig(0)
cc/csp.lua:345  assert(ac.getCarID(0) == self.carID and ...)
```

So GhostPro writes remote-car materials directly (`setMaterialTexture` on the
matched meshes). Your own car goes through the same path. Wiring the remote
cars to Car Customizer would mean patching Car Customizer, which is a separate
change.

## Licence

Same family as AssettoServer: **AGPL-3.0**.