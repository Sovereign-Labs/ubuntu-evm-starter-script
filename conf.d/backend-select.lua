local _M = {}

-- Handle mock responses for certain RPC methods
-- Returns true if the request was handled (response sent), false otherwise
function _M.handle_mock_responses(path)
    local method = ngx.var.request_method

    if path == "/rpc" and method == "POST" then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()

        if body then
            local rpc_method = body:match('"method"%s*:%s*"([^"]+)"')

            if rpc_method == "eth_maxPriorityFeePerGas" then
                -- Extract the request ID (can be number or string)
                local id = body:match('"id"%s*:%s*(%d+)') or body:match('"id"%s*:%s*"([^"]+)"')

                -- If ID was a string match, wrap it in quotes for the response
                local id_value = id
                if body:match('"id"%s*:%s*"') then
                    id_value = '"' .. id .. '"'
                end

                ngx.header.content_type = "application/json"
                ngx.say('{"jsonrpc":"2.0","id":' .. (id_value or "null") .. ',"result":"0x0"}')
                return true
            end
        end
    end

    return false
end

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
    if use_leader then
        ngx.var.backend = backend_cache:get("leader") or "{{ROLLUP_LEADER_IP}}:12346"
    else
        ngx.var.backend = backend_cache:get("follower") or
                         backend_cache:get("leader") or
                         "{{ROLLUP_FOLLOWER_IP}}:12346"
    end
end

return _M
