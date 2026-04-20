# Nginx Configuration Modules

This directory contains modular nginx configuration files that can be composed using `include` directives.

## Rate Limiting Configuration

The rate limiting setup uses OpenResty's Lua module to implement token bucket rate limiting with leader/follower routing for rollup nodes.

### Files

| File | Purpose |
|------|---------|
| `http-base.conf` | Base HTTP config: Cloudflare, logging, shared dicts, Lua module loading |
| `nginx-proxy-helpers.lua` | Core Lua module with rate limiting and proxy logic |
| `websocket-proxy.conf` | WebSocket location block with Lua handler |
| `http-proxy.conf` | HTTP location block with rate limiting |
| `common-locations.conf` | Health check and ACME challenge locations |
| `api-key-locations.conf` | API key URL rewriting for secure endpoints |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        nginx worker                             │
├─────────────────────────────────────────────────────────────────┤
│  http-base.conf                                                 │
│  ├── lua_shared_dict token_buckets (cross-worker state)         │
│  ├── lua_shared_dict backend_cache (leader/follower IPs)        │
│  ├── lua_shared_dict failed_auth_limit (brute force protection) │
│  ├── lua_package_path (module loading)                          │
│  ├── init_by_lua_block (load nginx-proxy-helpers.lua)           │
│  └── $rate_limit_key (exemption: "1" = exempt, "0" = limited)   │
├─────────────────────────────────────────────────────────────────┤
│  websocket-proxy.conf                                           │
│  ├── location = /rpc (HTTP or WebSocket)                        │
│  │   ├── WebSocket → proxy.handle_websocket()                   │
│  │   └── HTTP → rewrite to @http_handler                        │
│  └── location ~ .*/ws$ (WebSocket only)                         │
│      ├── WebSocket → proxy.handle_websocket()                   │
│      └── HTTP → 426 Upgrade Required                            │
├─────────────────────────────────────────────────────────────────┤
│  http-proxy.conf                                                │
│  ├── location @http_handler (internal redirect target)          │
│  └── location ~ ^/ (catch-all)                                  │
│      └── access_by_lua_block → proxy.handle_http_request()      │
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

Token bucket algorithm with configurable limits per server block:
- **Bucket capacity**: Set via `$bucket_capacity` (default: 150 tokens)
- **Refill rate**: Set via `$refill_rate` (default: 150 tokens/sec)
- **Concurrency**: Uses `resty.lock` mutex for cross-worker safety
- **Storage**: Single key per IP with packed `"tokens:timestamp"` format (memory efficient)
- **TTL**: 1 hour, refreshed on every request (including rate-limited) to prevent bucket reset exploits

Rate limit headers returned:
- `X-RateLimit-Capacity`: Bucket capacity
- `X-RateLimit-Remaining`: Tokens remaining
- `X-RateLimit-Cost`: Cost of the request

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

    server {
        listen 443 ssl;

        # Rate limit settings
        set $bucket_capacity 150;
        set $refill_rate 150;

        include conf.d/ssl.conf;
        include conf.d/common-locations.conf;
        include conf.d/websocket-proxy.conf;
        include conf.d/http-proxy.conf;
    }
}
```

See `regular-proxy.conf` in the parent directory for a complete example.

### Testing

Tests use Test::Nginx and are located in `../test/`. Run with:

```bash
cd test
make test
```

### Nginx Variables

The Lua module reads these nginx variables:
- `$bucket_capacity`: Token bucket size (default: 150)
- `$refill_rate`: Tokens added per second (default: 150)
- `$rate_limit_key`: Set to `1` to bypass rate limiting (via `$ip_exempt` or `$host_exempt`)
- `$require_api_key`: Set to `1` to require API key authentication
- `$valid_api_key`: Set by map based on `/rpc/<key>` pattern matching
