// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import {
    Airlock,
    CreateParams,
    ITokenFactory,
    IGovernanceFactory,
    IPoolInitializer,
    ILiquidityMigrator
} from "src/Airlock.sol";
import { InitData } from "src/UniswapV3Initializer.sol";
import { DERC20 } from "src/DERC20.sol";

struct Params {
    Airlock airlock;
    ITokenFactory tokenFactory;
    IGovernanceFactory governanceFactory;
    IPoolInitializer poolInitializer;
    ILiquidityMigrator liquidityMigrator;
    address weth;
}

string constant NAME = "a";
string constant SYMBOL = "a";
string constant TOKEN_URI = "ipfs://QmPXxsEGfHHnCa8VuPoMS7n1pAhJVw1BnnfSx83sioE65y";
uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;
int24 constant LOWER_TICK = 167_520;
int24 constant UPPER_TICK = 200_040;
uint256 constant MAX_SHARE_TO_BE_SOLD = 0.9 ether;

contract CreateTokenScript is Script {
    function run() public {
        Params memory params = Params({
            airlock: Airlock(payable(address(0))),
            tokenFactory: ITokenFactory(address(0)),
            governanceFactory: IGovernanceFactory(address(0)),
            poolInitializer: IPoolInitializer(address(0)),
            liquidityMigrator: ILiquidityMigrator(address(0)),
            weth: address(0)
        });

        vm.startBroadcast();
        _deployToken(params);
        vm.stopBroadcast();
    }

    function _deployToken(
        Params memory params
    ) internal {
        // Will be set later on
        bool isToken0;

        /**
         * Governance data is encoded as follows:
         * string memory name,
         * uint48 initialVotingDelay,
         * uint32 initialVotingPeriod,
         * uint256 initialProposalThreshold
         */
        bytes memory governanceData = abi.encode(NAME, 7200, 50_400, INITIAL_SUPPLY / 1000);

        /**
         * Token factory data is encoded as follows:
         * string memory name,
         * string memory symbol,
         * uint256 yearlyMintCap,
         * uint256 vestingDuration,
         * address[] memory recipients,
         * uint256[] memory amounts,
         * string memory tokenURI
         */
        bytes memory tokenFactoryData = abi.encode(NAME, SYMBOL, 0, 0, new address[](0), new uint256[](0), TOKEN_URI);

        // Compute the asset address that will be created
        bytes32 salt;

        bytes memory creationCode = type(DERC20).creationCode;
        bytes memory create2Args = abi.encode(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            address(params.airlock),
            address(params.airlock),
            0,
            0,
            new address[](0),
            new uint256[](0),
            TOKEN_URI
        );
        address predictedAsset = vm.computeCreate2Address(
            salt, keccak256(abi.encodePacked(creationCode, create2Args)), address(params.tokenFactory)
        );

        isToken0 = predictedAsset < address(params.weth);

        int24 tickLower = isToken0 ? -UPPER_TICK : LOWER_TICK;
        int24 tickUpper = isToken0 ? -LOWER_TICK : UPPER_TICK;

        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: uint24(vm.envOr("V3_FEE", uint256(3000))),
                tickLower: tickLower,
                tickUpper: tickUpper,
                numPositions: 10,
                maxShareToBeSold: MAX_SHARE_TO_BE_SOLD
            })
        );

        (address asset,,,,) = params.airlock.create(
            CreateParams(
                INITIAL_SUPPLY,
                900_000_000 ether,
                params.weth,
                params.tokenFactory,
                tokenFactoryData,
                params.governanceFactory,
                governanceData,
                params.poolInitializer,
                poolInitializerData,
                params.liquidityMigrator,
                new bytes(0),
                address(0),
                salt
            )
        );

        console.log("Token deployed at: %s!", asset);

        require(asset == predictedAsset, "Predicted asset address doesn't match actual");
    }
}
