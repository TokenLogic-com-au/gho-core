// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'forge-std/console2.sol';

import {AccessControlErrorsLib, OwnableErrorsLib} from './helpers/ErrorsLib.sol';

import {TransparentUpgradeableProxy} from 'solidity-utils/contracts/transparent-proxy/TransparentUpgradeableProxy.sol';
import {ProxyAdmin} from 'solidity-utils/contracts/transparent-proxy/ProxyAdmin.sol';
import {PercentageMath} from '@aave/core-v3/contracts/protocol/libraries/math/PercentageMath.sol';
import {IERC20} from 'aave-stk-v1-5/src/interfaces/IERC20.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';

import {FixedPriceStrategy} from '../contracts/facilitators/gsm/priceStrategy/FixedPriceStrategy.sol';
import {FixedFeeStrategy} from '../contracts/facilitators/gsm/feeStrategy/FixedFeeStrategy.sol';
import {SampleSwapFreezer} from '../contracts/facilitators/gsm/misc/SampleSwapFreezer.sol';
import {SampleLiquidator} from '../contracts/facilitators/gsm/misc/SampleLiquidator.sol';
import {GsmV2} from '../contracts/facilitators/gsm/GsmV2.sol';
import {Gsm} from '../contracts/facilitators/gsm/Gsm.sol';
import {GhoToken} from '../contracts/gho/GhoToken.sol';
import {Events} from './helpers/Events.sol';

contract TestGsmV2 is Test, Events {
  using PercentageMath for uint256;
  using PercentageMath for uint128;

  address internal gsmSignerAddr;
  uint256 internal gsmSignerKey;

  GhoToken internal GHO_TOKEN = GhoToken(AaveV3EthereumAssets.GHO_UNDERLYING);
  IERC20 internal USDC_TOKEN = IERC20(AaveV3EthereumAssets.USDC_UNDERLYING);
  IERC20 internal WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  address internal USDC_ATOKEN = AaveV3EthereumAssets.USDC_A_TOKEN;
  address internal POOL = address(AaveV3Ethereum.POOL);

  ProxyAdmin internal OLD_GSM_PROXY_ADMIN = ProxyAdmin(0xD3cF979e676265e4f6379749DECe4708B9A22476);
  address internal proxyAdminOwner = 0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A;
  Gsm internal OLD_GSM = Gsm(0x0d8eFfC11dF3F229AA1EA0509BC9DFa632A13578);
  GsmV2 internal GHO_GSM;

  FixedPriceStrategy internal GHO_GSM_FIXED_PRICE_STRATEGY =
    FixedPriceStrategy(0x430BEdcA5DfA6f94d1205Cb33AB4f008D0d9942a);
  FixedFeeStrategy internal GHO_GSM_FIXED_FEE_STRATEGY =
    FixedFeeStrategy(0x83896a35db4519BD8CcBAF5cF86CCA61b5cfb938);

  /// taken from Constants.sol
  bytes32 internal DEFAULT_ADMIN_ROLE = bytes32(0);
  bytes32 public constant GSM_CONFIGURATOR_ROLE = keccak256('CONFIGURATOR_ROLE');
  bytes32 public constant GSM_TOKEN_RESCUER_ROLE = keccak256('TOKEN_RESCUER_ROLE');
  bytes32 public constant GSM_SWAP_FREEZER_ROLE = keccak256('SWAP_FREEZER_ROLE');
  bytes32 public constant GSM_LIQUIDATOR_ROLE = keccak256('LIQUIDATOR_ROLE');
  bytes32 public constant GHO_TOKEN_FACILITATOR_MANAGER_ROLE =
    keccak256('FACILITATOR_MANAGER_ROLE');
  SampleSwapFreezer GHO_GSM_SWAP_FREEZER;
  SampleLiquidator GHO_GSM_LAST_RESORT_LIQUIDATOR;
  uint128 constant DEFAULT_GSM_USDC_EXPOSURE = 100_000_000e6;
  uint128 constant DEFAULT_GSM_USDC_AMOUNT = 100e6;
  uint128 constant DEFAULT_GSM_GHO_AMOUNT = 100e18;
  uint256 constant DEFAULT_GSM_SELL_FEE = 0.1e4; // 10%
  uint256 constant DEFAULT_GSM_BUY_FEE = 0.1e4; // 10%
  uint128 constant DEFAULT_CAPACITY = 100_000_000e18;
  address constant ALICE = address(0x1111);
  address constant BOB = address(0x1112);
  address constant CHARLES = address(0x1113);

  address internal TREASURY = address(AaveV3Ethereum.COLLECTOR);

  // signature typehash for GSM
  bytes32 public constant GSM_BUY_ASSET_WITH_SIG_TYPEHASH =
    keccak256(
      'BuyAssetWithSig(address originator,uint256 minAmount,address receiver,uint256 nonce,uint256 deadline)'
    );
  bytes32 public constant GSM_SELL_ASSET_WITH_SIG_TYPEHASH =
    keccak256(
      'SellAssetWithSig(address originator,uint256 maxAmount,address receiver,uint256 nonce,uint256 deadline)'
    );

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('mainnet'), 20814911);
    (gsmSignerAddr, gsmSignerKey) = makeAddrAndKey('gsmSigner');

    /// Deploy gsmV2 & upgrade current gsm impl
    vm.startPrank(proxyAdminOwner);
    GsmV2 gsm = new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    OLD_GSM_PROXY_ADMIN.upgradeAndCall(
      TransparentUpgradeableProxy(payable(address(OLD_GSM))),
      address(gsm),
      abi.encodeWithSelector(
        gsm.initialize.selector,
        address(this),
        TREASURY,
        DEFAULT_GSM_USDC_EXPOSURE
      )
    );
    GHO_GSM = GsmV2(address(OLD_GSM));
    GHO_TOKEN.grantRole(GHO_TOKEN_FACILITATOR_MANAGER_ROLE, address(this));
    vm.stopPrank();

    GHO_GSM_SWAP_FREEZER = new SampleSwapFreezer();
    GHO_GSM_LAST_RESORT_LIQUIDATOR = new SampleLiquidator();
    GHO_GSM.grantRole(GSM_SWAP_FREEZER_ROLE, address(GHO_GSM_SWAP_FREEZER));
    GHO_GSM.grantRole(GSM_LIQUIDATOR_ROLE, address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
  }

  function testConstructor() public {
    GsmV2 gsm = new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    assertEq(gsm.GHO_TOKEN(), address(GHO_TOKEN), 'Unexpected GHO token address');
    assertEq(gsm.UNDERLYING_ASSET(), address(USDC_TOKEN), 'Unexpected underlying asset address');
    assertEq(gsm.UNDERLYING_ATOKEN(), USDC_ATOKEN, 'Unexpected aToken asset address');
    assertEq(gsm.POOL(), POOL, 'Unexpected pool address');
    assertEq(
      gsm.PRICE_STRATEGY(),
      address(GHO_GSM_FIXED_PRICE_STRATEGY),
      'Unexpected price strategy'
    );
    assertEq(gsm.getExposureCap(), 0, 'Unexpected exposure capacity');
  }

  function testRevertConstructorInvalidPriceStrategy() public {
    FixedPriceStrategy newPriceStrategy = new FixedPriceStrategy(1e18, address(GHO_TOKEN), 18);
    vm.expectRevert('INVALID_PRICE_STRATEGY');
    new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(newPriceStrategy)
    );
  }

  function testRevertConstructorZeroAddressParams() public {
    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmV2(
      address(0),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );

    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmV2(
      address(GHO_TOKEN),
      address(0),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );

    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      address(0),
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );

    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      address(0),
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
  }

  function testInitialize() public {
    GsmV2 gsm = new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    vm.expectEmit(true, true, true, true);
    emit RoleGranted(DEFAULT_ADMIN_ROLE, address(this), address(this));
    vm.expectEmit(true, true, false, true);
    emit GhoTreasuryUpdated(address(0), address(TREASURY));
    vm.expectEmit(true, true, false, true);
    emit ExposureCapUpdated(0, DEFAULT_GSM_USDC_EXPOSURE);
    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE);
    assertEq(gsm.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
    assertEq(IERC20(USDC_ATOKEN).allowance(address(gsm), POOL), type(uint256).max);
    assertEq(USDC_TOKEN.allowance(address(gsm), POOL), type(uint256).max);
  }

  function testRevertInitializeZeroAdmin() public {
    GsmV2 gsm = new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    gsm.initialize(address(0), TREASURY, DEFAULT_GSM_USDC_EXPOSURE);
  }

  function testRevertInitializeTwice() public {
    GsmV2 gsm = new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE);
    vm.expectRevert('Contract instance has already been initialized');
    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE);
  }

  function testSellAssetZeroFee() public {
    uint256 aUsdcBalanceBefore = IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM));
    uint256 usdcBalanceBefore = USDC_TOKEN.balanceOf(address(GHO_GSM));

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, 0);
    (uint256 assetAmount, uint256 ghoBought) = GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    uint256 aUsdcBalanceAfter = IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM));

    assertEq(ghoBought, DEFAULT_GSM_GHO_AMOUNT, 'Unexpected GHO amount bought');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected asset amount sold');
    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected Alice final USDC balance');
    assertEq(USDC_TOKEN.balanceOf(address(GHO_GSM)), 0, 'Unexpected GSM final USDC balance');
    assertApproxEqAbs(
      aUsdcBalanceAfter,
      aUsdcBalanceBefore + usdcBalanceBefore + DEFAULT_GSM_USDC_AMOUNT,
      1
    );
    assertEq(GHO_TOKEN.balanceOf(ALICE), DEFAULT_GSM_GHO_AMOUNT, 'Unexpected final GHO balance');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testSellAsset() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - fee;
    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));
    uint256 availableUnderlyingExposureBefore = GHO_GSM.getAvailableUnderlyingExposure();
    uint256 availableLiquidityBefore = GHO_GSM.getAvailableLiquidity();

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, fee);
    (uint256 assetAmount, uint256 ghoBought) = GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    assertEq(ghoBought, DEFAULT_GSM_GHO_AMOUNT - fee, 'Unexpected GHO amount bought');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected asset amount sold');
    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected final USDC balance');
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoOut, 'Unexpected final GHO balance');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + fee,
      'Unexpected GSM GHO balance'
    );
    assertEq(
      GHO_GSM.getAvailableUnderlyingExposure(),
      availableUnderlyingExposureBefore - DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected available underlying exposure'
    );
    assertEq(
      GHO_GSM.getAvailableLiquidity(),
      availableLiquidityBefore + DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected available liquidity'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testSellAssetSendToOther() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - fee;
    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, BOB, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, fee);
    (uint256 assetAmount, uint256 ghoBought) = GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
    vm.stopPrank();

    assertEq(ghoBought, DEFAULT_GSM_GHO_AMOUNT - fee, 'Unexpected GHO amount bought');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected asset amount sold');
    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected final USDC balance');
    assertEq(GHO_TOKEN.balanceOf(ALICE), 0, 'Unexpected final GHO balance');
    assertEq(GHO_TOKEN.balanceOf(BOB), ghoOut, 'Unexpected final GHO balance');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + fee,
      'Unexpected GSM GHO balance'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testSellAssetWithSig() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 deadline = block.timestamp + 1 hours;
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - fee;

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    mintUsdc(gsmSignerAddr, DEFAULT_GSM_USDC_AMOUNT);

    vm.prank(gsmSignerAddr);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);

    assertEq(GHO_GSM.nonces(gsmSignerAddr), 0, 'Unexpected before gsmSignerAddr nonce');

    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        GHO_GSM.DOMAIN_SEPARATOR(),
        GSM_SELL_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(
          gsmSignerAddr,
          DEFAULT_GSM_USDC_AMOUNT,
          gsmSignerAddr,
          GHO_GSM.nonces(gsmSignerAddr),
          deadline
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(gsmSignerKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    assertTrue(gsmSignerAddr != ALICE, 'Signer is the same as Alice');

    // Send the signature via another user
    vm.prank(ALICE);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(
      gsmSignerAddr,
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      DEFAULT_GSM_GHO_AMOUNT,
      fee
    );
    GHO_GSM.sellAssetWithSig(
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      gsmSignerAddr,
      deadline,
      signature
    );

    assertEq(GHO_GSM.nonces(gsmSignerAddr), 1, 'Unexpected final gsmSignerAddr nonce');
    assertEq(USDC_TOKEN.balanceOf(gsmSignerAddr), 0, 'Unexpected final USDC balance');
    assertEq(GHO_TOKEN.balanceOf(gsmSignerAddr), ghoOut, 'Unexpected final GHO balance');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + fee,
      'Unexpected GSM GHO balance'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testSellAssetWithSigExactDeadline() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    // EIP-2612 states the execution must be allowed in case deadline is equal to block.timestamp
    uint256 deadline = block.timestamp;
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - fee;

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    mintUsdc(gsmSignerAddr, DEFAULT_GSM_USDC_AMOUNT);

    vm.prank(gsmSignerAddr);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);

    assertEq(GHO_GSM.nonces(gsmSignerAddr), 0, 'Unexpected before gsmSignerAddr nonce');

    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        GHO_GSM.DOMAIN_SEPARATOR(),
        GSM_SELL_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(
          gsmSignerAddr,
          DEFAULT_GSM_USDC_AMOUNT,
          gsmSignerAddr,
          GHO_GSM.nonces(gsmSignerAddr),
          deadline
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(gsmSignerKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    assertTrue(gsmSignerAddr != ALICE, 'Signer is the same as Alice');

    // Send the signature via another user
    vm.prank(ALICE);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(
      gsmSignerAddr,
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      DEFAULT_GSM_GHO_AMOUNT,
      fee
    );
    GHO_GSM.sellAssetWithSig(
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      gsmSignerAddr,
      deadline,
      signature
    );

    assertEq(GHO_GSM.nonces(gsmSignerAddr), 1, 'Unexpected final gsmSignerAddr nonce');
    assertEq(USDC_TOKEN.balanceOf(gsmSignerAddr), 0, 'Unexpected final USDC balance');
    assertEq(GHO_TOKEN.balanceOf(gsmSignerAddr), ghoOut, 'Unexpected final GHO balance');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + fee,
      'Unexpected GSM GHO balance'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testRevertSellAssetWithSigExpiredSignature() public {
    uint256 deadline = block.timestamp - 1;

    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        GHO_GSM.DOMAIN_SEPARATOR(),
        GSM_SELL_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(
          gsmSignerAddr,
          DEFAULT_GSM_USDC_AMOUNT,
          gsmSignerAddr,
          GHO_GSM.nonces(gsmSignerAddr),
          deadline
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(gsmSignerKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    assertTrue(gsmSignerAddr != ALICE, 'Signer is the same as Alice');

    // Send the signature via another user
    vm.prank(ALICE);
    vm.expectRevert('SIGNATURE_DEADLINE_EXPIRED');
    GHO_GSM.sellAssetWithSig(
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      gsmSignerAddr,
      deadline,
      signature
    );
  }

  function testRevertSellAssetWithSigInvalidSignature() public {
    uint256 deadline = block.timestamp + 1 hours;

    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        GHO_GSM.DOMAIN_SEPARATOR(),
        GSM_SELL_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(
          gsmSignerAddr,
          DEFAULT_GSM_USDC_AMOUNT,
          gsmSignerAddr,
          GHO_GSM.nonces(gsmSignerAddr),
          deadline
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(gsmSignerKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    assertTrue(gsmSignerAddr != ALICE, 'Signer is the same as Alice');

    // Send the signature via another user
    vm.prank(ALICE);
    vm.expectRevert('SIGNATURE_INVALID');
    GHO_GSM.sellAssetWithSig(ALICE, DEFAULT_GSM_USDC_AMOUNT, ALICE, deadline, signature);
  }

  function testRevertSellAssetZeroAmount() public {
    vm.prank(ALICE);
    vm.expectRevert('INVALID_AMOUNT');
    GHO_GSM.sellAsset(0, ALICE);
  }

  function testRevertSellAssetNoAsset() public {
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectRevert('ERC20: transfer amount exceeds balance');
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();
  }

  function testRevertSellAssetNoAllowance() public {
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);
    vm.prank(ALICE);
    vm.expectRevert('ERC20: transfer amount exceeds allowance');
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
  }

  function testRevertSellAssetNoBucketCap() public {
    GsmV2 gsm = new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE);
    vm.prank(proxyAdminOwner);
    GHO_TOKEN.addFacilitator(address(gsm), 'GSM Modified Bucket Cap', DEFAULT_CAPACITY - 1);
    uint256 defaultCapInUsdc = DEFAULT_CAPACITY / (10 ** (18 - 6));

    mintUsdc(ALICE, defaultCapInUsdc);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(gsm), defaultCapInUsdc);
    vm.expectRevert('FACILITATOR_BUCKET_CAPACITY_EXCEEDED');
    gsm.sellAsset(defaultCapInUsdc, ALICE);
    vm.stopPrank();
  }

  function testRevertSellAssetTooMuchUnderlyingExposure() public {
    GsmV2 gsm = new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE - 1);
    vm.prank(proxyAdminOwner);
    GHO_TOKEN.addFacilitator(address(gsm), 'GSM Modified Exposure Cap', DEFAULT_CAPACITY);

    mintUsdc(ALICE, DEFAULT_GSM_USDC_EXPOSURE);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(gsm), DEFAULT_GSM_USDC_EXPOSURE);
    vm.expectRevert('EXOGENOUS_ASSET_EXPOSURE_TOO_HIGH');
    gsm.sellAsset(DEFAULT_GSM_USDC_EXPOSURE, ALICE);
    vm.stopPrank();
  }

  function testGetGhoAmountForSellAsset() public {
    (uint256 exactAssetAmount, uint256 ghoBought, uint256 grossAmount, uint256 fee) = GHO_GSM
      .getGhoAmountForSellAsset(DEFAULT_GSM_USDC_AMOUNT);

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    _sellAsset(GHO_GSM, USDC_TOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);

    assertEq(
      DEFAULT_GSM_USDC_AMOUNT - USDC_TOKEN.balanceOf(ALICE),
      exactAssetAmount,
      'Unexpected asset amount sold'
    );
    assertEq(ghoBought + fee, grossAmount, 'Unexpected GHO gross amount');
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoBought, 'Unexpected GHO bought amount');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + fee,
      'Unexpected GHO fee amount'
    );

    (uint256 assetAmount, uint256 exactGhoBought, uint256 grossAmount2, uint256 fee2) = GHO_GSM
      .getAssetAmountForSellAsset(ghoBought);
    assertEq(GHO_TOKEN.balanceOf(ALICE), exactGhoBought, 'Unexpected GHO bought amount');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected estimation of sold assets');
    assertEq(grossAmount, grossAmount2, 'Unexpected GHO gross amount');
    assertEq(fee, fee2, 'Unexpected GHO fee amount');
  }

  function testGetGhoAmountForSellAssetWithZeroFee() public {
    vm.prank(proxyAdminOwner);
    GHO_GSM.updateFeeStrategy(address(0));

    (uint256 exactAssetAmount, uint256 ghoBought, uint256 grossAmount, uint256 fee) = GHO_GSM
      .getGhoAmountForSellAsset(DEFAULT_GSM_USDC_AMOUNT);
    assertEq(fee, 0, 'Unexpected GHO fee amount');

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    _sellAsset(GHO_GSM, USDC_TOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);

    assertEq(
      DEFAULT_GSM_USDC_AMOUNT - USDC_TOKEN.balanceOf(ALICE),
      exactAssetAmount,
      'Unexpected asset amount sold'
    );
    assertEq(ghoBought, grossAmount, 'Unexpected GHO gross amount');
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoBought, 'Unexpected GHO bought amount');
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), ghoBalanceBefore, 'Unexpected GHO fee amount');

    (uint256 assetAmount, uint256 exactGhoBought, uint256 grossAmount2, uint256 fee2) = GHO_GSM
      .getAssetAmountForSellAsset(ghoBought);
    assertEq(GHO_TOKEN.balanceOf(ALICE), exactGhoBought, 'Unexpected GHO bought amount');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected estimation of sold assets');
    assertEq(grossAmount, grossAmount2, 'Unexpected GHO gross amount');
    assertEq(fee, fee2, 'Unexpected GHO fee amount');
  }

  function testGetGhoAmountForSellAssetWithZeroAmount() public {
    (uint256 exactAssetAmount, uint256 ghoBought, uint256 grossAmount, uint256 fee) = GHO_GSM
      .getGhoAmountForSellAsset(0);
    assertEq(exactAssetAmount, 0, 'Unexpected exact asset amount');
    assertEq(ghoBought, 0, 'Unexpected GHO bought amount');
    assertEq(grossAmount, 0, 'Unexpected GHO gross amount');
    assertEq(fee, 0, 'Unexpected GHO fee amount');

    (uint256 assetAmount, uint256 exactGhoBought, uint256 grossAmount2, uint256 fee2) = GHO_GSM
      .getAssetAmountForSellAsset(ghoBought);
    assertEq(exactGhoBought, 0, 'Unexpected exact gho bought');
    assertEq(assetAmount, 0, 'Unexpected estimation of sold assets');
    assertEq(grossAmount, grossAmount2, 'Unexpected GHO gross amount');
    assertEq(fee, fee2, 'Unexpected GHO fee amount');
  }

  function testBuyAssetZeroFee() public {
    vm.expectEmit(true, true, false, true, address(GHO_GSM));
    emit FeeStrategyUpdated(address(GHO_GSM_FIXED_FEE_STRATEGY), address(0));
    vm.prank(proxyAdminOwner);
    GHO_GSM.updateFeeStrategy(address(0));

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, 0);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    // Buy assets as another user
    mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT);
    vm.startPrank(BOB);
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit BuyAsset(BOB, BOB, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, 0);
    (uint256 assetAmount, uint256 ghoSold) = GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
    vm.stopPrank();

    assertEq(ghoSold, DEFAULT_GSM_GHO_AMOUNT, 'Unexpected GHO amount sold');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected asset amount bought');
    assertEq(USDC_TOKEN.balanceOf(BOB), DEFAULT_GSM_USDC_AMOUNT, 'Unexpected final USDC balance');
    assertEq(GHO_TOKEN.balanceOf(ALICE), DEFAULT_GSM_GHO_AMOUNT, 'Unexpected final GHO balance');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testBuyAsset() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - sellFee;
    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));
    uint256 availableUnderlyingExposureBefore = GHO_GSM.getAvailableUnderlyingExposure();
    uint256 availableLiquidityBefore = GHO_GSM.getAvailableLiquidity();

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, sellFee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    // Buy assets as another user
    mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.startPrank(BOB);
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit BuyAsset(BOB, BOB, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT + buyFee, buyFee);
    (uint256 assetAmount, uint256 ghoSold) = GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
    vm.stopPrank();

    assertEq(ghoSold, DEFAULT_GSM_GHO_AMOUNT + buyFee, 'Unexpected GHO amount sold');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected asset amount bought');
    assertEq(USDC_TOKEN.balanceOf(BOB), DEFAULT_GSM_USDC_AMOUNT, 'Unexpected final USDC balance');
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoOut, 'Unexpected final GHO balance');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + sellFee + buyFee,
      'Unexpected GSM GHO balance'
    );
    assertEq(
      GHO_GSM.getAvailableUnderlyingExposure(),
      availableUnderlyingExposureBefore,
      'Unexpected available underlying exposure'
    );
    assertEq(
      GHO_GSM.getAvailableLiquidity(),
      availableLiquidityBefore,
      'Unexpected available liquidity'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testBuyAssetSendToOther() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - sellFee;
    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, sellFee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    // Buy assets as another user
    mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.startPrank(BOB);
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit BuyAsset(BOB, CHARLES, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT + buyFee, buyFee);
    (uint256 assetAmount, uint256 ghoSold) = GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, CHARLES);
    vm.stopPrank();

    assertEq(ghoSold, DEFAULT_GSM_GHO_AMOUNT + buyFee, 'Unexpected GHO amount sold');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected asset amount bought');
    assertEq(USDC_TOKEN.balanceOf(BOB), 0, 'Unexpected final USDC balance');
    assertEq(
      USDC_TOKEN.balanceOf(CHARLES),
      DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected final USDC balance'
    );
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoOut, 'Unexpected final GHO balance');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + sellFee + buyFee,
      'Unexpected GSM GHO balance'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testBuyAssetWithSig() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));

    uint256 deadline = block.timestamp + 1 hours;
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - sellFee;

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, sellFee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    assertTrue(gsmSignerAddr != ALICE, 'Signer is the same as Alice');

    // Buy assets as another user
    mintGho(gsmSignerAddr, DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.prank(gsmSignerAddr);
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT + buyFee);

    assertEq(GHO_GSM.nonces(gsmSignerAddr), 0, 'Unexpected before gsmSignerAddr nonce');

    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        GHO_GSM.DOMAIN_SEPARATOR(),
        GSM_BUY_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(
          gsmSignerAddr,
          DEFAULT_GSM_USDC_AMOUNT,
          gsmSignerAddr,
          GHO_GSM.nonces(gsmSignerAddr),
          deadline
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(gsmSignerKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    assertTrue(gsmSignerAddr != BOB, 'Signer is the same as Bob');

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit BuyAsset(
      gsmSignerAddr,
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      DEFAULT_GSM_GHO_AMOUNT + buyFee,
      buyFee
    );
    GHO_GSM.buyAssetWithSig(
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      gsmSignerAddr,
      deadline,
      signature
    );

    assertEq(GHO_GSM.nonces(gsmSignerAddr), 1, 'Unexpected final gsmSignerAddr nonce');
    assertEq(
      USDC_TOKEN.balanceOf(gsmSignerAddr),
      DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected final USDC balance'
    );
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoOut, 'Unexpected final GHO balance');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + sellFee + buyFee,
      'Unexpected GSM GHO balance'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testBuyAssetWithSigExactDeadline() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    // EIP-2612 states the execution must be allowed in case deadline is equal to block.timestamp
    uint256 deadline = block.timestamp;
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - sellFee;

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, sellFee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    assertTrue(gsmSignerAddr != ALICE, 'Signer is the same as Alice');

    // Buy assets as another user
    mintGho(gsmSignerAddr, DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.prank(gsmSignerAddr);
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT + buyFee);

    assertEq(GHO_GSM.nonces(gsmSignerAddr), 0, 'Unexpected before gsmSignerAddr nonce');

    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        GHO_GSM.DOMAIN_SEPARATOR(),
        GSM_BUY_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(
          gsmSignerAddr,
          DEFAULT_GSM_USDC_AMOUNT,
          gsmSignerAddr,
          GHO_GSM.nonces(gsmSignerAddr),
          deadline
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(gsmSignerKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    assertTrue(gsmSignerAddr != BOB, 'Signer is the same as Bob');

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit BuyAsset(
      gsmSignerAddr,
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      DEFAULT_GSM_GHO_AMOUNT + buyFee,
      buyFee
    );
    GHO_GSM.buyAssetWithSig(
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      gsmSignerAddr,
      deadline,
      signature
    );

    assertEq(GHO_GSM.nonces(gsmSignerAddr), 1, 'Unexpected final gsmSignerAddr nonce');
    assertEq(
      USDC_TOKEN.balanceOf(gsmSignerAddr),
      DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected final USDC balance'
    );
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoOut, 'Unexpected final GHO balance');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + sellFee + buyFee,
      'Unexpected GSM GHO balance'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  // TODO
  function testBuyThenSellAtMaximumBucketCapacity() public {
    // Use zero fees to simplify amount calculations
    vm.expectEmit(true, true, false, true, address(GHO_GSM));
    emit FeeStrategyUpdated(address(GHO_GSM_FIXED_FEE_STRATEGY), address(0));
    GHO_GSM.updateFeeStrategy(address(0));

    uint256 currentExposure = GHO_GSM.getAvailableUnderlyingExposure();

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_EXPOSURE - currentExposure);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_EXPOSURE - currentExposure);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(
      ALICE,
      ALICE,
      DEFAULT_GSM_USDC_EXPOSURE - currentExposure,
      7999995994919000000000000,
      0
    );
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_EXPOSURE - currentExposure, ALICE);

    (uint256 ghoCapacity, uint256 ghoLevel) = GHO_TOKEN.getFacilitatorBucket(address(GHO_GSM));
    assertEq(ghoLevel, ghoCapacity, 'Unexpected GHO bucket level after initial sell');
    assertEq(
      GHO_TOKEN.balanceOf(ALICE),
      DEFAULT_CAPACITY,
      'Unexpected Alice GHO balance after sell'
    );

    // Buy 1 of the underlying
    GHO_TOKEN.approve(address(GHO_GSM), 1e18);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit BuyAsset(ALICE, ALICE, 1e6, 1e18, 0);
    GHO_GSM.buyAsset(1e6, ALICE);

    (, ghoLevel) = GHO_TOKEN.getFacilitatorBucket(address(GHO_GSM));
    assertEq(ghoLevel, DEFAULT_CAPACITY - 1e18, 'Unexpected GHO bucket level after buy');
    assertEq(
      GHO_TOKEN.balanceOf(ALICE),
      DEFAULT_CAPACITY - 1e18,
      'Unexpected Alice GHO balance after buy'
    );
    assertEq(USDC_TOKEN.balanceOf(ALICE), 1e6, 'Unexpected Alice USDC balance after buy');

    // Sell 1 of the underlying
    USDC_TOKEN.approve(address(GHO_GSM), 1e6);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, 1e6, 1e18, 0);
    GHO_GSM.sellAsset(1e6, ALICE);
    vm.stopPrank();

    (ghoCapacity, ghoLevel) = GHO_TOKEN.getFacilitatorBucket(address(GHO_GSM));
    assertEq(ghoLevel, ghoCapacity, 'Unexpected GHO bucket level after second sell');
    assertEq(
      GHO_TOKEN.balanceOf(ALICE),
      DEFAULT_CAPACITY,
      'Unexpected Alice GHO balance after second sell'
    );
    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected Alice USDC balance after second sell');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testRevertBuyAssetWithSigExpiredSignature() public {
    uint256 deadline = block.timestamp - 1;

    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        GHO_GSM.DOMAIN_SEPARATOR(),
        GSM_BUY_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(
          gsmSignerAddr,
          DEFAULT_GSM_USDC_AMOUNT,
          gsmSignerAddr,
          GHO_GSM.nonces(gsmSignerAddr),
          deadline
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(gsmSignerKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    assertTrue(gsmSignerAddr != BOB, 'Signer is the same as Bob');

    vm.prank(BOB);
    vm.expectRevert('SIGNATURE_DEADLINE_EXPIRED');
    GHO_GSM.buyAssetWithSig(
      gsmSignerAddr,
      DEFAULT_GSM_USDC_AMOUNT,
      gsmSignerAddr,
      deadline,
      signature
    );
  }

  function testRevertBuyAssetWithSigInvalidSignature() public {
    uint256 deadline = block.timestamp + 1 hours;

    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        GHO_GSM.DOMAIN_SEPARATOR(),
        GSM_BUY_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(
          gsmSignerAddr,
          DEFAULT_GSM_USDC_AMOUNT,
          gsmSignerAddr,
          GHO_GSM.nonces(gsmSignerAddr),
          deadline
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(gsmSignerKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    assertTrue(gsmSignerAddr != BOB, 'Signer is the same as Bob');

    vm.prank(BOB);
    vm.expectRevert('SIGNATURE_INVALID');
    GHO_GSM.buyAssetWithSig(BOB, DEFAULT_GSM_USDC_AMOUNT, gsmSignerAddr, deadline, signature);
  }

  function testRevertBuyAssetZeroAmount() public {
    vm.prank(ALICE);
    vm.expectRevert('INVALID_AMOUNT');
    GHO_GSM.buyAsset(0, ALICE);
  }

  function testRevertBuyAssetNoGHO() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, sellFee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    vm.startPrank(BOB);
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.expectRevert(stdError.arithmeticError);
    GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
    vm.stopPrank();
  }

  function testRevertBuyAssetNoAllowance() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, sellFee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.startPrank(BOB);
    vm.expectRevert(stdError.arithmeticError);
    GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
    vm.stopPrank();
  }

  function testGetGhoAmountForBuyAsset() public {
    (uint256 exactAssetAmount, uint256 ghoSold, uint256 grossAmount, uint256 fee) = GHO_GSM
      .getGhoAmountForBuyAsset(DEFAULT_GSM_USDC_AMOUNT);

    uint256 topUpAmount = 1_000_000e18;
    mintGho(ALICE, topUpAmount);

    _sellAsset(GHO_GSM, USDC_TOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(ALICE);
    uint256 ghoFeesBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    vm.startPrank(ALICE);
    GHO_TOKEN.approve(address(GHO_GSM), type(uint256).max);
    GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    assertEq(DEFAULT_GSM_USDC_AMOUNT, exactAssetAmount, 'Unexpected asset amount bought');
    assertEq(ghoSold - fee, grossAmount, 'Unexpected GHO gross sold amount');
    assertEq(ghoBalanceBefore - GHO_TOKEN.balanceOf(ALICE), ghoSold, 'Unexpected GHO sold amount');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)) - ghoFeesBefore,
      fee,
      'Unexpected GHO fee amount'
    );

    (uint256 assetAmount, uint256 exactGhoSold, uint256 grossAmount2, uint256 fee2) = GHO_GSM
      .getAssetAmountForBuyAsset(ghoSold);
    assertEq(
      ghoBalanceBefore - GHO_TOKEN.balanceOf(ALICE),
      exactGhoSold,
      'Unexpected GHO sold exact amount'
    );
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected estimation of bought assets');
    assertEq(grossAmount, grossAmount2, 'Unexpected GHO gross amount');
    assertEq(fee, fee2, 'Unexpected GHO fee amount');
  }

  function testGetGhoAmountForBuyAssetWithZeroFee() public {
    GHO_GSM.updateFeeStrategy(address(0));

    (uint256 exactAssetAmount, uint256 ghoSold, uint256 grossAmount, uint256 fee) = GHO_GSM
      .getGhoAmountForBuyAsset(DEFAULT_GSM_USDC_AMOUNT);
    assertEq(fee, 0, 'Unexpected GHO fee amount');

    uint256 topUpAmount = 1_000_000e18;
    mintGho(ALICE, topUpAmount);

    _sellAsset(GHO_GSM, USDC_TOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(ALICE);
    uint256 ghoFeesBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));

    vm.startPrank(ALICE);
    GHO_TOKEN.approve(address(GHO_GSM), type(uint256).max);
    GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    assertEq(DEFAULT_GSM_USDC_AMOUNT, exactAssetAmount, 'Unexpected asset amount bought');
    assertEq(ghoSold, grossAmount, 'Unexpected GHO gross sold amount');
    assertEq(ghoBalanceBefore - GHO_TOKEN.balanceOf(ALICE), ghoSold, 'Unexpected GHO sold amount');
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), ghoFeesBefore, 'Unexpected GHO fee amount');

    (uint256 assetAmount, uint256 exactGhoSold, uint256 grossAmount2, uint256 fee2) = GHO_GSM
      .getAssetAmountForBuyAsset(ghoSold);
    assertEq(
      ghoBalanceBefore - GHO_TOKEN.balanceOf(ALICE),
      exactGhoSold,
      'Unexpected GHO sold exact amount'
    );
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected estimation of bought assets');
    assertEq(grossAmount, grossAmount2, 'Unexpected GHO gross amount');
    assertEq(fee, fee2, 'Unexpected GHO fee amount');
  }

  function testGetGhoAmountForBuyAssetWithZeroAmount() public {
    (uint256 exactAssetAmount, uint256 ghoSold, uint256 grossAmount, uint256 fee) = GHO_GSM
      .getGhoAmountForBuyAsset(0);
    assertEq(exactAssetAmount, 0, 'Unexpected exact asset amount');
    assertEq(ghoSold, 0, 'Unexpected GHO sold amount');
    assertEq(grossAmount, 0, 'Unexpected GHO gross amount');
    assertEq(fee, 0, 'Unexpected GHO fee amount');

    (uint256 assetAmount, uint256 exactGhoSold, uint256 grossAmount2, uint256 fee2) = GHO_GSM
      .getAssetAmountForBuyAsset(ghoSold);
    assertEq(exactGhoSold, 0, 'Unexpected exact gho bought');
    assertEq(assetAmount, 0, 'Unexpected estimation of bought assets');
    assertEq(grossAmount, grossAmount2, 'Unexpected GHO gross amount');
    assertEq(fee, fee2, 'Unexpected GHO fee amount');
  }

  function testSwapFreeze() public {
    assertEq(GHO_GSM.getIsFrozen(), false, 'Unexpected freeze status before');
    vm.prank(address(GHO_GSM_SWAP_FREEZER));
    vm.expectEmit(true, false, false, true, address(GHO_GSM));
    emit SwapFreeze(address(GHO_GSM_SWAP_FREEZER), true);
    GHO_GSM.setSwapFreeze(true);
    assertEq(GHO_GSM.getIsFrozen(), true, 'Unexpected freeze status after');
  }

  function testRevertFreezeNotAuthorized() public {
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(GSM_SWAP_FREEZER_ROLE, ALICE));
    vm.prank(ALICE);
    GHO_GSM.setSwapFreeze(true);
  }

  function testRevertSwapFreezeAlreadyFrozen() public {
    vm.startPrank(address(GHO_GSM_SWAP_FREEZER));
    GHO_GSM.setSwapFreeze(true);
    vm.expectRevert('GSM_ALREADY_FROZEN');
    GHO_GSM.setSwapFreeze(true);
    vm.stopPrank();
  }

  function testSwapUnfreeze() public {
    vm.startPrank(address(GHO_GSM_SWAP_FREEZER));
    GHO_GSM.setSwapFreeze(true);
    vm.expectEmit(true, false, false, true, address(GHO_GSM));
    emit SwapFreeze(address(GHO_GSM_SWAP_FREEZER), false);
    GHO_GSM.setSwapFreeze(false);
    vm.stopPrank();
  }

  function testRevertUnfreezeNotAuthorized() public {
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(GSM_SWAP_FREEZER_ROLE, ALICE));
    vm.prank(ALICE);
    GHO_GSM.setSwapFreeze(false);
  }

  function testRevertUnfreezeNotFrozen() public {
    vm.prank(address(GHO_GSM_SWAP_FREEZER));
    vm.expectRevert('GSM_ALREADY_UNFROZEN');
    GHO_GSM.setSwapFreeze(false);
  }

  function testRevertBuyAndSellWhenSwapFrozen() public {
    vm.prank(address(GHO_GSM_SWAP_FREEZER));
    GHO_GSM.setSwapFreeze(true);
    vm.expectRevert('GSM_FROZEN');
    GHO_GSM.buyAsset(0, ALICE);
    vm.expectRevert('GSM_FROZEN');
    GHO_GSM.sellAsset(0, ALICE);
  }

  function testUpdateConfigurator() public {
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit RoleGranted(GSM_CONFIGURATOR_ROLE, ALICE, address(this));
    GHO_GSM.grantRole(GSM_CONFIGURATOR_ROLE, ALICE);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit RoleRevoked(GSM_CONFIGURATOR_ROLE, address(this), address(this));
    GHO_GSM.revokeRole(GSM_CONFIGURATOR_ROLE, address(this));
  }

  function testRevertUpdateConfiguratorNotAuthorized() public {
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(DEFAULT_ADMIN_ROLE, ALICE));
    vm.prank(ALICE);
    GHO_GSM.grantRole(GSM_CONFIGURATOR_ROLE, ALICE);
  }

  function testConfiguratorUpdateMethods() public {
    // Alice as configurator
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit RoleGranted(GSM_CONFIGURATOR_ROLE, ALICE, address(this));
    GHO_GSM.grantRole(GSM_CONFIGURATOR_ROLE, ALICE);

    vm.startPrank(address(ALICE));

    assertEq(
      GHO_GSM.getFeeStrategy(),
      address(GHO_GSM_FIXED_FEE_STRATEGY),
      'Unexpected fee strategy'
    );
    FixedFeeStrategy newFeeStrategy = new FixedFeeStrategy(
      DEFAULT_GSM_BUY_FEE,
      DEFAULT_GSM_SELL_FEE
    );

    vm.expectEmit(true, true, false, true, address(GHO_GSM));
    emit FeeStrategyUpdated(address(GHO_GSM_FIXED_FEE_STRATEGY), address(newFeeStrategy));
    GHO_GSM.updateFeeStrategy(address(newFeeStrategy));
    assertEq(GHO_GSM.getFeeStrategy(), address(newFeeStrategy), 'Unexpected fee strategy');

    address newGhoTreasury = address(GHO_GSM);
    vm.expectEmit(true, true, true, true, address(newGhoTreasury));
    emit GhoTreasuryUpdated(TREASURY, newGhoTreasury);
    GHO_GSM.updateGhoTreasury(newGhoTreasury);
    assertEq(GHO_GSM.getGhoTreasury(), newGhoTreasury);

    vm.expectEmit(true, true, false, true, address(GHO_GSM));
    emit ExposureCapUpdated(DEFAULT_GSM_USDC_EXPOSURE, 0);
    GHO_GSM.updateExposureCap(0);
    assertEq(GHO_GSM.getExposureCap(), 0, 'Unexpected exposure capacity');

    vm.expectEmit(true, true, false, true, address(GHO_GSM));
    emit ExposureCapUpdated(0, 1000);
    GHO_GSM.updateExposureCap(1000);
    assertEq(GHO_GSM.getExposureCap(), 1000, 'Unexpected exposure capacity');

    vm.stopPrank();
  }

  function testRevertConfiguratorUpdateMethodsNotAuthorized() public {
    vm.startPrank(ALICE);
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(DEFAULT_ADMIN_ROLE, ALICE));
    GHO_GSM.grantRole(GSM_LIQUIDATOR_ROLE, ALICE);
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(DEFAULT_ADMIN_ROLE, ALICE));
    GHO_GSM.grantRole(GSM_SWAP_FREEZER_ROLE, ALICE);
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(GSM_CONFIGURATOR_ROLE, ALICE));
    GHO_GSM.updateExposureCap(0);
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(GSM_CONFIGURATOR_ROLE, ALICE));
    GHO_GSM.updateGhoTreasury(ALICE);
    vm.stopPrank();
  }

  function testRevertInitializeTreasuryZeroAddress() public {
    GsmV2 gsm = new GsmV2(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    vm.expectRevert(bytes('ZERO_ADDRESS_NOT_VALID'));
    gsm.initialize(address(this), address(0), DEFAULT_GSM_USDC_EXPOSURE);
  }

  function testUpdateGhoTreasuryRevertIfZero() public {
    vm.expectRevert(bytes('ZERO_ADDRESS_NOT_VALID'));
    GHO_GSM.updateGhoTreasury(address(0));
  }

  function testUpdateGhoTreasury() public {
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit GhoTreasuryUpdated(TREASURY, ALICE);
    GHO_GSM.updateGhoTreasury(ALICE);

    assertEq(GHO_GSM.getGhoTreasury(), ALICE);
  }

  function testUnauthorizedUpdateGhoTreasuryRevert() public {
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(GSM_CONFIGURATOR_ROLE, ALICE));
    vm.prank(ALICE);
    GHO_GSM.updateGhoTreasury(ALICE);
  }

  function testRescueTokens() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    mintWeth(address(GHO_GSM), 100e18);
    assertEq(WETH.balanceOf(address(GHO_GSM)), 100e18, 'Unexpected GSM WETH before balance');
    assertEq(WETH.balanceOf(ALICE), 0, 'Unexpected target WETH before balance');
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(address(WETH), ALICE, 100e18);
    GHO_GSM.rescueTokens(address(WETH), ALICE, 100e18);
    assertEq(WETH.balanceOf(address(GHO_GSM)), 0, 'Unexpected GSM WETH after balance');
    assertEq(WETH.balanceOf(ALICE), 100e18, 'Unexpected target WETH after balance');
  }

  function testRevertRescueTokensZeroAmount() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));
    vm.expectRevert('INVALID_AMOUNT');
    GHO_GSM.rescueTokens(address(WETH), ALICE, 0);
  }

  function testRescueGhoTokens() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));
    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));
    mintGho(address(GHO_GSM), 100e18);
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + 100e18,
      'Unexpected GSM GHO before balance'
    );
    assertEq(GHO_TOKEN.balanceOf(ALICE), 0, 'Unexpected target GHO before balance');
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(address(GHO_TOKEN), ALICE, 100e18);
    GHO_GSM.rescueTokens(address(GHO_TOKEN), ALICE, 100e18);
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore,
      'Unexpected GSM GHO after balance'
    );
    assertEq(GHO_TOKEN.balanceOf(ALICE), 100e18, 'Unexpected target GHO after balance');
  }

  function testRescueGhoTokensWithAccruedFees() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    uint256 ghoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    assertGt(fee, 0, 'Fee not greater than zero');

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, fee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + fee,
      'Unexpected GSM GHO balance'
    );

    mintGho(address(GHO_GSM), 1);
    assertEq(GHO_TOKEN.balanceOf(BOB), 0, 'Unexpected target GHO balance before');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + fee + 1,
      'Unexpected GSM GHO balance before'
    );

    vm.expectRevert('INSUFFICIENT_GHO_TO_RESCUE');
    GHO_GSM.rescueTokens(address(GHO_TOKEN), BOB, fee);

    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(address(GHO_TOKEN), BOB, 1);
    GHO_GSM.rescueTokens(address(GHO_TOKEN), BOB, 1);

    assertEq(GHO_TOKEN.balanceOf(BOB), 1, 'Unexpected target GHO balance after');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      ghoBalanceBefore + fee,
      'Unexpected GSM GHO balance after'
    );
  }

  function testRevertRescueGhoTokens() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    vm.expectRevert('INSUFFICIENT_GHO_TO_RESCUE');
    GHO_GSM.rescueTokens(address(GHO_TOKEN), ALICE, 1);
  }

  function testRescueUnderlyingTokens() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    mintUsdc(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);

    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected USDC balance before');
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(address(USDC_TOKEN), ALICE, DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.rescueTokens(address(USDC_TOKEN), ALICE, DEFAULT_GSM_USDC_AMOUNT);
    assertEq(USDC_TOKEN.balanceOf(ALICE), DEFAULT_GSM_USDC_AMOUNT, 'Unexpected USDC balance after');
  }

  function testRescueUnderlyingTokensWithAccruedFees() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    uint256 balanceBeforeSell = USDC_TOKEN.balanceOf(address(GHO_GSM));

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    uint256 currentGSMBalance = DEFAULT_GSM_USDC_AMOUNT + balanceBeforeSell;
    assertApproxEqAbs(IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM)), currentGSMBalance, 1);

    mintUsdc(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    assertEq(
      USDC_TOKEN.balanceOf(address(GHO_GSM)),
      DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected GSM USDC balance before, post-mint'
    );
    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected target USDC balance before');

    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(address(USDC_TOKEN), ALICE, DEFAULT_GSM_USDC_AMOUNT - 1);
    GHO_GSM.rescueTokens(address(USDC_TOKEN), ALICE, DEFAULT_GSM_USDC_AMOUNT - 1);
    assertApproxEqAbs(IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM)), currentGSMBalance, 1);
    assertEq(
      USDC_TOKEN.balanceOf(ALICE),
      DEFAULT_GSM_USDC_AMOUNT - 1,
      'Unexpected target USDC balance after'
    );
  }

  function testRevertRescueUnderlyingTokens() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    vm.expectRevert('INSUFFICIENT_EXOGENOUS_ASSET_TO_RESCUE');
    GHO_GSM.rescueTokens(address(USDC_TOKEN), ALICE, 1);
  }

  function testSeize() public {
    assertEq(GHO_GSM.getIsSeized(), false, 'Unexpected seize status before');

    uint256 usdcBalanceBefore = USDC_TOKEN.balanceOf(TREASURY);
    uint256 ausdcBalanceBefore = IERC20(USDC_ATOKEN).balanceOf(TREASURY);

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    uint256 gsmAusdcBalanceBefore = IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM));

    assertEq(
      USDC_TOKEN.balanceOf(TREASURY),
      usdcBalanceBefore,
      'Unexpected USDC before token balance'
    );

    (, uint256 ghoMinted) = GHO_TOKEN.getFacilitatorBucket(address(GHO_GSM));

    vm.expectEmit(true, false, false, true, address(GHO_GSM));
    emit Seized(
      address(GHO_GSM_LAST_RESORT_LIQUIDATOR),
      TREASURY,
      IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM)),
      ghoMinted
    );
    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    uint256 seizedAmount = GHO_GSM.seize();

    assertEq(GHO_GSM.getIsSeized(), true, 'Unexpected seize status after');
    assertEq(seizedAmount, gsmAusdcBalanceBefore, 'Unexpected seized amount');
    assertApproxEqAbs(
      IERC20(USDC_ATOKEN).balanceOf(TREASURY),
      gsmAusdcBalanceBefore + ausdcBalanceBefore,
      1
    );
    assertEq(GHO_GSM.getAvailableLiquidity(), 0, 'Unexpected available liquidity');
    assertEq(
      GHO_GSM.getAvailableUnderlyingExposure(),
      0,
      'Unexpected underlying exposure available'
    );
    assertEq(GHO_GSM.getExposureCap(), 0, 'Unexpected exposure capacity');
  }

  function testRevertSeizeWithoutAuthorization() public {
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(GSM_LIQUIDATOR_ROLE, address(this)));
    GHO_GSM.seize();
  }

  function testRevertMethodsAfterSeizure() public {
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    uint256 usdcBalanceBefore = USDC_TOKEN.balanceOf(address(GHO_GSM));

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    uint256 seizedAmount = GHO_GSM.seize();
    assertApproxEqAbs(seizedAmount, usdcBalanceBefore + DEFAULT_GSM_USDC_AMOUNT, 1);

    vm.expectRevert('GSM_SEIZED');
    GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.expectRevert('GSM_SEIZED');
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.expectRevert('GSM_SEIZED');
    GHO_GSM.seize();
  }

  function testBurnAfterSeize() public {
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    uint256 usdcBalanceBefore = USDC_TOKEN.balanceOf(address(GHO_GSM));
    (, uint256 ghoMintedBefore) = GHO_TOKEN.getFacilitatorBucket(address(GHO_GSM));

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    uint256 seizedAmount = GHO_GSM.seize();
    assertApproxEqAbs(seizedAmount, usdcBalanceBefore + DEFAULT_GSM_USDC_AMOUNT, 1);

    vm.expectRevert('FACILITATOR_BUCKET_LEVEL_NOT_ZERO');
    GHO_TOKEN.removeFacilitator(address(GHO_GSM));

    mintGho(address(GHO_GSM_LAST_RESORT_LIQUIDATOR), ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT);
    vm.startPrank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    GHO_TOKEN.approve(address(GHO_GSM), ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT);
    vm.expectEmit(true, false, false, true, address(GHO_GSM));
    emit BurnAfterSeize(
      address(GHO_GSM_LAST_RESORT_LIQUIDATOR),
      ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT,
      0
    );
    uint256 burnedAmount = GHO_GSM.burnAfterSeize(ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT);
    vm.stopPrank();

    assertEq(
      burnedAmount,
      ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT,
      'Unexpected burned amount of GHO'
    );

    vm.expectEmit(true, false, false, true, address(GHO_TOKEN));
    emit FacilitatorRemoved(address(GHO_GSM));
    GHO_TOKEN.removeFacilitator(address(GHO_GSM));
  }

  function testBurnAfterSeizeGreaterAmount() public {
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    uint256 usdcBalanceBefore = USDC_TOKEN.balanceOf(address(GHO_GSM));
    (, uint256 ghoMintedBefore) = GHO_TOKEN.getFacilitatorBucket(address(GHO_GSM));

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    uint256 seizedAmount = GHO_GSM.seize();
    assertApproxEqAbs(seizedAmount, usdcBalanceBefore + DEFAULT_GSM_USDC_AMOUNT, 1);

    mintGho(address(GHO_GSM_LAST_RESORT_LIQUIDATOR), ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT + 1);
    vm.startPrank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    GHO_TOKEN.approve(address(GHO_GSM), ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT + 1);
    vm.expectEmit(true, false, false, true, address(GHO_GSM));
    emit BurnAfterSeize(
      address(GHO_GSM_LAST_RESORT_LIQUIDATOR),
      ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT,
      0
    );
    uint256 burnedAmount = GHO_GSM.burnAfterSeize(ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT + 1);
    vm.stopPrank();
    assertEq(
      burnedAmount,
      ghoMintedBefore + DEFAULT_GSM_GHO_AMOUNT,
      'Unexpected burned amount of GHO'
    );
  }

  function testRevertBurnAfterSeizeNotSeized() public {
    vm.expectRevert('GSM_NOT_SEIZED');
    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    GHO_GSM.burnAfterSeize(1);
  }

  function testRevertBurnAfterInvalidAmount() public {
    vm.startPrank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    GHO_GSM.seize();
    vm.expectRevert('INVALID_AMOUNT');
    GHO_GSM.burnAfterSeize(0);
    vm.stopPrank();
  }

  function testRevertBurnAfterSeizeUnauthorized() public {
    vm.expectRevert(AccessControlErrorsLib.MISSING_ROLE(GSM_LIQUIDATOR_ROLE, address(this)));
    GHO_GSM.burnAfterSeize(1);
  }

  function testDistributeFeesToTreasury() public {
    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);

    uint256 gsmGhoBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));
    uint256 ghoFeeBefore = GHO_GSM.getAccruedFees();

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, fee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      gsmGhoBalanceBefore + fee,
      'Unexpected GSM GHO balance'
    );
    assertEq(GHO_GSM.getAccruedFees(), ghoFeeBefore + fee, 'Unexpected GSM accrued fees');

    uint256 treasuryGhoBalanceBefore = GHO_TOKEN.balanceOf(TREASURY);

    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit FeesDistributedToTreasury(
      TREASURY,
      address(GHO_TOKEN),
      GHO_TOKEN.balanceOf(address(GHO_GSM))
    );
    GHO_GSM.distributeFeesToTreasury();
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      0,
      'Unexpected GSM GHO balance post-distribution'
    );
    assertEq(
      GHO_TOKEN.balanceOf(TREASURY),
      treasuryGhoBalanceBefore + ghoFeeBefore + fee,
      'Unexpected GHO balance in treasury'
    );
    assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');
  }

  function testDistributeYieldToTreasuryDoNothing() public {
    GHO_GSM.distributeFeesToTreasury();
    uint256 gsmBalanceBefore = GHO_TOKEN.balanceOf(address(GHO_GSM));
    uint256 treasuryBalanceBefore = GHO_TOKEN.balanceOf(address(TREASURY));
    assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');

    vm.record();
    GHO_GSM.distributeFeesToTreasury();
    (, bytes32[] memory writes) = vm.accesses(address(GHO_GSM));
    assertEq(writes.length, 0, 'Unexpected update of accrued fees');

    assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');
    assertEq(
      GHO_TOKEN.balanceOf(address(GHO_GSM)),
      gsmBalanceBefore,
      'Unexpected GSM GHO balance post-distribution'
    );
    assertEq(
      GHO_TOKEN.balanceOf(TREASURY),
      treasuryBalanceBefore,
      'Unexpected GHO balance in treasury'
    );
  }

  function testGetAccruedFees() public {
    GHO_GSM.distributeFeesToTreasury();
    assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');

    FixedFeeStrategy newFeeStrat = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);
    GHO_GSM.updateFeeStrategy(address(newFeeStrat));
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);

    _sellAsset(GHO_GSM, USDC_TOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);

    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), sellFee, 'Unexpected GSM GHO balance');
    assertEq(GHO_GSM.getAccruedFees(), sellFee, 'Unexpected GSM accrued fees');

    mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.startPrank(BOB);
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT + buyFee);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit BuyAsset(BOB, BOB, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT + buyFee, buyFee);
    GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
    vm.stopPrank();

    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), sellFee + buyFee, 'Unexpected GSM GHO balance');
    assertEq(GHO_GSM.getAccruedFees(), sellFee + buyFee, 'Unexpected GSM accrued fees');
  }

  function testGetAccruedFeesWithZeroFee() public {
    GHO_GSM.distributeFeesToTreasury();
    vm.expectEmit(true, true, false, true, address(GHO_GSM));
    emit FeeStrategyUpdated(address(GHO_GSM_FIXED_FEE_STRATEGY), address(0));
    GHO_GSM.updateFeeStrategy(address(0));

    assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');

    for (uint256 i = 0; i < 10; i++) {
      _sellAsset(GHO_GSM, USDC_TOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);
      assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');

      mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT);
      vm.startPrank(BOB);
      GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT);
      GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
      vm.stopPrank();

      assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');
    }
  }

  function testCanSwap() public {
    assertEq(GHO_GSM.canSwap(), true, 'Unexpected initial swap state');

    // Freeze the GSM
    vm.startPrank(address(GHO_GSM_SWAP_FREEZER));
    GHO_GSM.setSwapFreeze(true);
    assertEq(GHO_GSM.canSwap(), false, 'Unexpected swap state post-freeze');

    // Unfreeze the GSM
    GHO_GSM.setSwapFreeze(false);
    assertEq(GHO_GSM.canSwap(), true, 'Unexpected swap state post-unfreeze');
    vm.stopPrank();

    // Seize the GSM
    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    GHO_GSM.seize();
    assertEq(GHO_GSM.canSwap(), false, 'Unexpected swap state post-seize');
  }

  function testUpdateExposureCapBelowCurrentExposure() public {
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure cap');

    mintUsdc(ALICE, 2 * DEFAULT_GSM_USDC_AMOUNT);

    uint256 exposureBefore = GHO_GSM.getAvailableUnderlyingExposure();

    // Alice as configurator
    GHO_GSM.grantRole(GSM_CONFIGURATOR_ROLE, ALICE);
    vm.startPrank(address(ALICE));

    GHO_GSM.updateFeeStrategy(address(0));

    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);

    assertEq(
      GHO_GSM.getAvailableUnderlyingExposure(),
      exposureBefore - DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected available underlying exposure'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure cap');

    // Update exposure cap to smaller value than current exposure
    uint256 currentExposure = GHO_GSM.getAvailableLiquidity();
    uint256 newExposureCap = currentExposure - 1;
    GHO_GSM.updateExposureCap(uint128(newExposureCap));
    assertEq(GHO_GSM.getExposureCap(), newExposureCap, 'Unexpected exposure cap');
    assertEq(GHO_GSM.getAvailableLiquidity(), currentExposure, 'Unexpected current exposure');

    // Reducing exposure to 0
    GHO_GSM.updateExposureCap(0);

    // Sell cannot be executed
    vm.expectRevert('EXOGENOUS_ASSET_EXPOSURE_TOO_HIGH');
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);

    // Buy some asset to reduce current exposure
    vm.stopPrank();
    mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT / 2);
    vm.startPrank(BOB);
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT / 2);
    GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT / 2, BOB);

    assertEq(GHO_GSM.getExposureCap(), 0, 'Unexpected exposure capacity');
  }

  function _sellAsset(
    GsmV2 gsm,
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

  function mintUsdc(address to, uint256 amount) internal {
    uint256 currentBalance = USDC_TOKEN.balanceOf(to);
    deal(address(USDC_TOKEN), to, currentBalance + amount);
    // IERC20(USDC_TOKEN).transfer(to, amount);
  }

  function mintGho(address to, uint256 amount) internal {
    uint256 currentBalance = GHO_TOKEN.balanceOf(to);
    deal(address(GHO_TOKEN), to, currentBalance + amount);
  }

  function mintWeth(address to, uint256 amount) internal {
    uint256 currentBalance = WETH.balanceOf(to);
    deal(address(WETH), to, currentBalance + amount);
  }
}
