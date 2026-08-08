using System.ComponentModel;
using System.Text;
using System.Text.Json;
using BvnlOps.Mt5Bridge;
using ModelContextProtocol.Server;

namespace BvnlOps.Mcp;

[McpServerToolType]
public static class Mt5Tools
{
    private static readonly JsonSerializerOptions _json = new() { WriteIndented = true };

    [McpServerTool]
    [Description("Get MT5 account info: balance, equity, free margin, profit, currency, leverage. " +
                 "Returns an error message if the EA is not running or data is stale (>30 s old).")]
    public static string GetAccountInfo(Mt5FileBridge bridge)
    {
        if (!bridge.IsAccountDataFresh())
            return "Error: account data is stale or missing. Is BvnlOps_FileBridge.mq5 running on a chart?";

        var info = bridge.GetAccountInfo();
        if (info == null) return "Error: could not read account file.";

        return $"""
            Account:    {info.Login} @ {info.Server}
            Balance:    {info.Balance:F2} {info.Currency}
            Equity:     {info.Equity:F2} {info.Currency}
            Free Margin:{info.FreeMargin:F2} {info.Currency}
            Open P&L:   {info.Profit:F2} {info.Currency}
            Leverage:   1:{info.Leverage}
            Updated:    {info.UpdatedAt:HH:mm:ss} UTC
            """;
    }

    [McpServerTool]
    [Description("Get the current bid/ask quote for a symbol. " +
                 "Common symbols: XAUUSD (gold), EURUSD, GBPUSD, USDJPY, BTCUSD. " +
                 "The EA must be tracking the symbol — it auto-tracks whatever chart it is attached to " +
                 "plus any symbols listed in the EA's WatchList input.")]
    public static string GetPrice(
        Mt5FileBridge bridge,
        [Description("MT5 symbol name, e.g. XAUUSD or EURUSD")] string symbol)
    {
        var sym = symbol.Trim().ToUpper();
        if (!bridge.IsQuoteFresh(sym))
            return $"Error: no quote for {sym} — ensure the EA is tracking this symbol " +
                   $"(add it to the WatchList input or attach the EA to a {sym} chart).";

        var q = bridge.GetQuote(sym);
        if (q == null) return $"Error: could not read quote file for {sym}.";

        return $"""
            {q.Symbol}  Bid={q.Bid:F5}  Ask={q.Ask:F5}  Spread={q.Spread:F1} pts
            Time: {q.Time:HH:mm:ss} UTC
            """;
    }

    [McpServerTool]
    [Description("List all currently open positions on the MT5 account. " +
                 "Returns ticket, symbol, direction, volume, open price, current price, P&L.")]
    public static string GetOpenPositions(Mt5FileBridge bridge)
    {
        if (!bridge.IsPositionsDataFresh())
            return "Error: positions data is stale or missing. Is BvnlOps_FileBridge.mq5 running?";

        var positions = bridge.GetPositions();
        if (positions.Count == 0) return "No open positions.";

        var sb = new StringBuilder();
        sb.AppendLine($"Open positions ({positions.Count}):");
        foreach (var p in positions)
        {
            sb.AppendLine(
                $"  #{p.Ticket}  {p.Symbol}  {p.Type}  {p.Volume:F2} lots" +
                $"  @ {p.OpenPrice:F5}  now {p.CurrentPrice:F5}" +
                $"  SL={p.StopLoss:F5}  TP={p.TakeProfit:F5}" +
                $"  P&L={p.Profit:F2}  [{p.Comment}]");
        }
        return sb.ToString();
    }

    [McpServerTool]
    [Description("Place a market order on MT5. " +
                 "REQUIRES the environment variable BVNL_ALLOW_TRADING=1 to be set in claude_desktop_config.json. " +
                 "Always test on a demo account first. Risk is 100% yours.")]
    public static async Task<string> PlaceMarketOrder(
        Mt5FileBridge bridge,
        [Description("MT5 symbol, e.g. XAUUSD")] string symbol,
        [Description("BUY or SELL")] string side,
        [Description("Volume in lots, e.g. 0.01")] double volume,
        [Description("Stop loss price (0 = no SL)")] double stopLoss = 0,
        [Description("Take profit price (0 = no TP)")] double takeProfit = 0)
    {
        if (!TradingEnabled())
            return "Trading is disabled. Set BVNL_ALLOW_TRADING=1 in the MCP server env block " +
                   "in claude_desktop_config.json, then restart Claude Desktop.";

        if (volume <= 0) return "Error: volume must be > 0.";
        side = side.Trim().ToUpper();
        if (side is not "BUY" and not "SELL") return "Error: side must be BUY or SELL.";

        var cmd = new TradeCommand("OPEN", symbol.Trim().ToUpper(), side, volume, stopLoss, takeProfit);
        var result = await bridge.SendCommandAsync(cmd, timeoutMs: 8000);

        return result.Success
            ? $"Order placed: #{result.Ticket}  {side} {volume} {symbol} @ {result.Price:F5}  [{result.Time:HH:mm:ss} UTC]"
            : $"Order failed: {result.Message}";
    }

    [McpServerTool]
    [Description("Close an open position by ticket number. " +
                 "REQUIRES BVNL_ALLOW_TRADING=1.")]
    public static async Task<string> ClosePosition(
        Mt5FileBridge bridge,
        [Description("Position ticket number (get it from GetOpenPositions)")] long ticket)
    {
        if (!TradingEnabled())
            return "Trading is disabled. Set BVNL_ALLOW_TRADING=1 in claude_desktop_config.json.";

        if (ticket <= 0) return "Error: invalid ticket number.";

        var cmd = new TradeCommand("CLOSE", "", "", 0, Ticket: ticket);
        var result = await bridge.SendCommandAsync(cmd, timeoutMs: 8000);

        return result.Success
            ? $"Position #{ticket} closed @ {result.Price:F5}  [{result.Time:HH:mm:ss} UTC]"
            : $"Close failed: {result.Message}";
    }

    [McpServerTool]
    [Description("Modify the stop loss and/or take profit of an open position. " +
                 "REQUIRES BVNL_ALLOW_TRADING=1. Pass 0 to leave SL or TP unchanged.")]
    public static async Task<string> ModifyPosition(
        Mt5FileBridge bridge,
        [Description("Position ticket number")] long ticket,
        [Description("New stop loss price (0 = leave unchanged)")] double newStopLoss,
        [Description("New take profit price (0 = leave unchanged)")] double newTakeProfit)
    {
        if (!TradingEnabled())
            return "Trading is disabled. Set BVNL_ALLOW_TRADING=1 in claude_desktop_config.json.";

        if (ticket <= 0) return "Error: invalid ticket number.";

        var cmd = new TradeCommand("MODIFY", "", "", 0, newStopLoss, newTakeProfit, ticket);
        var result = await bridge.SendCommandAsync(cmd, timeoutMs: 5000);

        return result.Success
            ? $"Position #{ticket} modified: SL={newStopLoss:F5}  TP={newTakeProfit:F5}"
            : $"Modify failed: {result.Message}";
    }

    private static bool TradingEnabled() =>
        string.Equals(
            Environment.GetEnvironmentVariable("BVNL_ALLOW_TRADING"),
            "1",
            StringComparison.Ordinal);
}
