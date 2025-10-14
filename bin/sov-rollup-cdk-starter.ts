#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { SovRollupCdkStarterStack } from '../lib/sov-rollup-cdk-starter-stack';

const app = new cdk.App();
new SovRollupCdkStarterStack(app, 'SovRollupCdkStarterStack', {

});