/**
 * Example of a deployment script for the Finprint contracts, leveraging ts-pact.
 */

import { PactApi } from 'ts-pact'

import configs from './config'
import { deployAndInitializeFinprintContracts, useOrGenerateKeyPair } from './lib'

// Config options can be specified for different envs in config.ts.
const env = process.env.SERVICE_ENV || 'dev'
const config = configs[env]
if (!config) {
  console.error(`Unknown SERVICE_ENV: '${env}'`)
  process.exit(1)
}

;(async () => {

  // Use key pairs from the config or generate if necessary.
  const adminKeyPair = useOrGenerateKeyPair(config.adminKeyPair, 'admin')

  const pactApi = new PactApi(config.pactUrl)
  console.log(`Connecting to Pact server at ${config.pactUrl}`)
  console.log(`Deploying with public key ${adminKeyPair.publicKey}`)

  await deployAndInitializeFinprintContracts(pactApi, adminKeyPair)

})().catch(console.error)
