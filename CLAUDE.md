# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Build and Development
- **Build TypeScript**: `npm run build`
- **Watch mode**: `npm run watch` - Auto-compiles on file changes
- **CDK Synth**: `npx cdk synth` - Validate and generate CloudFormation templates
- **CDK Diff**: `npx cdk diff` - Compare deployed stack with local changes
- **CDK Deploy**: `npx cdk deploy` - Deploy stack to AWS
- **CDK Destroy**: `npx cdk destroy` - Remove deployed stack

### Testing
- Tests are not yet implemented. When adding tests, update the `test` script in package.json.

## Architecture

This is an AWS CDK v2 TypeScript project for building sovereign rollup infrastructure. The codebase follows standard CDK patterns:

### Structure
- **bin/sov-rollup-cdk-starter.ts**: CDK app entry point that instantiates the stack
- **lib/sov-rollup-cdk-starter-stack.ts**: Main stack definition where AWS resources should be added
- **test/**: Directory for future unit tests

### Key Patterns
- Uses CDK v2 with constructs pattern
- TypeScript with strict mode enabled
- Stack extends `cdk.Stack` base class
- Resources should be defined as constructs within the stack

### Development Workflow
1. Add AWS resources to `lib/sov-rollup-cdk-starter-stack.ts`
2. Use constructs from `aws-cdk-lib` for AWS services
3. Run `npm run build` before CDK commands
4. Always synth before deploying to catch errors early

### Common Resource Patterns for Rollup Infrastructure
When implementing sovereign rollup infrastructure, consider these AWS services:
- **Compute**: ECS/Fargate for containerized services, Lambda for event processing
- **Storage**: S3 for blob storage, DynamoDB for state, RDS for relational data
- **Messaging**: SQS for queuing, Kinesis for streaming
- **Networking**: VPC with proper subnet configuration
- **API**: API Gateway or ALB for external access

### TypeScript Configuration
- Target: ES2020
- Module: CommonJS
- Strict type checking enabled
- Source maps included for debugging