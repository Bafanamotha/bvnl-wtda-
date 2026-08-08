namespace BvnlOps.Mt5Bridge;

public record AccountInfo(
    double Balance,
    double Equity,
    double Margin,
    double FreeMargin,
    double Profit,
    string Currency,
    int Leverage,
    string Server,
    string Login,
    DateTime UpdatedAt);

public record Quote(
    string Symbol,
    double Bid,
    double Ask,
    double Spread,
    DateTime Time);

public record Position(
    long Ticket,
    string Symbol,
    string Type,
    double Volume,
    double OpenPrice,
    double CurrentPrice,
    double StopLoss,
    double TakeProfit,
    double Profit,
    double Swap,
    string Comment,
    DateTime OpenTime);

public record TradeCommand(
    string Action,
    string Symbol,
    string Side,
    double Volume,
    double StopLoss    = 0,
    double TakeProfit  = 0,
    long   Ticket      = 0,
    string Comment     = "BVNL-MCP");

public record CommandResult(
    bool   Success,
    string Message,
    long   Ticket,
    double Price,
    DateTime Time);
