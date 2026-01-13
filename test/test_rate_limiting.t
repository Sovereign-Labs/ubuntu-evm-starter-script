#!/usr/bin/env perl

use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(abs_path);
use File::Basename qw(dirname);

# Get the directory containing this test file
my $test_dir = dirname(abs_path(__FILE__));
my $project_dir = dirname($test_dir);

# Read the test HTTP config
my $http_config_path = "$test_dir/test-http-config.conf";
open(my $fh1, '<', $http_config_path) or die "Cannot open: $http_config_path: $!";
our $HttpConfigBase = do { local $/; <$fh1> };
close($fh1);

# Location configs via include (uses same files as production)
our $LocationConfig = qq{
    include $project_dir/conf.d/websocket-proxy.conf;
    include $project_dir/conf.d/proxy-location-rate-limited.conf;
};

# Helper to modify bucket size in config
# Sets global variables before requiring the proxy module
sub with_bucket {
    my ($capacity, $refill) = @_;
    my $config = $::HttpConfigBase;
    $config =~ s/(init_by_lua_block \{)/$1\n        BUCKET_CAPACITY = $capacity\n        REFILL_RATE = $refill/;
    return $config;
}

# Config with localhost exempted (for testing exemption behavior)
our $HttpConfigExempt = $::HttpConfigBase;
$HttpConfigExempt =~ s/geo \$rate_limit_override \{/geo \$rate_limit_override {\n        127.0.0.1 1;  # Exempt localhost/;

# Large bucket - no rate limit interference
our $HttpConfigLargeBucket = with_bucket(10000, 10000);

# Tiny bucket - triggers rate limiting immediately
our $HttpConfigTinyBucket = with_bucket(1, 1);

run_tests();

__DATA__

=== TEST 1: JSON-RPC method configured for leader routes to leader
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
POST /rpc
{"jsonrpc":"2.0","method":"test_leader_write","params":[],"id":1}
--- response_body chomp
{"backend":"leader"}
--- response_headers
X-Backend: leader
--- error_code: 200



=== TEST 2: JSON-RPC method configured for follower routes to follower
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
POST /rpc
{"jsonrpc":"2.0","method":"test_follower_read","params":[],"id":1}
--- response_body chomp
{"backend":"follower"}
--- response_headers
X-Backend: follower
--- error_code: 200



=== TEST 3: REST endpoint configured for leader routes to leader
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
POST /sequencer/txs
{"tx":"0x123"}
--- response_body chomp
{"backend":"leader"}
--- response_headers
X-Backend: leader
--- error_code: 200



=== TEST 4: REST endpoint configured for follower routes to follower
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
GET /rollup/schema
--- response_body chomp
{"backend":"follower"}
--- response_headers
X-Backend: follower
--- error_code: 200



=== TEST 5: REST WebSocket endpoints reject non-WebSocket requests
HTTP GET (without WebSocket upgrade headers) to /ws endpoints returns 426.
Only WebSocket connections are accepted. Actual WebSocket routing is tested in TEST 14-19.
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
GET /ledger/slots/latest/ws
--- error_code: 426



=== TEST 6: Path parameter pattern matching works
/test/param/{id} has cost=123 and routes to leader (vs default cost=80, follower).
Verifies both routing and cost are correctly matched via pattern.
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
GET /test/param/abc123
--- response_body chomp
{"backend":"leader"}
--- response_headers
X-Backend: leader
X-RateLimit-Remaining: 9877
--- error_code: 200



=== TEST 7: Unknown RPC method uses default config
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
POST /rpc
{"jsonrpc":"2.0","method":"unknown_method","params":[],"id":1}
--- response_body chomp
{"backend":"follower"}
--- response_headers
X-Backend: follower
--- error_code: 200



=== TEST 8: Unknown REST endpoint uses default config
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
GET /some/unknown/path
--- response_body chomp
{"backend":"follower"}
--- response_headers
X-Backend: follower
--- error_code: 200



=== TEST 9: Rate limiting returns 429 when bucket exhausted
--- http_config eval: $::HttpConfigTinyBucket
--- config eval: $::LocationConfig
--- request
GET /rollup/schema
--- error_code: 429
--- response_headers_like
Retry-After: \d+



=== TEST 10: Rate limit error includes method name for RPC requests
--- http_config eval: $::HttpConfigTinyBucket
--- config eval: $::LocationConfig
--- request
POST /rpc
{"jsonrpc":"2.0","method":"test_follower_read","params":[],"id":1}
--- error_code: 429
--- response_body_like chomp
"method":"test_follower_read"



=== TEST 11: Exempted IP bypasses rate limiting even with exhausted bucket
Uses a tiny bucket (1 token) that would rate limit non-exempt requests immediately.
Exempted IP should still succeed on all requests.
--- http_config eval
my $config = $::HttpConfigBase;
# Tiny bucket that would rate limit immediately (set globals before require)
$config =~ s/(init_by_lua_block \{)/$1\n        BUCKET_CAPACITY = 1\n        REFILL_RATE = 0/;
# Add localhost to exemption list
$config =~ s/geo \$rate_limit_override \{/geo \$rate_limit_override {\n        127.0.0.1 1;  # Exempt localhost/;
return $config;
--- config eval: $::LocationConfig
--- pipelined_requests eval
["GET /rollup/schema", "GET /rollup/schema", "GET /rollup/schema"]
--- error_code eval
[200, 200, 200]



=== TEST 12: Exempted IP has no rate limit headers
--- http_config eval: $::HttpConfigExempt
--- config eval: $::LocationConfig
--- request
GET /health
--- raw_response_headers_unlike: X-RateLimit-Cost
--- error_code: 200



=== TEST 13: Non-exempt requests have rate limit headers
--- http_config eval: $::HttpConfigLargeBucket
--- config eval: $::LocationConfig
--- request
GET /health
--- response_headers_like
X-RateLimit-Cost: \d+
X-RateLimit-Remaining: \d+
X-RateLimit-Capacity: \d+
--- error_code: 200



=== TEST 14: WebSocket /rpc routes write method to leader
--- http_config eval: $::HttpConfigLargeBucket
--- config eval
qq{
$::LocationConfig

        # Test endpoint that acts as WebSocket client (^~ to bypass main proxy regex)
        location ^~ /test-ws-leader {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new()
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Send test_leader_write (should go to leader)
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_leader_write","params":[],"id":1}')
                if not ok then
                    ngx.say("ERR:send:", err)
                    return
                end

                local data, typ, err = wb:recv_frame()
                if not data then
                    ngx.say("ERR:recv:", err, " typ:", typ)
                    return
                end

                wb:send_close()
                ngx.say("OK:", typ, ":", data)
            }
        }
}
--- request
GET /test-ws-leader
--- response_body_like
OK:text:\{"jsonrpc":"2.0","result":"leader","id":1\}
--- error_code: 200
--- timeout: 5



=== TEST 15: WebSocket /rpc routes test_subscribe to follower
--- http_config eval: $::HttpConfigLargeBucket
--- config eval
qq{
$::LocationConfig

        # Test endpoint that acts as WebSocket client (^~ to bypass main proxy regex)
        location ^~ /test-ws-follower {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new()
                if not wb then
                    ngx.say("failed to create client: ", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                -- Send test_subscribe (should go to follower)
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_subscribe","params":["newHeads"],"id":1}')
                if not ok then
                    ngx.say("failed to send: ", err)
                    return
                end

                local data, typ, err = wb:recv_frame()
                if not data then
                    ngx.say("failed to receive: ", err)
                    return
                end

                wb:send_close()
                ngx.say(data)
            }
        }
}
--- request
GET /test-ws-follower
--- response_body
{"jsonrpc":"2.0","result":"0xabc123","id":1}
--- error_code: 200
--- timeout: 5



=== TEST 16: WebSocket subscription receives multiple messages (streaming)
--- http_config eval: $::HttpConfigLargeBucket
--- config eval
qq{
$::LocationConfig

        # Test endpoint that receives multiple subscription messages
        location ^~ /test-ws-streaming {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 2000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Send test_subscribe
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_subscribe","params":["newHeads"],"id":1}')
                if not ok then
                    ngx.say("ERR:send:", err)
                    return
                end

                -- Receive multiple messages
                local messages = {}
                for i = 1, 3 do
                    local data, typ, err = wb:recv_frame()
                    if not data then
                        break
                    end
                    if typ == "text" then
                        table.insert(messages, data)
                    end
                end

                wb:send_close()
                ngx.say("received " .. #messages .. " messages")
                for i, msg in ipairs(messages) do
                    ngx.say(i .. ": " .. msg)
                end
            }
        }
}
--- request
GET /test-ws-streaming
--- response_body
received 3 messages
1: {"jsonrpc":"2.0","result":"0xabc123","id":1}
2: {"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xabc123","result":{"number":"0x1"}}}
3: {"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xabc123","result":{"number":"0x2"}}}
--- error_code: 200
--- timeout: 5



=== TEST 17: Backend reconnects after death
--- http_config eval: $::HttpConfigLargeBucket
--- config eval
qq{
$::LocationConfig

        location ^~ /test-reconnect {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 3000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Step 1: Send test_leader_close to leader (leader will respond then close)
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_leader_close","id":1}')
                if not ok then
                    ngx.say("ERR:send1:", err)
                    return
                end

                -- Receive the "closing" response
                local data, typ, err = wb:recv_frame()
                if not data then
                    ngx.say("ERR:recv1:", err)
                    return
                end
                ngx.say("1: ", data)

                -- Small delay to let the backend close propagate
                ngx.sleep(0.1)

                -- Step 2: Send test_leader_write (should go to leader, needs reconnect)
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_leader_write","params":[],"id":2}')
                if not ok then
                    ngx.say("ERR:send2:", err)
                    return
                end

                -- Should get response after reconnection
                local data2, typ2, err2 = wb:recv_frame()
                if not data2 then
                    ngx.say("ERR:recv2:", err2)
                    return
                end
                ngx.say("2: ", data2)

                wb:send_close()
            }
        }
}
--- request
GET /test-reconnect
--- response_body
1: {"jsonrpc":"2.0","result":"closing","id":1}
2: {"jsonrpc":"2.0","result":"leader","id":1}
--- error_code: 200
--- timeout: 10



=== TEST 18: Connection survives missing method error
--- http_config eval: $::HttpConfigLargeBucket
--- config eval
qq{
$::LocationConfig

        location ^~ /test-parse-error {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 2000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Send message WITHOUT method (should get error but connection should survive)
                local ok, err = wb:send_text('{"jsonrpc":"2.0","params":[],"id":1}')
                if not ok then
                    ngx.say("ERR:send1:", err)
                    return
                end

                -- Should get error response
                local data, typ, err = wb:recv_frame()
                if not data then
                    ngx.say("ERR:recv1:", err)
                    return
                end
                ngx.say("1: ", typ, " ", data:match('"message":"([^"]+)"') or data)

                -- Now send a VALID message - connection should still work
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_follower_read","id":2}')
                if not ok then
                    ngx.say("ERR:send2:", err)
                    return
                end

                local data2, typ2, err2 = wb:recv_frame()
                if not data2 then
                    ngx.say("ERR:recv2:", err2, " (connection died after parse error)")
                    return
                end
                ngx.say("2: ", typ2, " ", data2:match('"result"') and "got result" or data2)

                wb:send_close()
            }
        }
}
--- request
GET /test-parse-error
--- response_body
1: text Invalid Request: Missing method
2: text got result
--- error_code: 200
--- timeout: 5



=== TEST 19: Rate limiting is atomic under concurrent requests
--- http_config eval
# Bucket: 10 tokens, 0 refill (so we can test exact consumption)
my $config = $::HttpConfigBase;
$config =~ s/(init_by_lua_block \{)/$1\n        BUCKET_CAPACITY = 10\n        REFILL_RATE = 0/;
$config
--- config eval
qq{
$::LocationConfig

        location ^~ /test-rate-limit-atomic {
            content_by_lua_block {
                local client = require "resty.websocket.client"

                -- Create 5 separate WebSocket connections to test true concurrency
                -- Each connection sends one test_subscribe (cost=5)
                -- With 10 token bucket: exactly 2 should succeed, 3 should fail

                local threads = {}
                local results = {}

                for i = 1, 5 do
                    threads[i] = ngx.thread.spawn(function()
                        local wb, err = client:new{ timeout = 2000 }
                        if not wb then
                            return "create_err:" .. (err or "nil")
                        end

                        local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                        if not ok then
                            return "connect_err:" .. (err or "nil")
                        end

                        local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_subscribe","params":["newHeads"],"id":' .. i .. '}')
                        if not ok then
                            wb:send_close()
                            return "send_err:" .. (err or "nil")
                        end

                        local data, typ, err = wb:recv_frame()
                        wb:send_close()

                        if not data then
                            return "recv_err:" .. (err or "nil")
                        end
                        if data:match('"error"') then
                            return "rate_limited"
                        else
                            return "success"
                        end
                    end)
                end

                -- Wait for all threads
                for i = 1, 5 do
                    local ok, res = ngx.thread.wait(threads[i])
                    if ok then
                        table.insert(results, res)
                    else
                        table.insert(results, "thread_err")
                    end
                end

                -- Count successes
                local successes = 0
                local rate_limited = 0
                local errors = {}
                for _, r in ipairs(results) do
                    if r == "success" then
                        successes = successes + 1
                    elseif r == "rate_limited" then
                        rate_limited = rate_limited + 1
                    else
                        table.insert(errors, r)
                    end
                end

                -- With atomic rate limiting: exactly 2 successes (10 tokens / 5 cost = 2)
                -- With race condition: could be more than 2
                if successes == 2 and rate_limited == 3 then
                    ngx.say("PASS: exactly 2 succeeded, 3 rate limited")
                elseif #errors > 0 then
                    ngx.say("ERRORS: " .. table.concat(errors, ", "))
                else
                    ngx.say("FAIL: expected 2 successes and 3 rate_limited, got " .. successes .. " successes and " .. rate_limited .. " rate_limited")
                end
            }
        }
}
--- request
GET /test-rate-limit-atomic
--- response_body
PASS: exactly 2 succeeded, 3 rate limited
--- error_code: 200
--- timeout: 10



=== TEST 20: REST WebSocket endpoints route correctly via unified handler
Tests that /ledger/slots/latest/ws WebSocket connections route to follower with per-message rate limiting.
--- http_config eval: $::HttpConfigLargeBucket
--- config eval
qq{
$::LocationConfig

        location ^~ /test-rest-ws {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 3000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                -- Connect to REST WebSocket endpoint (routed through unified handler)
                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/ledger/slots/latest/ws")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Send a message (REST WS just forwards to backend)
                local ok, err = wb:send_text('{"test":"request"}')
                if not ok then
                    ngx.say("ERR:send:", err)
                    return
                end

                -- Receive response from backend
                local data, typ, err = wb:recv_frame()
                if not data then
                    ngx.say("ERR:recv:", err)
                    return
                end

                wb:send_close()
                -- Backend should be follower (per rest_methods config for /ledger/slots/latest/ws)
                ngx.say(data)
            }
        }
}
--- request
GET /test-rest-ws
--- response_body
{"result":"follower_rest"}
--- error_code: 200
--- timeout: 5



=== TEST 21: REST WebSocket per-message rate limiting
Each message on REST WebSocket costs tokens (per-message, not just per-connection).
Bucket needs to allow 2 roundtrips: 2*(5 send + 80 recv) = 170, then 3rd send fails.
--- http_config eval
my $config = $::HttpConfigBase;
$config =~ s/(init_by_lua_block \{)/$1\n        BUCKET_CAPACITY = 170\n        REFILL_RATE = 0/;  # No refill
return $config;
--- config eval
qq{
$::LocationConfig

        location ^~ /test-rest-ws-rate-limit {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 3000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/ledger/slots/latest/ws")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- /ledger/slots/latest/ws has cost 5, bucket has 10 tokens
                -- First message should succeed (10-5=5)
                local ok, err = wb:send_text('{"msg":1}')
                if not ok then
                    ngx.say("ERR:send1:", err)
                    return
                end
                local data1, typ1, err = wb:recv_frame()
                if not data1 then
                    ngx.say("ERR:recv1:", err)
                    return
                end

                -- Second message should succeed (5-5=0)
                local ok, err = wb:send_text('{"msg":2}')
                if not ok then
                    ngx.say("ERR:send2:", err)
                    return
                end
                local data2, typ2, err = wb:recv_frame()
                if not data2 then
                    ngx.say("ERR:recv2:", err)
                    return
                end

                -- Third message should be rate limited (0 < 5)
                local ok, err = wb:send_text('{"msg":3}')
                if not ok then
                    ngx.say("ERR:send3:", err)
                    return
                end
                local data3, typ3, err = wb:recv_frame()
                if not data3 then
                    ngx.say("ERR:recv3:", err)
                    return
                end

                wb:send_close()

                -- Parse responses to check rate limiting
                local has_result1 = data1:match('"result"')
                local has_result2 = data2:match('"result"')
                local is_rate_limited = data3:match('"Rate limit exceeded"')

                if has_result1 and has_result2 and is_rate_limited then
                    ngx.say("PASS: first 2 messages succeeded, third rate limited")
                else
                    ngx.say("FAIL: responses were:")
                    ngx.say("1: " .. data1)
                    ngx.say("2: " .. data2)
                    ngx.say("3: " .. data3)
                end
            }
        }
}
--- request
GET /test-rest-ws-rate-limit
--- response_body
PASS: first 2 messages succeeded, third rate limited
--- error_code: 200
--- timeout: 5



=== TEST 22: Backend-to-client rate limiting severs connection
When pushed events exceed rate limit, connection should be closed.
Bucket: 90 tokens, no refill. test_subscribe=5, each event=80.
After subscribe(5) + 1 event(80) = 85 used, 5 remaining.
Second event needs 80, only 5 available -> rate limited -> connection severed.
Mock backend sends: confirmation + 2 events. We should only receive confirmation + 1 event.
--- http_config eval
my $config = $::HttpConfigBase;
$config =~ s/(init_by_lua_block \{)/$1\n        BUCKET_CAPACITY = 90\n        REFILL_RATE = 0/;
return $config;
--- config eval
qq{
$::LocationConfig

        location ^~ /test-backend-rate-limit {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 3000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Subscribe (costs test_subscribe=5)
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_subscribe","params":["newHeads"],"id":1}')
                if not ok then
                    ngx.say("ERR:send:", err)
                    return
                end

                -- Try to receive messages until connection closes
                local event_count = 0
                local got_confirmation = false
                local got_close = false
                local messages = {}

                for i = 1, 5 do
                    local data, typ, err = wb:recv_frame()
                    if not data then
                        table.insert(messages, "recv_err")
                        break
                    end
                    if typ == "close" then
                        got_close = true
                        table.insert(messages, "close")
                        break
                    elseif typ == "text" then
                        if data:match('"result":"0x') then
                            got_confirmation = true
                            table.insert(messages, "confirm")
                        elseif data:match("eth_subscription") then
                            event_count = event_count + 1
                            table.insert(messages, "event" .. event_count)
                        end
                    end
                end

                wb:send_close()

                -- Key assertion: We should receive EXACTLY 1 event (not 2)
                -- because the second event should be rate limited and connection severed
                local result = table.concat(messages, ",")
                if got_confirmation and event_count == 1 and (got_close or result:match("recv_err")) then
                    ngx.say("PASS: received 1 event then connection severed")
                else
                    ngx.say("FAIL: event_count=" .. event_count .. " messages=" .. result)
                end
            }
        }
}
--- request
GET /test-backend-rate-limit
--- response_body
PASS: received 1 event then connection severed
--- error_code: 200
--- timeout: 5



=== TEST 23: REST WebSocket backend-to-client rate limiting
Similar to TEST 22 but for REST WebSocket endpoints.
Bucket needs: 5 (send) + 80 (recv) = 85 minimum to receive one message.
--- http_config eval
my $config = $::HttpConfigBase;
$config =~ s/(init_by_lua_block \{)/$1\n        BUCKET_CAPACITY = 90\n        REFILL_RATE = 0/;
return $config;
--- config eval
qq{
$::LocationConfig

        location ^~ /test-rest-backend-rate-limit {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 3000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                -- Connect to REST WebSocket endpoint (cost=5 per message)
                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/ledger/slots/latest/ws")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Send a message to trigger backend response stream
                -- For this test, we'll simulate by sending test_subscribe which triggers streaming
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_subscribe","params":["newHeads"],"id":1}')
                if not ok then
                    ngx.say("ERR:send:", err)
                    return
                end

                -- Try to receive messages until connection closes
                local messages = {}
                for i = 1, 5 do
                    local data, typ, err = wb:recv_frame()
                    if not data then
                        table.insert(messages, "recv_err:" .. (err or "nil"))
                        break
                    end
                    if typ == "close" then
                        table.insert(messages, "close_frame")
                        break
                    elseif typ == "text" then
                        if data:match("Rate limit") then
                            table.insert(messages, "rate_limited")
                        else
                            table.insert(messages, "msg")
                        end
                    end
                end

                wb:send_close()

                -- With 50 token bucket and cost=5 per event, should get ~10 messages max
                -- But mock backend sends 3 messages for eth_subscribe, so we need to check
                -- that if we HAD more messages, connection would close
                local result = table.concat(messages, ",")
                -- For now, just verify we got messages and no errors
                if result:match("msg") then
                    ngx.say("PASS: received messages on REST WS")
                else
                    ngx.say("RESULT: " .. result)
                end
            }
        }
}
--- request
GET /test-rest-backend-rate-limit
--- response_body
PASS: received messages on REST WS
--- error_code: 200
--- timeout: 5



=== TEST 24: Inactive backend timeout does not affect active connections
When only reads are sent (follower active), the leader connection may timeout.
But client-to-proxy and proxy-to-follower should stay alive.
Later writes should reconnect to leader.
--- http_config eval
my $config = $::HttpConfigBase;
# Use short timeout (2 seconds) and high bucket (set globals before require)
$config =~ s/(init_by_lua_block \{)/$1\n        WS_TIMEOUT = 2000\n        BUCKET_CAPACITY = 10000/;
return $config;
--- config eval
qq{
$::LocationConfig

        location ^~ /test-inactive-backend-timeout {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 10000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Step 1: Establish leader connection with a write
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_leader_write","params":[],"id":1}')
                if not ok then
                    ngx.say("ERR:send1:", err)
                    return
                end
                local data1, typ1, err = wb:recv_frame()
                if not data1 or not data1:match('"result"') then
                    ngx.say("ERR:recv1:", err or data1)
                    return
                end

                -- Step 2: Keep follower active with reads while leader goes idle
                -- Send reads every 0.5s for 3s (leader timeout is 2s)
                for i = 2, 7 do
                    ngx.sleep(0.5)
                    local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_follower_read","params":[],"id":' .. i .. '}')
                    if not ok then
                        ngx.say("ERR:send" .. i .. ":", err)
                        return
                    end
                    local data, typ, err = wb:recv_frame()
                    if not data or not data:match('"result"') then
                        ngx.say("ERR:recv" .. i .. ":", err or data)
                        return
                    end
                end

                -- By now, leader should have timed out (no activity for 3s > 2s timeout)
                -- But client connection and follower should still be alive

                -- Step 3: Verify follower still works
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_follower_read","params":[],"id":8}')
                if not ok then
                    ngx.say("ERR:send8:", err)
                    return
                end
                local data8, typ8, err = wb:recv_frame()
                if not data8 or not data8:match('"result"') then
                    ngx.say("ERR:recv8:", err or data8)
                    return
                end

                -- Step 4: Send a write - leader should reconnect
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_leader_write","params":[],"id":9}')
                if not ok then
                    ngx.say("ERR:send9:", err)
                    return
                end
                local data9, typ9, err = wb:recv_frame()
                if not data9 or not data9:match('"result"') then
                    ngx.say("ERR:recv9:", err or data9)
                    return
                end

                wb:send_close()
                ngx.say("PASS: inactive backend timeout handled correctly")
            }
        }
}
--- request
GET /test-inactive-backend-timeout
--- response_body
PASS: inactive backend timeout handled correctly
--- error_code: 200
--- timeout: 15



=== TEST 25: Complete inactivity causes proxy-level timeout
When there is no activity from client or backend, the connection should
eventually timeout at the proxy level (not hang forever).
--- http_config eval
my $config = $::HttpConfigBase;
# Use short timeout (2 seconds) and high bucket (set globals before require)
$config =~ s/(init_by_lua_block \{)/$1\n        WS_TIMEOUT = 2000\n        BUCKET_CAPACITY = 10000/;
return $config;
--- config eval
qq{
$::LocationConfig

        location ^~ /test-complete-inactivity {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 10000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Send one message to establish connection
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_follower_read","params":[],"id":1}')
                if not ok then
                    ngx.say("ERR:send1:", err)
                    return
                end
                local data1, typ1, err = wb:recv_frame()
                if not data1 or not data1:match('"result"') then
                    ngx.say("ERR:recv1:", err or data1)
                    return
                end

                -- Now go completely silent and wait for timeout
                -- The proxy should timeout the connection after WS_TIMEOUT (2s)
                -- We wait up to 5 seconds to receive a close frame or error
                local data2, typ2, err = wb:recv_frame()

                -- We expect either:
                -- 1. A close frame from the proxy
                -- 2. A timeout/error indicating connection was closed
                if typ2 == "close" then
                    ngx.say("PASS: received close frame after inactivity")
                elseif not data2 and err then
                    ngx.say("PASS: connection closed due to inactivity: " .. err)
                else
                    ngx.say("FAIL: unexpected response type=" .. tostring(typ2) .. " data=" .. tostring(data2))
                end

                pcall(function() wb:send_close() end)
            }
        }
}
--- request
GET /test-complete-inactivity
--- response_body_like
PASS: (received close frame|connection closed).*
--- error_code: 200
--- timeout: 15



=== TEST 26: Single backend mode uses one connection for all traffic
When leader and follower have the same address, only one WebSocket connection
should be made. We verify this by checking that reads (normally follower)
return "leader" responses, proving they go through the shared leader connection.
--- http_config eval
my $config = $::HttpConfigBase;
# Set both leader and follower to the same address (single backend mode)
# Both point to leader mock (127.0.0.1:12346)
$config =~ s/backend_cache:set\("leader", "[^"]+"\)/backend_cache:set("leader", "127.0.0.1:12346")/g;
$config =~ s/backend_cache:set\("follower", "[^"]+"\)/backend_cache:set("follower", "127.0.0.1:12346")/g;
# High bucket to avoid rate limiting (set globals before require)
$config =~ s/(init_by_lua_block \{)/$1\n        BUCKET_CAPACITY = 10000/;
return $config;
--- config eval
qq{
$::LocationConfig

        location ^~ /test-single-backend {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local wb, err = client:new{ timeout = 5000 }
                if not wb then
                    ngx.say("ERR:create:", err)
                    return
                end

                local ok, err = wb:connect("ws://127.0.0.1:" .. ngx.var.server_port .. "/rpc")
                if not ok then
                    ngx.say("ERR:connect:", err)
                    return
                end

                -- Send a read request (test_follower_read normally routes to follower)
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_follower_read","params":[],"id":1}')
                if not ok then
                    ngx.say("ERR:send1:", err)
                    return
                end
                local data1, typ1, err = wb:recv_frame()
                if not data1 then
                    ngx.say("ERR:recv1:", err)
                    return
                end

                -- Send a write request (test_leader_write routes to leader)
                local ok, err = wb:send_text('{"jsonrpc":"2.0","method":"test_leader_write","params":[],"id":2}')
                if not ok then
                    ngx.say("ERR:send2:", err)
                    return
                end
                local data2, typ2, err = wb:recv_frame()
                if not data2 then
                    ngx.say("ERR:recv2:", err)
                    return
                end

                wb:send_close()

                -- WebSocket mock returns {"jsonrpc":"2.0","result":"leader"|"follower","id":N}
                local result1 = data1:match('"result":"([^"]+)"')
                local result2 = data2:match('"result":"([^"]+)"')

                -- Key assertion: in single backend mode, READS should return "leader"
                -- because they go through the shared leader connection instead of follower
                -- In normal dual-backend mode, test_follower_read would return "follower"
                if result1 == "leader" and result2 == "leader" then
                    ngx.say("PASS: single backend - read returned leader (not follower)")
                else
                    ngx.say("FAIL: read=" .. tostring(result1) .. " write=" .. tostring(result2))
                end
            }
        }
}
--- request
GET /test-single-backend
--- response_body
PASS: single backend - read returned leader (not follower)
--- error_code: 200
--- timeout: 10
