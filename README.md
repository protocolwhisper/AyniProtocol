# AyniProtocol

Solidity + Foundry version of the protocol contracts.

For a full architecture and flow explainer, see [PROJECT_OVERVIEW.md](./PROJECT_OVERVIEW.md).

## Stack

- Solidity `0.8.30`
- Foundry (`forge`)

## Layout

- `src/` protocol contracts
- `test/` Foundry tests and mocks

## Commands

```bash
forge build
forge test
```

## Deploy

Deploy the core stack:

```bash
forge script script/DeployProtocol.s.sol:DeployProtocol \
  --sig "run(address)" $OWNER \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --broadcast
```

Deploy a test stack with mock USDC and mock USDT markets for one collateral:

```bash
forge script script/DeployProtocol.s.sol:DeployProtocol \
  --sig "runWithMockDebts(address,address,address,uint256)" $OWNER $COLLATERAL $FEED 10000000000 \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --broadcast
```
