# alpha-blockchain
Includes alpha blockchain contracts, migrations, tests

## Contracts

### Agent
* Per-service contract that manages the creation of Job instances at the request of consumers

### AgentFactory
* Per-network contract that manages the creation of Agent instances at the request of service owners

### Job
* Per-service-invocation contract that performs escrow functionality with release of funds gated on a valid consumer signature

### Registry
* Per-network contract that maintains a mapping from name to agent address whose records can be updated and deprecated by the owner (first registrant) of the name

## Deployed Contracts
* AgentFactory (Kovan): 
* Registry (Kovan): 

## Requirements
* [Node.js](https://github.com/nodejs/node) (8+)
* [Npm](https://www.npmjs.com/package/npm)

## Install

### Dependencies
```bash
npm install
```

### Test 
```bash
npm run test
```

## Package
```bash
npm run package-npm
```

## Release
AgentFactory and Registry artifacts are published to NPM: https://www.npmjs.com/package/singularitynet-alpha-blockchain
