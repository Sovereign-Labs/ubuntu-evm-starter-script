-- ============================================================================
-- nginx-proxy-helpers.lua
-- ============================================================================
--
-- Shared helper functions for nginx rate limiting and WebSocket proxying.
-- This module is loaded once at nginx startup (via init_by_lua_block) and
-- cached by OpenResty's Lua module system for all subsequent requests.
--
-- ARCHITECTURE OVERVIEW:
--
--   Client <---> Nginx (this module) <---> Backend (leader or follower)
--
--   This module handles:
--   1. Token bucket rate limiting (per client IP)
--   2. Request routing (leader vs follower based on endpoint/method)
--   3. WebSocket proxying with bidirectional message forwarding
--   4. HTTP request processing with rate limit headers
--
-- RATE LIMITING:
--   Uses a token bucket algorithm with per-IP buckets stored in shared memory.
--   Each request/message costs tokens; buckets refill at REFILL_RATE tokens/sec.
--   Atomic locking via spinlock prevents race conditions across workers.
--
-- WEBSOCKET PROXY:
--   Two modes of operation:
--   - JSON-RPC (/rpc): Per-message routing based on method name
--   - REST WebSocket (*.../ws): Fixed routing based on endpoint config
--
--   Threading model:
--   - Main thread: client_to_backend() - reads client frames, forwards to backend
--   - Spawned thread(s): backend_to_client() - reads backend frames, forwards to client
--
-- BACKEND ROUTING:
--   - Leader: Handles write operations (transactions, state changes)
--   - Follower: Handles read operations (queries, subscriptions)
--   - Single backend mode: When leader == follower, all traffic uses leader
--
-- ============================================================================

local M = {}

-- Cache resty libraries at module load time (avoids per-request require overhead)
local ws_server = require "resty.websocket.server"
local ws_client = require "resty.websocket.client"

-- ============================================================================
-- CONSTANTS
-- ============================================================================
-- These can be overridden by setting globals BEFORE requiring this module:
--   BUCKET_CAPACITY = 100
--   REFILL_RATE = 50
--   proxy = require "nginx-proxy-helpers"
M.WS_TIMEOUT_MS = WS_TIMEOUT_MS or 60000         -- WebSocket timeout
M.WS_CLIENT_MAX_PAYLOAD = 20480                  -- Max payload from client (20KB)
M.WS_BACKEND_MAX_PAYLOAD = 1048576               -- Max payload from backend (1MB)
M.BUCKET_TTL_SEC = 3600                          -- Token bucket TTL (1 hour)
M.BACKEND_REFRESH_INTERVAL_SEC = 0.2             -- Backend IP refresh interval (200ms)
M.SPINLOCK_INITIAL_WAIT_SEC = 0.001              -- Initial spinlock wait
M.SPINLOCK_MAX_WAIT_SEC = 0.05                   -- Max spinlock wait
M.SPINLOCK_MAX_ATTEMPTS = 10                     -- Max spinlock attempts

-- Token bucket configuration
M.BUCKET_CAPACITY = BUCKET_CAPACITY or 150  -- Maximum tokens
M.REFILL_RATE = REFILL_RATE or 150          -- Tokens added per second

-- JSON-RPC subscription costs (Infura-style pricing model)
M.SUBSCRIBE_COST = 5                    -- Cost for eth_subscribe/eth_unsubscribe call
M.JSONRPC_PUSHED_EVENT_COST = 80        -- Cost per eth_subscription event pushed from backend

-- ============================================================================
-- REST ENDPOINT CONFIGURATION
-- ============================================================================
-- HTTP endpoints use:
--   cost: Number of tokens consumed per request (includes response)
--   use_leader: true = route to leader (writes), false = route to follower (reads)
--
-- WebSocket endpoints (ending in /ws) use:
--   client_request_cost: Tokens per client message (0 for subscribe-only)
--   backend_push_cost: Tokens per backend push (0 for request/response style)
--   use_leader: true = route to leader (writes), false = route to follower (reads)
--
-- Parameterized paths use {param} syntax (matched via pattern at runtime).
--
-- Cost guidelines:
--   0    = Free (e.g., responses to client requests on bidirectional WS)
--   5    = Cheap operations (health checks, simple metadata)
--   80   = Standard operations (single record lookups, transactions, subscription events)
--   255  = Expensive operations (list queries, log searches)
--   300  = Very expensive (simulations, gas estimation)
--   1000 = Extremely expensive (debug traces, nested expansions)
M.rest_endpoints = {
    -- HEALTH
    ["/health"] = { cost = 1, use_leader = false },

    -- LEDGER: SLOTS (worst case: children=1 returns all batches->txs->events)
    ["/ledger/slots"] = { cost = 1000, use_leader = false },
    ["/ledger/slots/latest"] = { cost = 1000, use_leader = false },
    ["/ledger/slots/finalized"] = { cost = 1000, use_leader = false },
    ["/ledger/slots/{slotId}"] = { cost = 1000, use_leader = false },
    ["/ledger/slots/{slotId}/events"] = { cost = 1000, use_leader = false },
    ["/ledger/slots/latest/ws"] = { client_request_cost = 0, backend_push_cost = 80, use_leader = false },
    ["/ledger/slots/finalized/ws"] = { client_request_cost = 0, backend_push_cost = 80, use_leader = false },

    -- LEDGER: BATCHES (can contain many txs, each with events)
    ["/ledger/batches/{batchId}"] = { cost = 3000, use_leader = false },

    -- LEDGER: TRANSACTIONS
    ["/ledger/txs"] = { cost = 255, use_leader = false },        -- list query
    ["/ledger/txs/{txId}"] = { cost = 80, use_leader = false },  -- single record

    -- NESTED LOOKUPS
    ["/ledger/slots/{slotId}/batches/{batchOffset}"] = { cost = 3000, use_leader = false },
    ["/ledger/slots/{slotId}/batches/{batchOffset}/txs/{txOffset}"] = { cost = 80, use_leader = false },
    ["/ledger/slots/{slotId}/batches/{batchOffset}/txs/{txOffset}/events/{eventOffset}"] = { cost = 80, use_leader = false },
    ["/ledger/batches/{batchId}/txs/{txOffset}"] = { cost = 80, use_leader = false },
    ["/ledger/batches/{batchId}/txs/{txOffset}/events/{eventOffset}"] = { cost = 80, use_leader = false },
    ["/ledger/txs/{txId}/events/{eventOffset}"] = { cost = 80, use_leader = false },

    -- LEDGER: EVENTS (no children param)
    ["/ledger/events"] = { cost = 255, use_leader = false },
    ["/ledger/events/latest"] = { cost = 80, use_leader = false },
    ["/ledger/events/{eventId}"] = { cost = 80, use_leader = false },

    -- LEDGER: PROOFS
    ["/ledger/aggregated-proofs/latest"] = { cost = 80, use_leader = false },
    ["/ledger/aggregated-proofs/latest/ws"] = { client_request_cost = 0, backend_push_cost = 80, use_leader = false },

    -- SEQUENCER
    ["/sequencer/txs"] = { cost = 80, use_leader = true },
    ["/sequencer/txs/ws"] = { client_request_cost = 0, backend_push_cost = 80, use_leader = false },
    ["/sequencer/txs/submit/ws"] = { client_request_cost = 80, backend_push_cost = 0, use_leader = true },  -- Bidirectional: client streams tx submissions, responses free
    ["/sequencer/txs/{txHash}"] = { cost = 80, use_leader = false },
    ["/sequencer/txs/{txHash}/status"] = { cost = 80, use_leader = false },
    ["/sequencer/txs/{txHash}/ws"] = { client_request_cost = 0, backend_push_cost = 80, use_leader = false },
    ["/sequencer/ready"] = { cost = 5, use_leader = false },
    ["/sequencer/unstable/events"] = { cost = 255, use_leader = false },
    ["/sequencer/unstable/events/{eventOffset}"] = { cost = 80, use_leader = false },
    ["/sequencer/events/ws"] = { client_request_cost = 0, backend_push_cost = 80, use_leader = false },

    -- ROLLUP
    ["/rollup/base-fee-per-gas/latest"] = { cost = 80, use_leader = false },
    ["/rollup/schema"] = { cost = 5, use_leader = false },
    ["/rollup/constants"] = { cost = 5, use_leader = false },
    ["/rollup/addresses/{credential_id}/dedup"] = { cost = 80, use_leader = false },
    ["/rollup/simulate"] = { cost = 300, use_leader = false },
    ["/rollup/sync-status"] = { cost = 5, use_leader = false },

    -- Default for unspecified REST endpoints
    default = { cost = 80, use_leader = false }
}

-- Build pattern matching table at init time for efficiency
-- Converts {param} patterns to Lua patterns
M.rest_patterns = {}
for key, config in pairs(M.rest_endpoints) do
    if key ~= "default" and key:find("{") then
        local pattern = "^" .. key:gsub("{[^}]+}", "[^/]+") .. "$"
        table.insert(M.rest_patterns, {
            pattern = pattern,
            config = config
        })
    end
end

-- ============================================================================
-- JSON-RPC METHOD CONFIGURATION
-- ============================================================================
-- Configuration for JSON-RPC methods on the /rpc endpoint.
-- Each method has: cost (client request cost) + use_leader (routing).
--
-- IMPORTANT: Only write transactions go to leader (eth_send*, realtime_send*).
-- Subscriptions (eth_subscribe) go to follower - the subscription request is
-- cheap (cost=5), but each pushed event costs JSONRPC_PUSHED_EVENT_COST (80).
-- Request/response methods (like eth_getBalance) only charge for the request;
-- the response is free.
M.jsonrpc_methods = {
    -- NETWORK & CHAIN INFORMATION
    ["net_version"] = { cost = 5, use_leader = false },
    ["eth_chainId"] = { cost = 5, use_leader = false },

    -- BLOCKS
    ["eth_blockNumber"] = { cost = 80, use_leader = false },
    ["eth_getBlockByHash"] = { cost = 80, use_leader = false },
    ["eth_getBlockByNumber"] = { cost = 80, use_leader = false },
    ["eth_getBlockReceipts"] = { cost = 1000, use_leader = false },

    -- ACCOUNT OPERATIONS
    ["eth_getBalance"] = { cost = 80, use_leader = false },
    ["eth_getTransactionCount"] = { cost = 80, use_leader = false },
    ["eth_getCode"] = { cost = 80, use_leader = false },
    ["eth_getStorageAt"] = { cost = 80, use_leader = false },

    -- TRANSACTION LIFECYCLE (send* methods go to leader)
    ["eth_sendRawTransaction"] = { cost = 80, use_leader = true },
    ["realtime_sendRawTransaction"] = { cost = 80, use_leader = true },
    ["eth_sendRawTransactionSync"] = { cost = 80, use_leader = true },
    ["eth_getTransactionByHash"] = { cost = 80, use_leader = false },
    ["eth_getTransactionReceipt"] = { cost = 80, use_leader = false },
    ["eth_call"] = { cost = 80, use_leader = false },
    ["eth_estimateGas"] = { cost = 300, use_leader = false },

    -- EVENTS & LOGS
    ["eth_getLogs"] = { cost = 255, use_leader = false },
    ["eth_getLogsWithCursor"] = { cost = 255, use_leader = false },
    ["eth_subscribe"] = { cost = 5, use_leader = false },  -- SUBSCRIBE_COST
    ["eth_unsubscribe"] = { cost = 5, use_leader = false }, -- SUBSCRIBE_COST

    -- DEVELOPER TOOLS
    ["debug_traceTransaction"] = { cost = 1000, use_leader = false },
    ["debug_traceBlockByNumber"] = { cost = 1000, use_leader = false },
    ["eth_gasPrice"] = { cost = 80, use_leader = false },
    -- Default for unspecified methods
    default = { cost = 80, use_leader = false }
}

-- ============================================================================
-- CONFIG LOOKUP
-- ============================================================================

-- Find REST endpoint config by path.
-- First tries exact match, then pattern match for parameterized paths.
-- Falls back to default config if no match found.
function M.find_rest_config(path)
    -- Try exact match first
    if M.rest_endpoints[path] then
        return M.rest_endpoints[path]
    end

    -- Try pattern matching for paths with {param}
    for _, entry in ipairs(M.rest_patterns) do
        if path:match(entry.pattern) then
            return entry.config
        end
    end

    return M.rest_endpoints.default
end

-- Get request configuration for a given URI.
-- For HTTP endpoints: returns cost, use_leader, nil
-- For WS endpoints: returns client_request_cost, backend_push_cost, use_leader
-- For JSON-RPC: returns cost, use_leader, method_name
function M.get_request_config(uri, http_method, body)
    if uri == "/rpc" and http_method == "POST" and body then
        local method = body:match('"method"%s*:%s*"([^"]+)"')
        if method then
            local cfg = M.jsonrpc_methods[method] or M.jsonrpc_methods.default
            return cfg.cost, cfg.use_leader, method
        end
    end

    local cfg = M.find_rest_config(uri)

    -- WebSocket endpoints use new field names
    if cfg.client_request_cost ~= nil then
        return cfg.client_request_cost, cfg.backend_push_cost, cfg.use_leader
    end

    -- HTTP endpoints use cost
    return cfg.cost, cfg.use_leader, nil
end

-- ============================================================================
-- RATE LIMITING
-- ============================================================================

-- Apply rate limiting using token bucket algorithm with atomic locking.
--
-- Token bucket works as follows:
-- - Each client IP has a bucket that holds up to BUCKET_CAPACITY tokens
-- - Bucket refills at REFILL_RATE tokens per second
-- - Each request costs a certain number of tokens
-- - If bucket has insufficient tokens, request is rate limited
--
-- Returns: ok (boolean), err_type ("busy"|"exceeded"|nil), remaining_tokens
--
-- Locking: Uses spinlock via shared dict's atomic add() operation.
-- The add() only succeeds if key doesn't exist, providing mutual exclusion.
function M.apply_rate_limit(client_ip, cost, is_exempt)
    if is_exempt then
        return true, nil, nil  -- Exempt IPs bypass rate limiting entirely
    end

    local buckets = ngx.shared.token_buckets
    local current_time = ngx.now()
    local bucket_key = "bucket:" .. client_ip
    local last_refill_key = "refill:" .. client_ip
    local lock_key = "lock:" .. client_ip

    -- Acquire lock using spinlock with exponential backoff.
    -- buckets:add() is atomic - only succeeds if key doesn't exist.
    local lock_acquired = false
    local wait_time = M.SPINLOCK_INITIAL_WAIT_SEC
    for attempt = 1, M.SPINLOCK_MAX_ATTEMPTS do
        local ok = buckets:add(lock_key, true, 1)
        if ok then
            lock_acquired = true
            break
        end
        ngx.sleep(wait_time)
        wait_time = math.min(wait_time * 2, M.SPINLOCK_MAX_WAIT_SEC)
    end

    if not lock_acquired then
        return false, "busy", nil
    end

    -- Read and refill tokens
    local tokens = buckets:get(bucket_key)
    local last_refill = buckets:get(last_refill_key) or current_time

    if not tokens then
        -- First request from this IP: initialize with full bucket
        tokens = M.BUCKET_CAPACITY
    else
        -- Calculate tokens earned since last refill
        local elapsed = current_time - last_refill
        local new_tokens = elapsed * M.REFILL_RATE
        -- Add earned tokens, but don't exceed bucket capacity
        tokens = math.min(M.BUCKET_CAPACITY, tokens + new_tokens)
    end

    -- Check and consume tokens
    local rate_limited = tokens < cost
    if not rate_limited then
        tokens = tokens - cost
        buckets:set(bucket_key, tokens, M.BUCKET_TTL_SEC)
        buckets:set(last_refill_key, current_time, M.BUCKET_TTL_SEC)
    end

    -- Release lock
    buckets:delete(lock_key)

    if rate_limited then
        return false, "exceeded", tokens
    end
    return true, nil, tokens
end

-- ============================================================================
-- WEBSOCKET PROXY
-- ============================================================================
--
-- WebSocket proxying uses a concurrent threading model:
--
--   Client                     Nginx                      Backend(s)
--     |                          |                            |
--     |  --- frame --->  [main thread]  --- frame --->        |
--     |                   client_to_backend()                 |
--     |                          |                            |
--     |  <--- frame ---  [spawned thread]  <--- frame ---     |
--     |                   backend_to_client()                 |
--
-- The main thread handles client->backend flow (including rate limiting).
-- Spawned threads handle backend->client flow (one thread per backend).
--
-- For JSON-RPC (/rpc): Messages are routed per-request based on method.
-- For REST WebSocket: Single backend connection based on endpoint config.
--
-- PUBLIC API:
--   M.handle_websocket() - Main entry point, handles everything
--
-- The code below is organized in dependency order (bottom-up):
--   1. Connection helpers (create ws, connect to backend, spawn threads)
--   2. Message handlers (process individual client messages)
--   3. Main loop (client_to_backend) and entry point (handle_websocket)

--------------------------------------------------------------------------------
-- Connection Helpers
--------------------------------------------------------------------------------

-- Create a WebSocket server connection for accepting the client's upgrade request.
-- Called at the start of WebSocket handling to complete the handshake.
function M.create_client_websocket()
    local wb, err = ws_server:new{
        timeout = M.WS_TIMEOUT_MS,
        max_payload_len = M.WS_CLIENT_MAX_PAYLOAD
    }
    return wb, err
end

-- Backend to client forwarding (runs in separate ngx.thread).
-- Rate limits pushed events and closes connection if limit exceeded.
function M.backend_to_client(ctx, backend_entry, backend_name)
    local backend_wb = backend_entry.wb
    while not ctx.closing do
        local data, typ, err = backend_wb:recv_frame()
        if not data then
            if not ctx.closing and err then
                ngx.log(ngx.INFO, "Backend ", backend_name, " disconnected: ", err)
            end
            backend_entry.wb = nil
            break
        end
        if typ == "close" then
            backend_entry.wb = nil
            break
        elseif typ == "text" or typ == "binary" then
            -- Rate limit backend pushes:
            -- - JSON-RPC: only eth_subscription notifications cost tokens (request/response are free)
            -- - REST WebSocket: use backend_push_cost from endpoint config (0 = free, e.g., for tx submit responses)
            local push_cost = 0
            if ctx.is_jsonrpc then
                if data:match('"method"%s*:%s*"eth_subscription"') then
                    push_cost = M.JSONRPC_PUSHED_EVENT_COST
                end
            else
                push_cost = ctx.backend_push_cost
            end

            if push_cost > 0 then
                local ok = M.apply_rate_limit(ctx.client_ip, push_cost, ctx.is_exempt)
                if not ok then
                    ngx.log(ngx.WARN, "Rate limit exceeded for pushed event, closing connection")
                    ctx.closing = true
                    ctx.client_wb:send_close(1008, "Rate limit exceeded")
                    break
                end
            end
            -- Forward to client preserving frame type
            if typ == "text" then
                ctx.client_wb:send_text(data)
            else
                ctx.client_wb:send_binary(data)
            end
        elseif typ == "ping" then
            backend_wb:send_pong(data)
        end
    end
end

-- Connect to a backend WebSocket server and spawn a reader thread.
-- The reader thread (backend_to_client) forwards messages to the client.
-- Returns: websocket handle on success, nil on failure
function M.connect_backend(ctx, backend_entry, backend_name)
    local wb, err = ws_client:new{
        timeout = M.WS_TIMEOUT_MS,
        max_payload_len = M.WS_BACKEND_MAX_PAYLOAD
    }
    if not wb then
        ngx.log(ngx.ERR, "failed to create backend websocket: ", err)
        return nil, err
    end

    local ok, err = wb:connect("ws://" .. backend_entry.addr .. ctx.uri, {
        headers = {
            ["Host"] = ngx.var.host,
            ["X-Real-IP"] = ngx.var.remote_addr,
            ["X-Forwarded-For"] = ngx.var.proxy_add_x_forwarded_for,
            ["X-Forwarded-Proto"] = ngx.var.scheme
        }
    })
    if not ok then
        ngx.log(ngx.ERR, "failed to connect to backend ", backend_entry.addr, ": ", err)
        return nil, err
    end

    backend_entry.wb = wb
    local thread = ngx.thread.spawn(M.backend_to_client, ctx, backend_entry, backend_name)
    table.insert(ctx.backend_threads, thread)

    return wb
end

-- Get or create backend connection (lazy connect with auto-reconnect).
-- In single backend mode (leader == follower), always uses leader entry
-- to avoid duplicate connections to the same server.
-- Returns: websocket handle, backend name ("leader" or "follower")
function M.get_backend(ctx, use_leader)
    local name = (use_leader or ctx.is_single_backend) and "leader" or "follower"
    local entry = ctx.backends[name]
    if not entry.wb then
        M.connect_backend(ctx, entry, name)
    end
    return entry.wb, name
end

--------------------------------------------------------------------------------
-- Message Handlers
--------------------------------------------------------------------------------

-- Handle a single JSON-RPC message from client.
-- Parses method, applies rate limiting, routes to appropriate backend.
-- Returns: true to continue processing, false to close connection.
local function handle_jsonrpc_message(ctx, data, typ)
    local text_data = data

    if typ == "binary" then
        local valid_utf8 = pcall(function()
            for p, c in utf8.codes(data) do end
        end)
        if not valid_utf8 then
            ctx.client_wb:send_text('{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error: Binary frame must contain valid UTF-8"},"id":null}')
            return true  -- continue
        end
        text_data = data
    end

    -- Extract request ID for error responses (JSON-RPC 2.0 spec: echo back client's id)
    local id = text_data:match('"id"%s*:%s*(%d+)') or
               text_data:match('"id"%s*:%s*(".-")') or "null"

    local method = text_data:match('"method"%s*:%s*"([^"]+)"')
    if not method then
        ctx.client_wb:send_text('{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request: Missing method"},"id":' .. id .. '}')
        return true  -- continue
    end

    local method_config = M.jsonrpc_methods[method] or M.jsonrpc_methods.default
    local cost = method_config.cost
    local use_leader = method_config.use_leader

    local ok, err_type, remaining = M.apply_rate_limit(ctx.client_ip, cost, ctx.is_exempt)
    if not ok then
        if err_type == "busy" then
            ctx.client_wb:send_text('{"jsonrpc":"2.0","error":{"code":-32000,"message":"Rate limit busy, try again"},"id":' .. id .. '}')
        else
            ctx.client_wb:send_text('{"jsonrpc":"2.0","error":{"code":-32000,"message":"Rate limit exceeded","data":{"cost":' .. cost .. ',"remaining":' .. math.floor(remaining or 0) .. ',"method":"' .. method .. '"}},"id":' .. id .. '}')
        end
        return true  -- continue
    end

    local backend_wb, backend_name = M.get_backend(ctx, use_leader)
    if not backend_wb then
        ctx.client_wb:send_text('{"jsonrpc":"2.0","error":{"code":-32603,"message":"Backend unavailable"},"id":' .. id .. '}')
        return false  -- break
    end

    local send_ok, send_err
    if typ == "text" then
        send_ok, send_err = backend_wb:send_text(data)
    else
        send_ok, send_err = backend_wb:send_binary(data)
    end
    if not send_ok then
        ctx.client_wb:send_text('{"jsonrpc":"2.0","error":{"code":-32603,"message":"Backend send failed"},"id":' .. id .. '}')
    end

    return true  -- continue
end

-- Handle a single REST WebSocket message from client.
-- Used for bidirectional endpoints like /sequencer/txs/submit/ws.
-- For subscribe-only endpoints, client typically doesn't send data messages.
-- Returns: true to continue processing, false to close connection.
local function handle_rest_ws_message(ctx, data, typ)
    local ok, err_type, remaining = M.apply_rate_limit(ctx.client_ip, ctx.client_request_cost, ctx.is_exempt)
    if not ok then
        if err_type == "busy" then
            ctx.client_wb:send_text('{"error":"Rate limit busy, try again"}')
        else
            ctx.client_wb:send_text('{"error":"Rate limit exceeded","cost":' .. ctx.client_request_cost .. ',"remaining":' .. math.floor(remaining or 0) .. '}')
        end
        return true  -- continue
    end

    -- Reconnect to backend if disconnected
    if not ctx.endpoint_backend_wb or not ctx.backends[ctx.endpoint_backend_name].wb then
        ctx.endpoint_backend_wb, ctx.endpoint_backend_name = M.get_backend(ctx, ctx.endpoint_use_leader)
        if not ctx.endpoint_backend_wb then
            ctx.client_wb:send_text('{"error":"Backend unavailable"}')
            return false  -- break
        end
    end

    local send_ok, send_err
    if typ == "text" then
        send_ok, send_err = ctx.endpoint_backend_wb:send_text(data)
    else
        send_ok, send_err = ctx.endpoint_backend_wb:send_binary(data)
    end
    if not send_ok then
        ngx.log(ngx.ERR, "Failed to send to backend: ", send_err)
        ctx.client_wb:send_text('{"error":"Backend send failed"}')
    end

    return true  -- continue
end

--------------------------------------------------------------------------------
-- Main Loop and Entry Point
--------------------------------------------------------------------------------

-- Main client-to-backend message loop (runs in main thread).
-- Reads frames from client, handles control frames (ping/pong/close),
-- and delegates data frames to appropriate handler based on mode.
local function client_to_backend(ctx)
    -- For REST WebSocket, connect to backend immediately so it can start
    -- pushing subscription events. For JSON-RPC, we connect lazily per-message.
    if not ctx.is_jsonrpc then
        ctx.endpoint_backend_wb, ctx.endpoint_backend_name = M.get_backend(ctx, ctx.endpoint_use_leader)
        if not ctx.endpoint_backend_wb then
            ctx.client_wb:send_text('{"error":"Backend unavailable"}')
            ctx.client_wb:send_close()
            return
        end
    end

    while not ctx.closing do
        local data, typ, err = ctx.client_wb:recv_frame()
        if not data then
            if err and err ~= "timeout" then
                ngx.log(ngx.INFO, "Client disconnected: ", err)
            end
            break
        end

        if typ == "close" then
            ctx.closing = true
            break
        elseif typ == "ping" then
            ctx.client_wb:send_pong(data)
        elseif typ == "pong" then
            -- Ignore pongs
        elseif typ == "text" or typ == "binary" then
            local should_continue
            if ctx.is_jsonrpc then
                should_continue = handle_jsonrpc_message(ctx, data, typ)
            else
                should_continue = handle_rest_ws_message(ctx, data, typ)
            end
            if not should_continue then
                break
            end
        end
    end
end

-- Main entry point for WebSocket proxy.
-- Called from nginx content_by_lua_block. Handles all setup internally.
function M.handle_websocket()
    local uri = ngx.var.uri
    local is_jsonrpc = (uri == "/rpc")

    -- Create client WebSocket connection
    local client_wb, err = M.create_client_websocket()
    if not client_wb then
        ngx.log(ngx.ERR, "failed to create websocket: ", err)
        return ngx.exit(400)
    end

    -- Get backend addresses from shared cache
    local backend_cache = ngx.shared.backend_cache
    local leader_addr = backend_cache:get("leader") or "127.0.0.1:12346"
    local follower_addr = backend_cache:get("follower") or leader_addr

    -- Get endpoint config (for REST WebSocket; JSON-RPC does per-message routing)
    -- For WS: returns client_request_cost, backend_push_cost, use_leader
    local client_request_cost, backend_push_cost, endpoint_use_leader = M.get_request_config(uri, nil, nil)

    -- Build context object with all request state
    local ctx = {
        uri = uri,
        is_jsonrpc = is_jsonrpc,
        client_wb = client_wb,
        client_ip = ngx.var.binary_remote_addr,
        is_exempt = (ngx.var.rate_limit_override ~= "0"),
        is_single_backend = (leader_addr == follower_addr),
        endpoint_use_leader = endpoint_use_leader,
        client_request_cost = client_request_cost,
        backend_push_cost = backend_push_cost,
        backends = {
            leader = { wb = nil, addr = leader_addr },
            follower = { wb = nil, addr = follower_addr }
        },
        closing = false,
        backend_threads = {},
        endpoint_backend_wb = nil,
        endpoint_backend_name = nil
    }

    -- Run main loop until client disconnects or error
    client_to_backend(ctx)

    -- Signal all backend threads to stop and wait for them
    ctx.closing = true
    for _, thread in ipairs(ctx.backend_threads) do
        ngx.thread.wait(thread)
    end

    -- Clean up: send close frames to all connections (ignore errors)
    pcall(function() ctx.client_wb:send_close() end)
    pcall(function() if ctx.backends.leader.wb then ctx.backends.leader.wb:send_close() end end)
    pcall(function() if ctx.backends.follower.wb then ctx.backends.follower.wb:send_close() end end)
end

-- ============================================================================
-- HTTP PROXY
-- ============================================================================
--
-- PUBLIC API:
--   M.handle_http_request(uri, http_method) - Rate limit and route HTTP request

-- Handle HTTP request rate limiting and backend routing.
-- Called from nginx access_by_lua_block before proxy_pass.
-- Sets ngx.var.backend to the selected backend address.
-- Returns 429 with rate limit info if limit exceeded.
function M.handle_http_request(uri, http_method)
    local backend_cache = ngx.shared.backend_cache
    local client_ip = ngx.var.binary_remote_addr
    local is_exempt = (ngx.var.rate_limit_override ~= "0")

    -- Read body for POST requests (needed for JSON-RPC method extraction)
    local body = nil
    if http_method == "POST" then
        ngx.req.read_body()
        body = ngx.req.get_body_data()
    end

    -- Get request config (handles both REST and JSON-RPC)
    local cost, use_leader, jsonrpc_method = M.get_request_config(uri, http_method, body)

    -- Apply rate limiting
    local ok, err_type, remaining = M.apply_rate_limit(client_ip, cost, is_exempt)

    if not ok then
        ngx.status = 429
        ngx.header["X-RateLimit-Cost"] = cost
        ngx.header["X-RateLimit-Remaining"] = math.floor(remaining or 0)
        if err_type == "busy" then
            ngx.header["Retry-After"] = 1
            ngx.say('{"error":"Rate limit busy, try again"}')
        else
            ngx.header["Retry-After"] = math.ceil((cost - (remaining or 0)) / M.REFILL_RATE)
            local error_msg = '{"error":"Rate limit exceeded","cost":' .. cost .. ',"remaining":' .. math.floor(remaining or 0)
            if jsonrpc_method then
                error_msg = error_msg .. ',"method":"' .. jsonrpc_method .. '"'
            end
            error_msg = error_msg .. '}'
            ngx.say(error_msg)
        end
        return ngx.exit(429)
    end

    -- Add rate limit headers for successful requests
    if not is_exempt and remaining then
        ngx.header["X-RateLimit-Cost"] = cost
        ngx.header["X-RateLimit-Remaining"] = math.floor(remaining)
        ngx.header["X-RateLimit-Capacity"] = M.BUCKET_CAPACITY
    end

    -- Select backend based on routing decision
    if use_leader then
        ngx.var.backend = backend_cache:get("leader") or "127.0.0.1:12346"
    else
        ngx.var.backend = backend_cache:get("follower") or
                         backend_cache:get("leader") or
                         "127.0.0.1:12346"
    end
end

return M
