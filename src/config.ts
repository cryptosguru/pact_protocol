/**
 * Example configuration that can be used to deploy contracts to different envs.
 */

import { IKeyPair } from 'ts-pact'

export interface IConfig {
  adminKeyPair: IKeyPair
  pactUrl: string
}

function decodeEnvHex(key: string): Buffer {
  return Buffer.from(process.env[key] || '', 'hex')
}

const configs: { [env: string]: IConfig } = {
  dev: {
    adminKeyPair: {
      publicKey: decodeEnvHex('PACT_ADMIN_PUBLIC'),
      privateKey: decodeEnvHex('PACT_ADMIN_PRIVATE'),
    },
    pactUrl: process.env.PACT_URL || 'http://localhost:9444',
  },
}

export default configs
