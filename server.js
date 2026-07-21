/**
 * MT5 Live Bridge Server (Express + WebSockets)
 * Compatible with Railway, Heroku, Render, and Localhost
 */

const http = require('http');
const path = require('path');
const express = require('express');
const cors = require('cors');
const WebSocket = require('ws');

const PORT = process.env.PORT || 8080;

// In-Memory Data Store (M5: 900 candles, M15: 300 candles)
const state = {
    candlesM5: [],
    candlesM15: [],
    currentBid: 0,
    currentAsk: 0,
    symbol: 'XAUUSD',
    lastMt5Time: 0,
    isConnectedToMT5: false
};

const app = express();
app.use(cors());
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true, limit: '50mb' }));

// Serve all static frontend files (index.html, app.js, styles.css, images)
app.use(express.static(__dirname));

// Health check endpoint for Railway
app.get('/health', (req, res) => {
    res.json({
        status: 'running',
        mt5Connected: state.isConnectedToMT5,
        m5Count: state.candlesM5.length,
        m15Count: state.candlesM15.length,
        clients: wss ? wss.clients.size : 0
    });
});

// HTTP Endpoint for MT5 Expert Advisor (MQL5 WebRequest)
app.post('/api/mt5-data', (req, res) => {
    try {
        const payload = req.body;
        handleMt5Payload(payload);
        res.json({ status: 'ok', clientCount: wss ? wss.clients.size : 0 });
    } catch (err) {
        console.error('[Error] Invalid JSON from MT5 EA:', err.message);
        res.status(400).json({ status: 'error', message: err.message });
    }
});

// Fallback to index.html for root and SPA routing
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// Create HTTP Server & WebSocket Server
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Broadcast JSON to all connected WebSockets
function broadcast(data) {
    const jsonStr = JSON.stringify(data);
    wss.clients.forEach(client => {
        if (client.readyState === WebSocket.OPEN) {
            try {
                client.send(jsonStr);
            } catch (e) {
                console.error('[WebSocket] Send error:', e);
            }
        }
    });
}

wss.on('connection', (ws) => {
    console.log(`[WebSocket] Client connected. Total clients: ${wss.clients.size}`);

    // Send initial snapshot to newly connected client
    const initialPayload = {
        type: 'initial',
        symbol: state.symbol,
        currentBid: state.currentBid,
        currentAsk: state.currentAsk,
        candlesM5: state.candlesM5,
        candlesM15: state.candlesM15,
        mt5Connected: state.isConnectedToMT5
    };
    ws.send(JSON.stringify(initialPayload));

    ws.on('close', () => {
        console.log(`[WebSocket] Client disconnected. Remaining: ${wss.clients.size}`);
    });

    ws.on('error', (err) => {
        console.error('[WebSocket] Client error:', err);
    });
});

// Process Incoming MT5 Payload from MQL5 EA
function handleMt5Payload(payload) {
    state.lastMt5Time = Date.now();
    
    if (!state.isConnectedToMT5) {
        state.isConnectedToMT5 = true;
        console.log('[MT5] ✅ Connected to MetaTrader 5 EA!');
        broadcast({ type: 'status', mt5Connected: true });
    }

    const action = payload.action;

    if (action === 'initial') {
        // Initial payload containing 900 M5 candles and 300 M15 candles
        if (Array.isArray(payload.candlesM5)) {
            state.candlesM5 = payload.candlesM5.slice(-900);
        }
        if (Array.isArray(payload.candlesM15)) {
            state.candlesM15 = payload.candlesM15.slice(-300);
        }
        state.currentBid = payload.currentBid || state.currentBid;
        state.currentAsk = payload.currentAsk || state.currentAsk;
        state.symbol = payload.symbol || 'XAUUSD';

        console.log(`[MT5] 🚀 Received Initial Data: ${state.candlesM5.length} M5 candles, ${state.candlesM15.length} M15 candles.`);
        
        broadcast({
            type: 'initial',
            symbol: state.symbol,
            currentBid: state.currentBid,
            currentAsk: state.currentAsk,
            candlesM5: state.candlesM5,
            candlesM15: state.candlesM15,
            mt5Connected: true
        });
    } else if (action === 'tick') {
        // Real-Time Live Tick Update
        state.currentBid = payload.currentBid || state.currentBid;
        state.currentAsk = payload.currentAsk || state.currentAsk;
        
        const timeframe = payload.timeframe || 'M5';
        const updatedCandle = payload.candle;

        if (timeframe === 'M5' && state.candlesM5.length > 0 && updatedCandle) {
            state.candlesM5[state.candlesM5.length - 1] = updatedCandle;
        } else if (timeframe === 'M15' && state.candlesM15.length > 0 && updatedCandle) {
            state.candlesM15[state.candlesM15.length - 1] = updatedCandle;
        }

        // Broadcast lightweight tick payload
        broadcast({
            type: 'tick',
            timeframe: timeframe,
            currentBid: state.currentBid,
            currentAsk: state.currentAsk,
            candle: updatedCandle,
            mt5Connected: true
        });
    } else if (action === 'candle_close') {
        // Candle Close Event
        const timeframe = payload.timeframe || 'M5';
        const newCandle = payload.newCandle;
        const closedCandle = payload.closedCandle;

        if (timeframe === 'M5') {
            if (closedCandle && state.candlesM5.length > 0) {
                state.candlesM5[state.candlesM5.length - 1] = closedCandle;
            }
            if (newCandle) {
                state.candlesM5.push(newCandle);
                if (state.candlesM5.length > 900) state.candlesM5.shift(); // Keep exact 900 cap
            }
        } else if (timeframe === 'M15') {
            if (closedCandle && state.candlesM15.length > 0) {
                state.candlesM15[state.candlesM15.length - 1] = closedCandle;
            }
            if (newCandle) {
                state.candlesM15.push(newCandle);
                if (state.candlesM15.length > 300) state.candlesM15.shift(); // Keep exact 300 cap
            }
        }

        console.log(`[MT5] 🕯️ Candle Closed on ${timeframe}`);
        broadcast({
            type: 'candle_close',
            timeframe: timeframe,
            closedCandle: closedCandle,
            newCandle: newCandle,
            currentBid: state.currentBid,
            currentAsk: state.currentAsk,
            mt5Connected: true
        });
    }
}

// Heartbeat timer to monitor MT5 terminal connectivity
setInterval(() => {
    if (state.isConnectedToMT5 && Date.now() - state.lastMt5Time > 6000) {
        state.isConnectedToMT5 = false;
        console.warn('[MT5] ⚠️ Connection to MetaTrader 5 EA timed out.');
        broadcast({ type: 'status', mt5Connected: false });
    }
}, 3000);

server.listen(PORT, '0.0.0.0', () => {
    console.log(`====================================================`);
    console.log(`🚀 MT5 Live Express & WebSocket Bridge running on port ${PORT}`);
    console.log(`====================================================`);
});
