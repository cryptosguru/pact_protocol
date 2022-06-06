## Specifications

This implementation of the protocol uses X25519-Chacha20-Poly1305 for encryption/decryption, and blake2b for hashing.

All binary data is encoded in unpadded Base64URL. Public and private keys are encoded in hex format.

## Installation

Download the latest version of pact, e.g. from https://github.com/kadena-io/pact/releases
or through Homebrew via:

```bash
brew install kadena-io/pact/pact
```

The contracts require Pact v3.3.1 or higher.

## Deploy and initialize contracts locally

```bash
yarn
yarn compile
yarn start

# In another tab:
yarn deploy
```

## Smart contracts

The smart contracts in `contracts/` are as follows:
* `finprint.pact`: The core  protocol, including staking functions.
* `finprint-token.pact`: The  token, based on the Pact fungible token interface defined in `fungible-v1.pact`


## Unit tests

Run all unit tests:
```
yarn test
```
Use the -v option to print out failures or -vv to print all test output. A glob or the name of a specific .repl file can be passed as a positional argument to run specific tests.

Alternatively, the tests can be run in the pact interpreter as follows:
```
pact> (load "test/finprint.repl")
pact> (load "test/finprint-token.repl")
```
