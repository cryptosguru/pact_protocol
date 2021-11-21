import path from 'path'

import { IKeyPair, PactApi, pactUtils } from 'ts-pact'

const CONTRACTS_DIR = path.normalize(__dirname + '/../../contracts')

// File paths of contracts to deploy, relative to `CONTRACTS_DIR`. In order of deployment.
const CONTRACTS = ['finprint-token.pact', 'finprint.pact']

// Transactions to run to initialize the smart contracts.
// This code and any functions called may reference the admin key pair via the name 'admin-keyset'.
const INIT_STEPS = [
  '(finprint-token.initialize)',
  '(finprint.initialize)',
]

/**
 * In sandbox and prod envs, the private key should be set as an env variable.
 *
 * In dev env, the public and private keys can be set, otherwise a random key will be used.
 */
export function useOrGenerateKeyPair(keyPair: IKeyPair, label: string): IKeyPair {
  if (keyPair.publicKey.length === 0) {
    console.log(`Generating a random key pair for: ${label}`)
    return pactUtils.generateKeyPair()
  } else {
    if (keyPair.privateKey.length === 0) {
      throw new Error(`Aborting: Private key was not set for: ${label}`)
    } else {
      return keyPair
    }
  }
}

/**
 * Deploy a contract. Returned value should be the string: "Success."
 */
async function deployContract(pactApi: PactApi, adminKeyPair: IKeyPair, contractFilename: string): Promise<void> {
  const result = await pactApi.eval({
    codeFile: contractFilename,
    data: pactUtils.keysetData(adminKeyPair.publicKey, 'admin-keyset'),
    keyPair: adminKeyPair,
  })
  console.log(`Deployed contract '${contractFilename}' with result: ${result}`)
}

export async function deployAndInitializeFinprintContracts(pactApi: PactApi, adminKeyPair: IKeyPair): Promise<{}[]> {
  for (const contract of CONTRACTS) {
    const path = `${CONTRACTS_DIR}/${contract}`
    await deployContract(pactApi, adminKeyPair, path)
  }
  const results: {}[] = []
  for (const code of INIT_STEPS) {
    const result = await pactApi.eval({
      code,
      data: pactUtils.keysetData(adminKeyPair.publicKey, 'admin-keyset'),
      keyPair: adminKeyPair,
    })
    results.push(result)
  }
  return results
}
