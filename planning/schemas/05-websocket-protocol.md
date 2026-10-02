# 05 — WebSocket Protocol (OBS Overlay)

> **Endpoint:** `wss://overlay.inflora.app/ws?token=<ok_xxx>`
> **Subprotocol:** `inflora-overlay.v1`
> **Encoding:** JSON UTF-8
> **Reconnect:** exponential backoff with jitter (200ms → 30s)

---

## 1. Connection lifecycle

```
Client                                         Server
  |                                                │
  |  WS Upgrade + token in URL + subprotocol hdr  |
  | ────────────────────────────────────────────▶ |
  |                                 │ Validate token (cache 60s)
  |                                 │ Per-streamer hub lookup
  |  HTTP 101 Switching Protocols                 |
  | ◀──────────────────────────────────────────── │
  |  {"type":"hello", ...}                       |
  | ◀──────────────────────────────────────────── │
  |                                                │
  |  ... heartbeat every 10s ...                 │
  |  ... donation frames with seq N+1, N+2 ...   │
  |                                                │
  |  ... (network drop)                           │
  |                                                │
  |  (reconnect after backoff)                    │
  |  WS Upgrade + new hello                       │
  |  {"type":"catch_up", last_seq: 41}            │
  | ────────────────────────────────────────────▶ |
  |  server replays 42..HWM                       │
  |  {"type":"donation", seq: 42, ...}           │
  | ◀──────────────────────────────────────────── │
  |  {"type":"catch_up_end", last_seq: 47}       │
  | ◀──────────────────────────────────────────── │
  |                                                │
  |  ... live events continue from seq 48 ...     │
```

---

## 2. Connection URL

```
wss://overlay.inflora.app/ws?token=ok_<full-token>
```

Optional query params:
- `?from_seq=42` — request catch-up starting from seq 42 (instead of client-sent `catch_up` frame).

Required headers:
- `Sec-WebSocket-Protocol: inflora-overlay.v1`
- `Origin: https://app.inflora.app` (CORS; reject if mismatch in production)

---

## 3. Server → Client frames

### 3.1 Hello (first frame after upgrade)

```json
{
  "type":         "hello",
  "streamer_id":  "abc-123-def-456",
  "server_time":  "2026-10-02T14:30:00.000Z",
  "replay_window_seconds": 600,
  "high_water_mark":       42,
  "version":     "1.0.0"
}
```

| Field | Type | Notes |
|---|---|---|
| `replay_window_seconds` | int | How far back the server can replay from NATS log. Client uses this to decide when catch-up is impossible. |
| `high_water_mark` | int | Current highest `seq` issued. Client treats anything ≤ this as already-seen-or-current. |
| `version` | string | Protocol version. Mismatch → reconnect attempt with different protocol. |

### 3.2 Heartbeat (every 10s)

```json
{
  "type": "heartbeat",
  "ts":   "2026-10-02T14:30:10.000Z",
  "seq":  42
}
```

- Sent every 10s.
- `seq` is current `high_water_mark`.
- If client doesn't receive heartbeat for 30s → consider connection dead, reconnect.

### 3.3 Donation (main event)

```json
{
  "type":       "donation",
  "seq":        43,
  "streamer_id":"abc-123-def-456",
  "ts":         "2026-10-02T14:30:11.000Z",
  "data": {
    "donation_id":         "uuid",
    "amount_idr":          50000,
    "platform_fee_idr":    5,
    "net_idr":             49995,
    "donor_display_name":  "Andi",
    "is_anonymous":        false,
    "message":             "Semangat streamingnya bang!"
  }
}
```

### 3.4 Donation failed (optional, streamer configurable)

```json
{
  "type":       "donation_failed",
  "seq":        44,
  "streamer_id":"abc-...",
  "ts":         "...",
  "data": {
    "donation_id":        "uuid",
    "donor_display_name": "Andi",
    "amount_idr":         50000,
    "failure_reason":     "USER_CANCELLED"
  }
}
```

### 3.5 Catch-up events (after `catch_up` request)

Same as `donation` / `donation_failed` frames, but ordered by seq.

### 3.6 Catch-up end

```json
{
  "type":      "catch_up_end",
  "last_seq":  47,
  "ts":        "2026-10-02T14:31:00Z"
}
```

Sent when replay finishes. Client should be caught up to live mode.

### 3.7 Error frame (before close)

```json
{
  "type":         "error",
  "code":         "INVALID_TOKEN" | "STREAMER_INACTIVE" | "RATE_LIMITED" | "INTERNAL",
  "message":      "human readable",
  "close_after":  true
}
```

Server closes WS after this. See close codes.

---

## 4. Client → Server frames

### 4.1 Catch-up request

```json
{
  "type":     "catch_up",
  "last_seq": 41
}
```

Server replays events from `last_seq + 1` to current HWM, then sends `catch_up_end`.

If client sends multiple `catch_up` requests → server treats as rate-limited (close 4429).

### 4.2 Pong (heartbeat response)

```json
{
  "type": "pong",
  "ts":   "2026-10-02T14:30:10.500Z"
}
```

Server-initiated heartbeat expects client to respond with pong within 5s. Missing pong → server closes with 4408.

### 4.3 Close (graceful)

WS Close frame:
- Code: `1000`
- Reason: any short string

---

## 5. Close codes

| Code | Meaning | Client action |
|---|---|---|
| `1000` | Normal closure | None |
| `1001` | Going away (server restart) | Reconnect immediately |
| `1006` | Abnormal closure (no close frame) | Reconnect with backoff |
| `4401` | Invalid token | Notify user "OBS URL expired — visit dashboard to rotate" |
| `4403` | Streamer inactive | Notify user "streamer account disabled" |
| `4408` | Heartbeat timeout | Reconnect with backoff |
| `4429` | Rate limited | Wait 60s before reconnect |
| `1011` | Internal server error | Reconnect with backoff |

---

## 6. Sequence number semantics

| Property | Value |
|---|---|
| Scope | Per streamer |
| Starts at | 1 on gateway boot for that streamer |
| Increments by | 1 per fanout to that streamer |
| Wraps at | `2^53 - 1` (JS safe int) |
| Monotonic | Yes, even across reconnects |

### Client invariants

- Client stores `lastSeq` in `localStorage` (key: `inflora_overlay_last_seq_<streamer_id>`).
- On every received frame, update `lastSeq = max(lastSeq, frame.seq)`.
- Persist `lastSeq` every 5s (debounced).
- On reconnect, send `catch_up` with `lastSeq`.

### Gateway invariants

- Sequence is per-streamer across all connected clients.
- Replay from NATS log respects seq order.
- Gaps allowed (e.g., 1, 2, 3, 5 — meaning 4 was filtered or undelivered).
- Wrap-around at `2^53 - 1`: gateway resets to 1; sends `catch_up_end` with `last_seq: 0` to force full replay (if available).

---

## 7. Reconnect algorithm (client reference)

```typescript
class OverlayClient {
  private ws: WebSocket | null = null;
  private lastSeq: number = 0;
  private reconnectAttempts = 0;
  private maxReconnectDelay = 30_000;
  private baseDelay = 200;
  
  start() {
    this.lastSeq = this.loadPersistedSeq();
    this.connect();
    
    // Persist lastSeq every 5s
    setInterval(() => this.persistSeq(), 5000);
  }
  
  private connect() {
    const url = `wss://overlay.inflora.app/ws?token=${this.token}`;
    this.ws = new WebSocket(url, ['inflora-overlay.v1']);
    
    this.ws.onopen = () => {
      this.reconnectAttempts = 0;
      // catch_up is sent after we receive 'hello'
    };
    
    this.ws.onmessage = (e) => {
      const frame = JSON.parse(e.data);
      this.handleFrame(frame);
    };
    
    this.ws.onclose = (e) => {
      this.handleClose(e.code);
    };
    
    this.ws.onerror = () => {
      // onclose will fire after this
    };
  }
  
  private handleFrame(frame: any) {
    switch (frame.type) {
      case 'hello':
        // First frame; catch up if needed
        if (this.lastSeq > 0 && this.lastSeq < frame.high_water_mark) {
          this.send({ type: 'catch_up', last_seq: this.lastSeq });
        }
        break;
        
      case 'heartbeat':
        this.send({ type: 'pong', ts: new Date().toISOString() });
        break;
        
      case 'donation':
      case 'donation_failed':
        if (frame.seq > this.lastSeq) {
          this.lastSeq = frame.seq;
          this.renderAlert(frame);
        }
        break;
        
      case 'catch_up_end':
        // Replay finished; resume live mode
        this.live = true;
        break;
        
      case 'error':
        console.error('overlay error', frame.code, frame.message);
        break;
    }
  }
  
  private handleClose(code: number) {
    if (code === 4401) {
      // Token bad — notify streamer
      this.notifyTokenExpired();
      return;
    }
    if (code === 4403) {
      // Streamer disabled
      this.notifyStreamerDisabled();
      return;
    }
    
    // Exponential backoff with jitter
    const delay = Math.min(
      this.maxReconnectDelay,
      this.baseDelay * Math.pow(2, this.reconnectAttempts) +
      Math.random() * 200
    );
    this.reconnectAttempts++;
    setTimeout(() => this.connect(), delay);
  }
  
  private renderAlert(frame: any) {
    // Hand to overlay renderer (DOM/Canvas)
    this.renderer.show(frame.data);
  }
}
```

---

## 8. Latency budget

| Step | p99 budget |
|---|---|
| Webhook → ledger commit | < 500ms |
| Internal: ledger commit → NATS publish | < 50ms |
| NATS → gateway consume | < 100ms |
| Gateway → WS frame dispatch | < 50ms |
| **Webhook → OBS popup** | **< 700ms** |

If over budget, check in this order:
1. DB latency (`pg_stat_statements`)
2. NATS consumer lag
3. WS hub lock contention
4. Network between server and OBS client

---

## 9. Failure modes & client UX

| Symptom | Client behavior |
|---|---|
| WS won't upgrade | Show "Cannot connect to Inflora overlay" overlay |
| Heartbeat missed > 30s | Show "Reconnecting..." pill in OBS |
| Token rejected (4401) | Show "OBS URL expired — visit dashboard to rotate" |
| Streamer inactive (4403) | Show "Streamer account is currently disabled" |
| Server restart (1001) | Silent reconnect; no UX change |
| Catch-up gap too large | Show "Some recent donations may not have appeared" (best-effort) |
| Catch-up > replay_window | Show "Reconnecting..." with a spinner |

---

## 10. Security

- TLS required (`wss://`). Reject plain `ws://` in production.
- Token validated against `tolkien` on connect. Cache result for 60s.
- Token can be revoked server-side: server sends `error: INVALID_TOKEN` + close 4401.
- Origin check: `Origin` header must match `https://app.inflora.app` in production.
- Rate limit: max 100 connections per streamer. Beyond that, close 4429.
- Per-IP rate limit: max 10 new connections/min/IP. Beyond that, close 4429.

---

## 11. Observability

Gateway exports per-connection metrics:
- `ws_connections_active{streamer_id}` (gauge)
- `ws_frames_sent_total{type}` (counter)
- `ws_reconnect_attempts_total{streamer_id}` (counter)
- `ws_catchup_events_replayed_total` (counter)

Logs structured JSON per `00-frozen-contracts.md` §10.

---

*Pin this file. Client and server implementations must match exactly. Breaking changes require a new subprotocol version (`inflora-overlay.v2`).*