pragma solidity 0.8.26;

import { Doppler } from "../../src/Doppler.sol";

struct DopplerImmutables {
  uint256 startingTime;
  uint256 endingTime;
  uint256 epochLength;
  bool isToken0;
  uint256 numTokensToSell;
  uint256 minimumProceeds;
  uint256 maximumProceeds;
  int24 startingTick;
  int24 endingTick;
  int24 gamma;
  uint256 totalEpochs;
  uint256 numPDSlugs;
}

contract DopplerLens {
    constructor() {}

    function getDopplerImmutables(address payable tgt) public view returns (DopplerImmutables memory imms) {
      Doppler doppler = Doppler(tgt);
      imms.startingTime = doppler.startingTime();
      imms.endingTime = doppler.endingTime();
      imms.epochLength = doppler.epochLength();
      imms.isToken0 = doppler.isToken0();
      imms.numTokensToSell = doppler.numTokensToSell();
      imms.minimumProceeds = doppler.minimumProceeds();
      imms.maximumProceeds = doppler.maximumProceeds();
      imms.startingTick = doppler.startingTick();
      imms.endingTick = doppler.endingTick();
      imms.gamma = doppler.gamma();
      imms.totalEpochs = doppler.totalEpochs();
      imms.numPDSlugs = doppler.numPDSlugs();
    }

}
