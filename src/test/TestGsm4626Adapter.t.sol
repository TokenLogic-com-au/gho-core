// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'forge-std/console2.sol';

import {AccessControlErrorsLib, OwnableErrorsLib} from './helpers/ErrorsLib.sol';

import {TransparentUpgradeableProxy} from 'solidity-utils/contracts/transparent-proxy/TransparentUpgradeableProxy.sol';
import {ProxyAdmin} from 'solidity-utils/contracts/transparent-proxy/ProxyAdmin.sol';
import {PercentageMath} from '@aave/core-v3/contracts/protocol/libraries/math/PercentageMath.sol';
import {IAToken} from '@aave/core-v3/contracts/interfaces/IAToken.sol';
import {IERC20} from 'aave-stk-v1-5/src/interfaces/IERC20.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {MiscEthereum} from 'aave-address-book/MiscEthereum.sol';

import {FixedPriceStrategy4626} from '../contracts/facilitators/gsm/priceStrategy/FixedPriceStrategy4626.sol';
import {FixedPriceStrategy} from '../contracts/facilitators/gsm/priceStrategy/FixedPriceStrategy.sol';
import {FixedFeeStrategy} from '../contracts/facilitators/gsm/feeStrategy/FixedFeeStrategy.sol';
import {SampleSwapFreezer} from '../contracts/facilitators/gsm/misc/SampleSwapFreezer.sol';
import {SampleLiquidator} from '../contracts/facilitators/gsm/misc/SampleLiquidator.sol';
import {Gsm4626Adapter, StaticAtoken} from '../contracts/facilitators/gsm/Gsm4626Adapter.sol';
import {Gsm4626} from '../contracts/facilitators/gsm/Gsm4626.sol';
import {Gsm} from '../contracts/facilitators/gsm/Gsm.sol';
import {GhoToken} from '../contracts/gho/GhoToken.sol';
import {Events} from './helpers/Events.sol';


/// to run this test: forge test --match-path src/test/TestGsm4626Adapter.t.sol -vv
contract TestGsmAdapter is Test, Events {
  using PercentageMath for uint256;
  using PercentageMath for uint128;

  Gsm4626Adapter internal GSM_ADAPTER;
  Gsm4626 internal GSM_4626;

  address internal gsmSignerAddr;
  uint256 internal gsmSignerKey;

  SampleSwapFreezer internal GHO_GSM_SWAP_FREEZER;
  SampleLiquidator internal GHO_GSM_LAST_RESORT_LIQUIDATOR;
  FixedPriceStrategy4626 internal GHO_GSM_4626_FIXED_PRICE_STRATEGY;

  IERC20 internal USDC_TOKEN = IERC20(AaveV3EthereumAssets.USDC_UNDERLYING);
  IERC20 internal WETH = IERC20(AaveV3EthereumAssets.WETH_UNDERLYING);
  GhoToken internal GHO_TOKEN = GhoToken(AaveV3EthereumAssets.GHO_UNDERLYING);
  address internal USDC_ATOKEN = 0x73edDFa87C71ADdC275c2b9890f5c3a8480bC9E6;
  address internal POOL = address(AaveV3Ethereum.POOL);
  address internal PROXY_ADMIN_OWNER = address(GovernanceV3Ethereum.EXECUTOR_LVL_1);
  address internal TREASURY = address(AaveV3Ethereum.COLLECTOR);

  // https://etherscan.io/address/0x0d8eFfC11dF3F229AA1EA0509BC9DFa632A13578
  // Gsm internal constant OLD_GSM = Gsm(0x0d8eFfC11dF3F229AA1EA0509BC9DFa632A13578);

  /// https://etherscan.io/address/0xD3cF979e676265e4f6379749DECe4708B9A22476
  ProxyAdmin internal constant GSM_PROXY_ADMIN =
    ProxyAdmin(0xD3cF979e676265e4f6379749DECe4708B9A22476);

  /// https://etherscan.io/address/0x430BEdcA5DfA6f94d1205Cb33AB4f008D0d9942a
  FixedPriceStrategy internal constant GHO_GSM_FIXED_PRICE_STRATEGY =
    FixedPriceStrategy(0x430BEdcA5DfA6f94d1205Cb33AB4f008D0d9942a);

  /// https://etherscan.io/address/0x83896a35db4519BD8CcBAF5cF86CCA61b5cfb938
  FixedFeeStrategy internal constant GHO_GSM_FIXED_FEE_STRATEGY =
    FixedFeeStrategy(0x83896a35db4519BD8CcBAF5cF86CCA61b5cfb938);

  uint256 internal constant YIELD_AMOUNT = 100e6;

  /// taken from Constants.sol
  bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
  bytes32 internal constant GSM_CONFIGURATOR_ROLE = keccak256('CONFIGURATOR_ROLE');
  bytes32 internal constant GSM_TOKEN_RESCUER_ROLE = keccak256('TOKEN_RESCUER_ROLE');
  bytes32 internal constant GSM_SWAP_FREEZER_ROLE = keccak256('SWAP_FREEZER_ROLE');
  bytes32 internal constant GSM_LIQUIDATOR_ROLE = keccak256('LIQUIDATOR_ROLE');
  bytes32 internal constant GHO_TOKEN_FACILITATOR_MANAGER_ROLE =
    keccak256('FACILITATOR_MANAGER_ROLE');
  uint128 internal constant DEFAULT_GSM_USDC_EXPOSURE = 100_000_000e6;
  uint128 internal constant DEFAULT_GSM_USDC_AMOUNT = 100e6;
  uint128 internal constant DEFAULT_GSM_GHO_AMOUNT = 100e18;
  uint256 internal constant DEFAULT_GSM_SELL_FEE = 0.1e4; // 10%
  uint256 internal constant DEFAULT_GSM_BUY_FEE = 0.1e4; // 10%
  uint128 internal constant DEFAULT_CAPACITY = 100_000_000e18;
  address internal constant ALICE = address(0x1111);
  address internal constant BOB = address(0x1112);
  address internal constant CHARLES = address(0x1113);

  // signature typehash for GSM
  bytes32 internal constant GSM_BUY_ASSET_WITH_SIG_TYPEHASH =
    keccak256(
      'BuyAssetWithSig(address originator,uint256 minAmount,address receiver,uint256 nonce,uint256 deadline)'
    );
  bytes32 internal constant GSM_SELL_ASSET_WITH_SIG_TYPEHASH =
    keccak256(
      'SellAssetWithSig(address originator,uint256 maxAmount,address receiver,uint256 nonce,uint256 deadline)'
    );

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('mainnet'), 20814911);
    (gsmSignerAddr, gsmSignerKey) = makeAddrAndKey('gsmSigner');

    GHO_GSM_SWAP_FREEZER = new SampleSwapFreezer();
    GHO_GSM_LAST_RESORT_LIQUIDATOR = new SampleLiquidator();

    GHO_GSM_4626_FIXED_PRICE_STRATEGY = new FixedPriceStrategy4626(
      1e18,
      address(USDC_ATOKEN),
      6
    );

    /// Deploy Gsm4626Adapter & upgrade current gsm impl
    
    Gsm4626 gsm = new Gsm4626(
      address(GHO_TOKEN),
      USDC_ATOKEN,
      address(GHO_GSM_4626_FIXED_PRICE_STRATEGY)
    );
    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE);
    gsm.updateFeeStrategy(address(GHO_GSM_FIXED_FEE_STRATEGY));
    vm.prank(PROXY_ADMIN_OWNER);
    GHO_TOKEN.addFacilitator(address(gsm), 'GSM 4626 Facilitator', DEFAULT_CAPACITY);

    Gsm4626Adapter adapter = new Gsm4626Adapter(
      address(gsm),
      address(USDC_TOKEN)
    );
    vm.prank(PROXY_ADMIN_OWNER);
    GHO_TOKEN.grantRole(GHO_TOKEN_FACILITATOR_MANAGER_ROLE, address(this));

    
    gsm.grantRole(GSM_SWAP_FREEZER_ROLE, address(GHO_GSM_SWAP_FREEZER));
    gsm.grantRole(GSM_LIQUIDATOR_ROLE, address(GHO_GSM_LAST_RESORT_LIQUIDATOR));

    GSM_4626 = gsm;
    GSM_ADAPTER = adapter;
  }

  function testSellAssetZeroFee() public {
    /// sends 0.5e6 ATOKEN to the underlying 4626 GSM, and the adapter (this does nothing)
    simulateAusdcYield(0.5e6);
    vm.expectEmit(true, true, false, true, address(GSM_4626));
    emit FeeStrategyUpdated(address(GHO_GSM_FIXED_FEE_STRATEGY), address(0));
    GSM_4626.updateFeeStrategy(address(0));

    uint256 aUsdcBalanceBefore = IERC20(USDC_ATOKEN).balanceOf(address(GSM_4626));
    uint256 sharesAmount = StaticAtoken(GSM_4626.UNDERLYING_ASSET()).previewDeposit(DEFAULT_GSM_USDC_AMOUNT);
    uint256 sharesAmountInGho = GHO_GSM_4626_FIXED_PRICE_STRATEGY.getAssetPriceInGho(sharesAmount, false);
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GSM_ADAPTER), DEFAULT_GSM_USDC_AMOUNT);
    // vm.expectEmit(true, true, true, true, address(GSM_4626));
    // emit SellAsset(address(GSM_ADAPTER), ALICE, sharesAmount, sharesAmountInGho, 0);
    (uint256 assetAmount, uint256 ghoBought) = GSM_ADAPTER.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    uint256 aUsdcBalanceAfter = IERC20(USDC_ATOKEN).balanceOf(address(GSM_4626));

    assertEq(ghoBought, sharesAmountInGho, 'Unexpected GHO amount bought');
    assertEq(assetAmount, sharesAmount, 'Unexpected asset amount sold');
    assertEq(aUsdcBalanceAfter, aUsdcBalanceBefore + sharesAmount, 'Unexpected asset balance after');

    assertEq(USDC_TOKEN.balanceOf(address(GSM_ADAPTER)), 0, 'Unexpected GSM Adapter final USDC after');
    assertEq(USDC_TOKEN.balanceOf(address(GSM_4626)), 0, 'Unexpected GSM 4626 final USDC after');
    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected Alice final USDC balance');

    assertEq(IERC20(USDC_ATOKEN).balanceOf(address(GSM_ADAPTER)), 0.5e6, 'Unexpected GSM Adapter final aUSDC after');
    assertEq(IERC20(USDC_ATOKEN).balanceOf(address(GSM_4626)), 0.5e6 + sharesAmount, 'Unexpected GSM 4626 final USDC after');

    assertEq(GHO_TOKEN.balanceOf(ALICE), DEFAULT_GSM_GHO_AMOUNT, 'Unexpected final GHO balance');

    assertEq(GSM_ADAPTER.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function _sellAsset(
    Gsm4626Adapter gsm,
    IERC20 token,
    address receiver,
    uint256 amount
  ) internal returns (uint256) {
    mintUsdc(address(0xb00b), amount);
    vm.startPrank(address(0xb00b));
    token.approve(address(gsm), amount);
    (, uint256 ghoBought) = gsm.sellAsset(amount, receiver);
    vm.stopPrank();
    return ghoBought;
  }

  function _buyAsset(
    Gsm4626Adapter gsm,
    IERC20 token,
    address receiver,
    uint256 amount
  ) internal returns (uint256) {
    mintGho(address(0xb00b), amount);
    vm.startPrank(address(0xb00b));
    token.approve(address(gsm), amount);
    (uint256 usdcBought, ) = gsm.buyAsset(amount, receiver);
    vm.stopPrank();
    return usdcBought;
  }

  function mintUsdc(address to, uint256 amount) internal {
    mint(address(USDC_TOKEN), to, amount);
  }

  function mintGho(address to, uint256 amount) internal {
    mint(address(GHO_TOKEN), to, amount);
  }

  function mintWeth(address to, uint256 amount) internal {
    mint(address(WETH), to, amount);
  }

  function mint(address token, address to, uint256 amount) internal {
    uint256 currentBalance = IERC20(token).balanceOf(to);
    deal(token, to, currentBalance + amount);
  }

  function simulateAusdcYield(uint256 amount) internal {
    vm.startPrank(0x8EA2A9764fA673D790e8AcC7DCb7f8532854271c);
    IERC20(USDC_ATOKEN).transfer(address(GSM_4626), amount);
    IERC20(USDC_ATOKEN).transfer(address(GSM_ADAPTER), amount);
    vm.stopPrank();
  }
}
