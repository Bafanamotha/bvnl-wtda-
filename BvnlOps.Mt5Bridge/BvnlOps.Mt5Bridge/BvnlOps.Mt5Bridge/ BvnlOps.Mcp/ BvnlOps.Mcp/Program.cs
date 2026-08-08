using BvnlOps.Mt5Bridge;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var builder = Host.CreateApplicationBuilder(args);

// ALL logs go to stderr — stdout is reserved for JSON-RPC frames.
// A single stray Console.WriteLine corrupts the stream and drops Claude's connection.
builder.Logging.ClearProviders();
builder.Logging.AddConsole(o =>
{
    o.LogToStandardErrorThreshold = LogLevel.Trace;
});
builder.Logging.SetMinimumLevel(LogLevel.Information);

// Optional: override the bridge folder via env var for non-standard MT5 installs.
// e.g. set BVNL_BRIDGE_FOLDER=D:\MT5\MQL5\Files  in claude_desktop_config.json env block.
var bridgeFolder = Environment.GetEnvironmentVariable("BVNL_BRIDGE_FOLDER");

builder.Services.AddSingleton<Mt5FileBridge>(sp =>
    new Mt5FileBridge(
        sp.GetRequiredService<ILogger<Mt5FileBridge>>(),
        folder: string.IsNullOrEmpty(bridgeFolder) ? null : bridgeFolder));

builder.Services
    .AddMcpServer()
    .WithStdioServerTransport()
    .WithToolsFromAssembly();

await builder.Build().RunAsync();
