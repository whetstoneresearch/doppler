import {AbiParameter, encodeAbiParameters,parseAbiParameters} from 'viem';

import DopplerDeployerJson from './out/UniswapV4Initializer.sol/DopplerDeployer.json';
import DopplerLensJson from './out/DopplerLens.sol/DopplerLensQuoter.json';

import BroadcastJson from './broadcast/Deploy.s.sol/1301/run-latest.json';
import { Abi } from 'ox';

function getConstructorSig(jsonFile): string {
  let sig = '';

  for (let i = 0; i < jsonFile.abi.length; i++) {
    const item = jsonFile.abi[i];

    if (item.type === 'constructor') {
      for (let j = 0; j < item.inputs.length; j++) {
        const input = item.inputs[j];
        sig += `${input.type}`;
  
        if (j < item.inputs.length - 1) {
          sig += ',';
        }
      }
    }
  }

  return sig;
}

function getConstructorParams(contractName): AbiParameter[] {
  for (let i = 0; i < BroadcastJson.transactions.length; i++) {
    const transaction = BroadcastJson.transactions[i];

    if (transaction.contractName === contractName) {
      return transaction.arguments as unknown as AbiParameter[];
    }
  }

  throw new Error('Not found');
}

console.log(getConstructorSig(DopplerLensJson));

const encoded = encodeAbiParameters(
  parseAbiParameters(getConstructorSig(DopplerLensJson)),
  getConstructorParams('DopplerLensQuoter'),
);

console.log(encoded);
