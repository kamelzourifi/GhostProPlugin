using AssettoServer.Server.Plugin;
using AssettoServer.Server.Weather.Implementation;
using Autofac;
using Microsoft.Extensions.Hosting;

namespace GhostProPlugin;

public class GhostProModule : AssettoServerModule<GhostProConfiguration>
{
    protected override void Load(ContainerBuilder builder)
    {
        // Registered after the core's WeatherModule, so Autofac resolves this
        // one as IWeatherImplementation. It forwards to the core implementation
        // unless somebody has a personal sky.
        builder.RegisterType<PersonalWeatherImplementation>()
            .As<IWeatherImplementation>()
            .SingleInstance();

        builder.RegisterType<GhostProScriptPusher>()
            .AsSelf()
            .As<IHostedService>()
            .SingleInstance();

        builder.RegisterType<GhostStateService>()
            .AsSelf()
            .SingleInstance();

        builder.RegisterType<GhostProPlugin>()
            .AsSelf()
            .As<IHostedService>()
            .SingleInstance();
    }
}