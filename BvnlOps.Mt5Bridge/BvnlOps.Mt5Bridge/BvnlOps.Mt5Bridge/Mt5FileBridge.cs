using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;

namespace BvnlOps.Mt5Bridge;

public sealed class Mt5FileBridge
{
    private readonly string _folder;
    private readonly ILogger<Mt5FileBridge> _logger;
    private readonly TimeSpan _staleThreshold;

    private static readonly JsonSerializerOptions _json = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
        WriteIndented = false,
    };

    public Mt5FileBridge(
        ILogger<Mt5FileBridge> logger,
        string? folder = null,
        TimeSpan? staleThreshold = null)
    {
        _logger = logger;
        _folder = folder
            ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "MetaQuotes", "Terminal", "Common", "Files");
        _staleThreshold = staleThreshold ?? TimeSpan.FromSeconds(30);
    }

    public AccountInfo? GetAccountInfo()
        => ReadFile<AccountFileDto>("bvnl_account.json")?.ToAccountInfo();

    public IReadOnlyList<Position> GetPositions()
        => ReadFile<PositionsFileDto>("bvnl_positions.json")?.Positions
               .Select(p => p.ToPosition()).ToList()
           ?? [];

    public Quote? GetQuote(string symbol)
        => ReadFile<QuoteFileDto>($"bvnl_price_{symbol.ToUpper()}.json")?.ToQuote(symbol);

    public async Task<CommandResult> SendCommandAsync(
        TradeCommand cmd,
        int timeoutMs = 5000,
        CancellationToken ct = default)
    {
        SafeDelete("bvnl_command_result.json");

        var payload = JsonSerializer.Serialize(new CommandFileDto(cmd), _json);
        await WriteFileAsync("bvnl_command.json", payload);
        _logger.LogInformation("MT5 command written: {Action} {Side} {Volume} {Symbol}",
            cmd.Action, cmd.Side, cmd.Volume, cmd.Symbol);

        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            await Task.Delay(200, ct);
            var result = ReadFile<CommandResultFileDto>("bvnl_command_result.json");
            if (result != null)
            {
                SafeDelete("bvnl_command_result.json");
                SafeDelete("bvnl_command.json");
                return result.ToCommandResult();
            }
        }

        return new CommandResult(false, "Timeout — EA did not respond within the time limit.",
            0, 0, DateTime.UtcNow);
    }

    public bool IsAccountDataFresh()   => IsFileFresh("bvnl_account.json");
    public bool IsPositionsDataFresh() => IsFileFresh("bvnl_positions.json");
    public bool IsQuoteFresh(string symbol) => IsFileFresh($"bvnl_price_{symbol.ToUpper()}.json");

    private T? ReadFile<T>(string filename) where T : class
    {
        var path = Path.Combine(_folder, filename);
        try
        {
            if (!File.Exists(path)) return null;
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            return JsonSerializer.Deserialize<T>(fs, _json);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not read {File}", filename);
            return null;
        }
    }

    private async Task WriteFileAsync(string filename, string content)
    {
        var path = Path.Combine(_folder, filename);
        var tmp  = path + ".tmp";
        await File.WriteAllTextAsync(tmp, content);
        File.Move(tmp, path, overwrite: true);
    }

    private bool IsFileFresh(string filename)
    {
        var path = Path.Combine(_folder, filename);
        if (!File.Exists(path)) return false;
        return DateTime.UtcNow - File.GetLastWriteTimeUtc(path) < _staleThreshold;
    }

    private void SafeDelete(string filename)
    {
        try { File.Delete(Path.Combine(_folder, filename)); } catch { }
    }
}

file record AccountFileDto(
    double Balance, double Equity, double Margin,
    double FreeMargin, double Profit,
    string Currency, int Leverage,
    string Server, string Login, string UpdatedAt)
{
    public AccountInfo ToAccountInfo() => new(
        Balance, Equity, Margin, FreeMargin, Profit,
        Currency, Leverage, Server, Login,
        DateTime.TryParse(UpdatedAt, out var dt) ? dt : DateTime.UtcNow);
}

file record PositionDto(
    long Ticket, string Symbol, string Type, double Volume,
    double OpenPrice, double CurrentPrice,
    double StopLoss, double TakeProfit,
    double Profit, double Swap, string Comment, string OpenTime)
{
    public Position ToPosition() => new(
        Ticket, Symbol, Type, Volume, OpenPrice, CurrentPrice,
        StopLoss, TakeProfit, Profit, Swap, Comment,
        DateTime.TryParse(OpenTime, out var dt) ? dt : DateTime.UtcNow);
}

file record PositionsFileDto(List<PositionDto> Positions);

file record QuoteFileDto(
    double Bid, double Ask, double Spread, string Time)
{
    public Quote ToQuote(string symbol) => new(
        symbol, Bid, Ask, Spread,
        DateTime.TryParse(Time, out var dt) ? dt : DateTime.UtcNow);
}

file record CommandFileDto(
    string Action, string Symbol, string Side,
    double Volume, double StopLoss, double TakeProfit,
    long Ticket, string Comment)
{
    public CommandFileDto(TradeCommand c)
        : this(c.Action, c.Symbol, c.Side, c.Volume,
               c.StopLoss, c.TakeProfit, c.Ticket, c.Comment) { }
}

file record CommandResultFileDto(
    bool Success, string Message, long Ticket, double Price, string Time)
{
    public CommandResult ToCommandResult() => new(
        Success, Message, Ticket, Price,
        DateTime.TryParse(Time, out var dt) ? dt : DateTime.UtcNow);
}
