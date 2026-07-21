//+------------------------------------------------------------------+
//|                                        MT5_Live_Streamer.mq5     |
//|                    Real-Time Data Streamer for MT5 Web Simulator |
//+------------------------------------------------------------------+
#property copyright "Antigravity AI"
#property link      "http://127.0.0.1:8080"
#property version   "1.00"
#property description "Streams real-time M5 (900 candles) and M15 (300 candles) data to Local Bridge Server"

// Input Parameters
input string   InpServerUrl = "http://127.0.0.1:8080/api/mt5-data"; // Local or Railway Server URL
input int      InpM5History  = 900;                                   // M5 Candle History Count
input int      InpM15History = 300;                                   // M15 Candle History Count

// Global State Trackers
datetime g_lastM5Time  = 0;
datetime g_lastM15Time = 0;
double   g_lastBid     = 0;
double   g_lastAsk     = 0;
double   g_lastM5Close = 0;

//+------------------------------------------------------------------+
//| Helper: Format MqlRates struct into JSON string                  |
//+------------------------------------------------------------------+
string RateToJson(const MqlRates &rate)
{
   datetime t = rate.time;
   MqlDateTime dt;
   TimeToStruct(t, dt);
   
   string dateStr = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
   string timeStr = StringFormat("%02d:%02d", dt.hour, dt.min);
   
   return StringFormat("{\"time\":\"%sT%02d:%02d:00Z\",\"timeLabel\":\"%s\",\"dateLabel\":\"%s\",\"open\":%.3f,\"high\":%.3f,\"low\":%.3f,\"close\":%.3f,\"volume\":%d}",
                       dateStr, dt.hour, dt.min, timeStr, dateStr,
                       rate.open, rate.high, rate.low, rate.close, (long)rate.tick_volume);
}

//+------------------------------------------------------------------+
//| Helper: Send JSON Payload via WebRequest HTTP POST                |
//+------------------------------------------------------------------+
bool SendJsonPayload(string json)
{
   char postData[];
   char resultData[];
   string responseHeaders;
   string headers = "Content-Type: application/json\r\n";
   
   int len = StringLen(json);
   StringToCharArray(json, postData, 0, len, CP_UTF8);
   
   // Ensure array size matches string length without trailing null
   ArrayResize(postData, len);
   
   ResetLastError();
   int res = WebRequest("POST", InpServerUrl, headers, 1000, postData, resultData, responseHeaders);
   
   if (res == -1)
   {
      int err = GetLastError();
      if (err == 4014) // ERR_WEBREQUEST_INVALID_URL
      {
         Print("ERROR: WebRequest not allowed for URL '", InpServerUrl, "'. Please add it to Tools -> Options -> Expert Advisors -> Allow WebRequest.");
      }
      return false;
   }
   return (res == 200);
}

//+------------------------------------------------------------------+
//| Helper: Send Initial 900 M5 & 300 M15 Candles                    |
//+------------------------------------------------------------------+
void SendInitialData()
{
   MqlRates ratesM5[];
   MqlRates ratesM15[];
   
   ArraySetAsSeries(ratesM5, false);
   ArraySetAsSeries(ratesM15, false);
   
   int countM5  = CopyRates(_Symbol, PERIOD_M5, 0, InpM5History, ratesM5);
   int countM15 = CopyRates(_Symbol, PERIOD_M15, 0, InpM15History, ratesM15);
   
   if (countM5 <= 0 || countM15 <= 0)
   {
      Print("WARNING: Waiting for price data history to load...");
      return;
   }
   
   MqlTick lastTick;
   SymbolInfoTick(_Symbol, lastTick);
   
   string jsonM5 = "[";
   for (int i = 0; i < countM5; i++)
   {
      jsonM5 += RateToJson(ratesM5[i]);
      if (i < countM5 - 1) jsonM5 += ",";
   }
   jsonM5 += "]";
   
   string jsonM15 = "[";
   for (int i = 0; i < countM15; i++)
   {
      jsonM15 += RateToJson(ratesM15[i]);
      if (i < countM15 - 1) jsonM15 += ",";
   }
   jsonM15 += "]";
   
   string json = StringFormat("{\"action\":\"initial\",\"symbol\":\"%s\",\"currentBid\":%.3f,\"currentAsk\":%.3f,\"candlesM5\":%s,\"candlesM15\":%s}",
                              _Symbol, lastTick.bid, lastTick.ask, jsonM5, jsonM15);
   
   if (SendJsonPayload(json))
   {
      Print("✅ Initial Data Sent Successfully: ", countM5, " M5 candles & ", countM15, " M15 candles.");
      g_lastM5Time  = ratesM5[countM5 - 1].time;
      g_lastM15Time = ratesM15[countM15 - 1].time;
      g_lastBid     = lastTick.bid;
      g_lastAsk     = lastTick.ask;
      g_lastM5Close = ratesM5[countM5 - 1].close;
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("🚀 Starting MT5 Live Streamer EA for ", _Symbol);
   
   // Send initial data snapshot
   SendInitialData();
   
   // Fast 100ms timer for low-latency tick streaming
   EventSetMillisecondTimer(100);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("🛑 MT5 Live Streamer EA Stopped.");
}

//+------------------------------------------------------------------+
//| Expert timer function (Sub-100ms Live Streaming)                 |
//+------------------------------------------------------------------+
void OnTimer()
{
   MqlTick tick;
   if (!SymbolInfoTick(_Symbol, tick)) return;
   
   MqlRates ratesM5[];
   MqlRates ratesM15[];
   ArraySetAsSeries(ratesM5, true);
   ArraySetAsSeries(ratesM15, true);
   
   if (CopyRates(_Symbol, PERIOD_M5, 0, 2, ratesM5) < 2) return;
   if (CopyRates(_Symbol, PERIOD_M15, 0, 2, ratesM15) < 2) return;
   
   datetime currentM5Time  = ratesM5[0].time;
   datetime currentM15Time = ratesM15[0].time;
   
   // Check M5 Candle Close Event
   if (g_lastM5Time != 0 && currentM5Time > g_lastM5Time)
   {
      string jsonClose = StringFormat("{\"action\":\"candle_close\",\"symbol\":\"%s\",\"timeframe\":\"M5\",\"closedCandle\":%s,\"newCandle\":%s,\"currentBid\":%.3f,\"currentAsk\":%.3f}",
                                      _Symbol, RateToJson(ratesM5[1]), RateToJson(ratesM5[0]), tick.bid, tick.ask);
      SendJsonPayload(jsonClose);
      g_lastM5Time = currentM5Time;
      Print("🕯️ M5 Candle Closed");
      return;
   }
   
   // Check M15 Candle Close Event
   if (g_lastM15Time != 0 && currentM15Time > g_lastM15Time)
   {
      string jsonClose15 = StringFormat("{\"action\":\"candle_close\",\"symbol\":\"%s\",\"timeframe\":\"M15\",\"closedCandle\":%s,\"newCandle\":%s,\"currentBid\":%.3f,\"currentAsk\":%.3f}",
                                         _Symbol, RateToJson(ratesM15[1]), RateToJson(ratesM15[0]), tick.bid, tick.ask);
      SendJsonPayload(jsonClose15);
      g_lastM15Time = currentM15Time;
      Print("🕯️ M15 Candle Closed");
      return;
   }
   
   // Live Tick Update (Send if price or current candle updated)
   if (tick.bid != g_lastBid || tick.ask != g_lastAsk || ratesM5[0].close != g_lastM5Close)
   {
      g_lastBid     = tick.bid;
      g_lastAsk     = tick.ask;
      g_lastM5Close = ratesM5[0].close;
      
      string jsonTick = StringFormat("{\"action\":\"tick\",\"symbol\":\"%s\",\"timeframe\":\"M5\",\"currentBid\":%.3f,\"currentAsk\":%.3f,\"candle\":%s}",
                                     _Symbol, tick.bid, tick.ask, RateToJson(ratesM5[0]));
      SendJsonPayload(jsonTick);
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   OnTimer();
}
//+------------------------------------------------------------------+
