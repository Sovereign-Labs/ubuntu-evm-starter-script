FROM openresty/openresty:alpine

# Install dependencies
RUN apk add --no-cache \
    postgresql-client \
    redis \
    curl

# Copy nginx configuration
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# Create log directory
RUN mkdir -p /var/log/nginx

# Expose port 80
EXPOSE 80

# Start nginx
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]