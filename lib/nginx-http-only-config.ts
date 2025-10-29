import {
  workerConfig,
  eventsConfig,
  httpBaseConfig,
  rateLimitingConfig,
  healthCheckLocation,
  acmeChallengeLocation,
  proxyLocation
} from './nginx-shared-config';

// Use the npm run generate-nginx-configs to get a human readable version of this config printed into 
// the nginx-configs directory. Running that command will not deploy the config or modify the stack in any way.
export const nginxHttpOnlyConfig = `${workerConfig}

${eventsConfig}

${httpBaseConfig}

${rateLimitingConfig}

    server {
        listen 80;
        server_name {{DOMAIN_NAME}};

${healthCheckLocation}

${acmeChallengeLocation}

${proxyLocation}
    }
}`;
