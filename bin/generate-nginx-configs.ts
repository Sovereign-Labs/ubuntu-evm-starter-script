#!/usr/bin/env node

// Prints the programmatically generated nginx config files into the `nginx-configs` directory.
import * as fs from 'fs';
import * as path from 'path';
import { nginxHttpOnlyConfig } from '../lib/nginx-http-only-config';
import { nginxHttpsConfig } from '../lib/nginx-https-config';

// Create output directory
const outputDir = path.join(__dirname, '..', 'nginx-configs');
if (!fs.existsSync(outputDir)) {
  fs.mkdirSync(outputDir, { recursive: true });
}

// Generate HTTP-only config
const httpConfig = nginxHttpOnlyConfig

// Generate HTTPS config
const httpsConfig = nginxHttpsConfig

// Write configs to files
fs.writeFileSync(path.join(outputDir, 'nginx-http-only.conf'), httpConfig);
fs.writeFileSync(path.join(outputDir, 'nginx-https.conf'), httpsConfig);

console.log(`Nginx config files generated in ${outputDir}/`);
