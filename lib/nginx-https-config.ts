import {
  workerConfig,
  eventsConfig,
  httpBaseConfig,
  rateLimitingConfig,
  healthCheckLocation,
  acmeChallengeLocation,
  proxyLocation,
  sslConfig
} from './nginx-shared-config';

// Use the npm run generate-nginx-configs to get a human readable version of this config printed into 
// the nginx-configs directory. Running that command will not deploy the config or modify the stack in any way.
export const nginxHttpsConfig = `${workerConfig}

${eventsConfig}

${httpBaseConfig}

${rateLimitingConfig}

    server {
        listen 80;
        server_name {{DOMAIN_NAME}};

${healthCheckLocation}

${acmeChallengeLocation}

        # Redirect all other HTTP traffic to HTTPS
        location / {
            return 301 https://$server_name$request_uri;
        }
    }

    server {
        listen 443 ssl;
        http2 on;
        server_name {{DOMAIN_NAME}};

${sslConfig}

${healthCheckLocation}

${proxyLocation}
    }
}`;
