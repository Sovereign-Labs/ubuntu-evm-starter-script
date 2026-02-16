local _M = {}

local function is_empty(value)
    return not value or value == ""
end

local function pick_backend(use_leader, backend_cache)
    local backend
    if use_leader then
        backend = backend_cache:get("leader")
    else
        backend = backend_cache:get("follower_1")
        if is_empty(backend) then
            backend = backend_cache:get("leader")
        end
    end
    return backend
end

-- Exposed for unit tests.
_M.pick_backend = pick_backend

function _M.select(path)
    local method = ngx.var.request_method
    local backend_cache = ngx.shared.backend_cache
    local use_leader = false

    -- Check if this is a WebSocket upgrade request
    local is_websocket = ngx.var.http_upgrade and ngx.var.http_upgrade:lower() == "websocket"

    -- Route /sequencer/txs POSTs to leader
    if path == "/sequencer/txs" and method == "POST" then
        use_leader = true
    -- Route /sequencer/ready to leader (health check for leader node)
    elseif path == "/sequencer/ready" and method == "GET" then
        use_leader = true
    -- Route WebSocket connections to leader for consistency
    elseif is_websocket then
        use_leader = true
    -- Check for JSON-RPC eth_sendRawTransaction on /rpc endpoint
    elseif path == "/rpc" and method == "POST" then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()

        if body then
            local rpc_method = body:match('"method"%s*:%s*"([^"]+)"')

            if rpc_method == "eth_sendRawTransaction" or rpc_method == "eth_sendRawTransactionSync" or rpc_method == "realtime_sendRawTransaction" then
                use_leader = true
            end
        end
    end

    -- Select backend based on routing decision
    local backend = pick_backend(use_leader, backend_cache)

    if is_empty(backend) then
        ngx.log(ngx.ERR, "backend not available in cache")
        ngx.status = 503
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("backend unavailable")
        return ngx.exit(ngx.status)
    end

    ngx.var.backend = backend
end

return _M
