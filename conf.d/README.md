# Nginx Configuration Modules

This directory contains modular nginx configuration files that can be composed using `include` directives.

## Rate Limiting Configuration

The rate limiting setup uses OpenResty's Lua module to implement token bucket rate limiting with leader/follower routing for rollup nodes.

### Files

| File | Purpose |
|------|---------|
| `nginx-proxy-helpers.lua` | Core Lua module with rate limiting and proxy logic |
| `token-bucket-setup.conf` | Shared dict initialization and Lua module loading |
| `websocket-proxy.conf` | WebSocket location block with Lua handler |
| `proxy-location-rate-limited.conf` | HTTP location block with rate limiting |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        nginx worker                             │
├─────────────────────────────────────────────────────────────────┤
│  token-bucket-setup.conf                                        │
│  ├── lua_shared_dict token_buckets (cross-worker state)         │
│  ├── lua_package_path (module loading)                          │
│  └── init_by_lua_block (load nginx-proxy-helpers.lua)           │
├─────────────────────────────────────────────────────────────────┤
│  websocket-proxy.conf                                           │
│  ├── location = /rpc (HTTP or WebSocket)                        │
│  │   ├── WebSocket → proxy.handle_websocket()                   │
│  │   └── HTTP → rewrite to /_main_handler                       │
│  └── location ~ .*/ws$ (WebSocket only)                         │
│      ├── WebSocket → proxy.handle_websocket()                   │
│      └── HTTP → 426 Upgrade Required                            │
├─────────────────────────────────────────────────────────────────┤
│  proxy-location-rate-limited.conf                               │
│  └── location /_main_handler                                    │
│      ├── access_by_lua_block → proxy.apply_rate_limit()         │
│      └── content_by_lua_block → proxy.handle_http_request()     │
└─────────────────────────────────────────────────────────────────┘
```

### Endpoint Behavior

| Endpoint | HTTP Request | WebSocket Request |
|----------|--------------|-------------------|
| `/rpc` | JSON-RPC via HTTP handler | WebSocket proxy |
| `*.../ws` | 426 Upgrade Required | WebSocket proxy |

The `/rpc` endpoint supports both HTTP (for single JSON-RPC calls) and WebSocket (for streaming).
REST WebSocket endpoints (`/ws`) are WebSocket-only and reject plain HTTP requests.

### Rate Limiting

Token bucket algorithm with:
- **Bucket capacity**: 10,000 tokens per IP
- **Refill rate**: 1,000 tokens/second
- **Atomic operations**: Spinlock for concurrent request safety

Rate limit headers returned:
- `X-RateLimit-Limit`: Bucket capacity
- `X-RateLimit-Remaining`: Tokens remaining
- `X-RateLimit-Reset`: Seconds until bucket refills

### Leader/Follower Routing

Requests are routed based on JSON-RPC method:

| Method Pattern | Route | Use Case |
|----------------|-------|----------|
| `eth_sendRawTransaction` | Leader | Write operations |
| `eth_getBalance`, `eth_call`, etc. | Follower | Read operations |
| `eth_subscribe` | Follower | Subscription events |

### Usage

In your main nginx config:

```nginx
http {
    include conf.d/http-base.conf;
    include conf.d/token-bucket-setup.conf;

    server {
        listen 443 ssl;

        include conf.d/ssl.conf;
        include conf.d/websocket-proxy.conf;
        include conf.d/proxy-location-rate-limited.conf;
    }
}
```

See `nginx-https-rate-limited.conf` in the parent directory for a complete example.

### Testing

Tests use Test::Nginx and are located in `../test/`. Run with:

```bash
cd test
make test
```

### Environment Variables

The Lua module reads these nginx variables:
- `$leader_backend`: Leader node address (e.g., `127.0.0.1:8545`)
- `$follower_backend`: Follower node address (e.g., `127.0.0.1:8546`)
- `$rate_limit_override`: Set to `1` to bypass rate limiting (e.g., for allowlisted IPs)
