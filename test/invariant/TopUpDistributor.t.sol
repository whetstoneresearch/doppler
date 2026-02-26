// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Airlock } from "src/Airlock.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";

contract TopUpDistributorInvariantTest is Test {
    address public AIRLOCK_OWNER = address(0xb055);
    Airlock public airlock;
    TopUpDistributor public distributor;
    TopUpDistributorHandler public handler;

    constructor() {
        airlock = new Airlock(AIRLOCK_OWNER);
        distributor = new TopUpDistributor(address(airlock));
        handler = new TopUpDistributorHandler(distributor);
        vm.prank(AIRLOCK_OWNER);
        distributor.setPullUp(address(handler), true);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.newAsset.selector;
        selectors[1] = handler.topUp.selector;
        selectors[2] = handler.pullUp.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @dev For each numeraire, the distributor's balance must equal net deposits (topUp - pullUp)
    function invariant_TotalTopUpsEqualBalances() public view {
        for (uint256 i; i < handler.numerairesLength(); i++) {
            TestERC20 numeraire = handler.numeraires(i);
            uint256 expected = handler.totalToppedUp(numeraire) - handler.totalPulledUp(numeraire);
            assertEq(numeraire.balanceOf(address(distributor)), expected);
        }
    }

    /// @dev For each asset, total pulled must never exceed total topped up
    function invariant_CannotPullUpMoreThanTotalTopUps() public view {
        for (uint256 i; i < handler.assetsLength(); i++) {
            TestERC20 asset = handler.assets(i);
            (uint256 topped, uint256 pulled,) = handler.dataOf(asset);
            assertLe(pulled, topped);
        }
    }

    /// @dev For each numeraire, the recipient's balance must equal total pulled up
    function invariant_RecipientBalanceMatchesPullUps() public view {
        for (uint256 i; i < handler.numerairesLength(); i++) {
            TestERC20 numeraire = handler.numeraires(i);
            assertEq(numeraire.balanceOf(handler.RECIPIENT()), handler.totalPulledUp(numeraire));
        }
    }

    /// @dev For each asset, the on-chain topUpOf amount must match the handler's shadow state
    function invariant_OnChainAmountMatchesShadowState() public view {
        for (uint256 i; i < handler.assetsLength(); i++) {
            TestERC20 asset = handler.assets(i);
            (uint256 topped, uint256 pulled, TestERC20 numeraire) = handler.dataOf(asset);
            (address token0, address token1) = address(asset) < address(numeraire)
                ? (address(asset), address(numeraire))
                : (address(numeraire), address(asset));
            (uint256 onChainAmount,) = distributor.topUpOf(token0, token1);
            assertEq(onChainAmount, topped - pulled);
        }
    }
}

struct Data {
    uint256 topUp;
    uint256 pullUp;
    TestERC20 numeraire;
}

contract TopUpDistributorHandler is Test {
    TopUpDistributor public distributor;
    TestERC20[] public assets;
    TestERC20[] public numeraires;
    address public RECIPIENT = address(0xbeef);
    mapping(TestERC20 asset => Data) public dataOf;

    mapping(TestERC20 numeraire => uint256) public totalToppedUp;
    mapping(TestERC20 numeraire => uint256) public totalPulledUp;

    constructor(TopUpDistributor distributor_) {
        distributor = distributor_;

        // We want to make sure numeraire tokens are reused so we predeploy a few of them
        for (uint256 i; i < 5; i++) {
            numeraires.push(new TestERC20(0));
        }
    }

    function assetsLength() external view returns (uint256) {
        return assets.length;
    }

    function numerairesLength() external view returns (uint256) {
        return numeraires.length;
    }

    function newAsset(uint256 seed) public {
        vm.assume(seed % 100 < 5);
        TestERC20 asset = new TestERC20(0);
        assets.push(asset);
        dataOf[asset] = Data({ topUp: 0, pullUp: 0, numeraire: numeraires[seed % numeraires.length] });
    }

    function topUp(uint256 amount) public payable {
        vm.assume(assets.length > 0);
        TestERC20 asset = assets[amount % assets.length];
        // We want to avoid overflow issues in the tests, so we bound the amount to a reasonable value
        amount = bound(amount, 0, 1e30);
        TestERC20 numeraire = dataOf[asset].numeraire;
        numeraire.mint(address(this), amount);
        numeraire.approve(address(distributor), amount);
        distributor.topUp(address(asset), address(numeraire), amount);
        dataOf[asset].topUp += amount;
        totalToppedUp[numeraire] += amount;
    }

    function pullUp(uint256 seed) public {
        vm.assume(assets.length > 0);
        vm.assume(seed % 100 < 30);
        TestERC20 asset = assets[seed % assets.length];
        TestERC20 numeraire = dataOf[asset].numeraire;
        (address token0, address token1) = address(asset) < address(numeraire)
            ? (address(asset), address(numeraire))
            : (address(numeraire), address(asset));
        (uint256 amountToPullUp,) = distributor.topUpOf(token0, token1);
        vm.assume(amountToPullUp > 0);
        distributor.pullUp(token0, token1, RECIPIENT);
        dataOf[asset].pullUp += amountToPullUp;
        totalPulledUp[numeraire] += amountToPullUp;
    }
}

