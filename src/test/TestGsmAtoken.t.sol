// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'forge-std/console2.sol';

import {AccessControlErrorsLib} from './helpers/ErrorsLib.sol';

import {ProxyAdmin} from 'solidity-utils/contracts/transparent-proxy/ProxyAdmin.sol';
import {PercentageMath} from '@aave/core-v3/contracts/protocol/libraries/math/PercentageMath.sol';
import {IERC20} from 'aave-stk-v1-5/src/interfaces/IERC20.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';

import {FixedPriceStrategy} from '../contracts/facilitators/gsm/priceStrategy/FixedPriceStrategy.sol';
import {FixedFeeStrategy} from '../contracts/facilitators/gsm/feeStrategy/FixedFeeStrategy.sol';
import {SampleSwapFreezer} from '../contracts/facilitators/gsm/misc/SampleSwapFreezer.sol';
import {SampleLiquidator} from '../contracts/facilitators/gsm/misc/SampleLiquidator.sol';
import {GsmAtoken} from '../contracts/facilitators/gsm/GsmAtoken.sol';
import {Gsm} from '../contracts/facilitators/gsm/Gsm.sol';
import {GhoToken} from '../contracts/gho/GhoToken.sol';
import {Events} from './helpers/Events.sol';


/// to run this test: forge test --match-path src/test/TestGsmAtoken.t.sol -vv
contract TestGsmAtoken is Test, Events {
  using PercentageMath for uint256;
  using PercentageMath for uint128;

  GsmAtoken internal GHO_GSM;

  address internal gsmSignerAddr;
  uint256 internal gsmSignerKey;

  SampleSwapFreezer internal GHO_GSM_SWAP_FREEZER;
  SampleLiquidator internal GHO_GSM_LAST_RESORT_LIQUIDATOR;
  FixedPriceStrategy internal GHO_GSM_FIXED_PRICE_STRATEGY;
  FixedFeeStrategy internal GHO_GSM_FIXED_FEE_STRATEGY;

  IERC20 internal USDC_TOKEN = IERC20(AaveV3EthereumAssets.USDC_UNDERLYING);
  IERC20 internal WETH = IERC20(AaveV3EthereumAssets.WETH_UNDERLYING);
  GhoToken internal GHO_TOKEN = GhoToken(AaveV3EthereumAssets.GHO_UNDERLYING);
  address internal USDC_ATOKEN = AaveV3EthereumAssets.USDC_A_TOKEN;
  address internal POOL = address(AaveV3Ethereum.POOL);
  address internal TREASURY = address(AaveV3Ethereum.COLLECTOR);

  /// taken from Constants.sol
  bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
  bytes32 internal constant GHO_TOKEN_BUCKET_MANAGER_ROLE = keccak256('BUCKET_MANAGER_ROLE');
  bytes32 internal constant GSM_CONFIGURATOR_ROLE = keccak256('CONFIGURATOR_ROLE');
  bytes32 internal constant GSM_TOKEN_RESCUER_ROLE = keccak256('TOKEN_RESCUER_ROLE');
  bytes32 internal constant GSM_SWAP_FREEZER_ROLE = keccak256('SWAP_FREEZER_ROLE');
  bytes32 internal constant GSM_LIQUIDATOR_ROLE = keccak256('LIQUIDATOR_ROLE');
  bytes32 internal constant GHO_TOKEN_FACILITATOR_MANAGER_ROLE =
    keccak256('FACILITATOR_MANAGER_ROLE');
  uint256 internal constant DEFAULT_FIXED_PRICE = 1e18;
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

    vm.startPrank(address(GovernanceV3Ethereum.EXECUTOR_LVL_1));
    GHO_TOKEN.grantRole(GHO_TOKEN_FACILITATOR_MANAGER_ROLE, address(this));
    GHO_TOKEN.grantRole(GHO_TOKEN_BUCKET_MANAGER_ROLE, address(this));
    vm.stopPrank();

    GHO_GSM_SWAP_FREEZER = new SampleSwapFreezer();
    GHO_GSM_LAST_RESORT_LIQUIDATOR = new SampleLiquidator();
    GHO_GSM_FIXED_PRICE_STRATEGY = new FixedPriceStrategy(
      DEFAULT_FIXED_PRICE,
      address(USDC_TOKEN),
      6
    );
    GHO_GSM_FIXED_FEE_STRATEGY = new FixedFeeStrategy(DEFAULT_GSM_BUY_FEE, DEFAULT_GSM_SELL_FEE);

    GsmAtoken gsm = new GsmAtoken(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );

    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE);
    gsm.grantRole(GSM_SWAP_FREEZER_ROLE, address(GHO_GSM_SWAP_FREEZER));
    gsm.grantRole(GSM_LIQUIDATOR_ROLE, address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    gsm.updateFeeStrategy(address(GHO_GSM_FIXED_FEE_STRATEGY));
    GHO_GSM = gsm;

    GHO_TOKEN.addFacilitator(address(gsm), 'GSM Facilitator', DEFAULT_CAPACITY);
  }

  /// If multiple exchanges occur on the Gsm on the same block, while no yield has been accrued
  /// by the aToken, rounding errors emerging from the aToken will lead to the Gsm being unbacked
  /// by some wei. If we donate 1 unit of the underlying (the atoken), we prevent this issue from happening
  /// on same block as this Gsm is deployed. This single unit + the atoken yield will allow the Gsm to round
  /// in favor of the user while still mainting full backing.
  function test_WithDonationBacked() public {
    assertEq(USDC_TOKEN.balanceOf(address(GHO_GSM)), 0);

    GHO_GSM.updateFeeStrategy(address(0));

    /// comment the line below to showcase the issues above
    simulateAusdcYield(1e6);

    for (uint256 i = 0; i < 20; i++) {
      // Sell some assets
      _sellAsset(GHO_GSM, USDC_TOKEN, address(0xb0b), DEFAULT_GSM_USDC_AMOUNT+1000e6);

      // Buy some assets
      mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT);
      vm.startPrank(BOB);
      GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT);
      GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
      vm.stopPrank();

      // Sell some assets
      _sellAsset(GHO_GSM, USDC_TOKEN, address(0xb0b), DEFAULT_GSM_USDC_AMOUNT);

      // Sell some assets
      _sellAsset(GHO_GSM, USDC_TOKEN, address(0xb0b), DEFAULT_GSM_USDC_AMOUNT);

      // Buy some assets
      mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT);
      vm.startPrank(BOB);
      GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT);
      GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
      vm.stopPrank();

      // Buy some assets
      mintGho(BOB, DEFAULT_GSM_GHO_AMOUNT);
      vm.startPrank(BOB);
      GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT);
      GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, BOB);
      vm.stopPrank();

      // Sell some assets
      _sellAsset(GHO_GSM, USDC_TOKEN, address(0xb0b), DEFAULT_GSM_USDC_AMOUNT);
      assertGe(IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM)), GHO_GSM.getAvailableLiquidity());
    }

    uint256 maxUsdcAmount = GHO_GSM.getAvailableLiquidity();
    uint256 maxGhoAmount = GHO_GSM_FIXED_PRICE_STRATEGY.getAssetPriceInGho(maxUsdcAmount, true);

    mintGho(BOB, maxGhoAmount);
    vm.startPrank(BOB);
    GHO_TOKEN.approve(address(GHO_GSM), maxGhoAmount);
    GHO_GSM.buyAsset(maxUsdcAmount, BOB);
    vm.stopPrank();

    assertGe(IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM)), GHO_GSM.getAvailableLiquidity());
  }

  function testConstructor() public {
    GsmAtoken gsm = new GsmAtoken(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    assertEq(gsm.POOL(), POOL, 'Unexpected POOL address');
    assertEq(gsm.UNDERLYING_ATOKEN(), USDC_ATOKEN, 'Unexpected aToken address');
  }

  function testRevertConstructorZeroAddressParams() public {
    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmAtoken(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      address(0),
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );

    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmAtoken(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      address(0),
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
  }

  function testInitialize() public {
    GsmAtoken gsm = new GsmAtoken(
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
    assertEq(USDC_TOKEN.allowance(address(gsm), POOL), type(uint256).max);
    assertEq(IERC20(USDC_ATOKEN).allowance(address(gsm), POOL), type(uint256).max);
  }

  function testSellAssetZeroFee() public {
    vm.expectEmit(true, true, false, true, address(GHO_GSM));
    emit FeeStrategyUpdated(address(GHO_GSM_FIXED_FEE_STRATEGY), address(0));
    GHO_GSM.updateFeeStrategy(address(0));

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, 0);
    (uint256 assetAmount, uint256 ghoBought) = GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    assertEq(ghoBought, DEFAULT_GSM_GHO_AMOUNT, 'Unexpected GHO amount bought');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected asset amount sold');
    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected final USDC balance');
    assertEq(GHO_TOKEN.balanceOf(ALICE), DEFAULT_GSM_GHO_AMOUNT, 'Unexpected final GHO balance');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testSellAsset() public {
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - fee;

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
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee, 'Unexpected GSM GHO balance');
    assertEq(
      GHO_GSM.getAvailableUnderlyingExposure(),
      DEFAULT_GSM_USDC_EXPOSURE - DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected available underlying exposure'
    );
    assertEq(
      GHO_GSM.getAvailableLiquidity(),
      DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected available liquidity'
    );
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testSellAssetSendToOther() public {
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - fee;

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
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee, 'Unexpected GSM GHO balance');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testSellAssetWithSig() public {
    uint256 deadline = block.timestamp + 1 hours;
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - fee;

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
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee, 'Unexpected GSM GHO balance');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testSellAssetWithSigExactDeadline() public {
    // EIP-2612 states the execution must be allowed in case deadline is equal to block.timestamp
    uint256 deadline = block.timestamp;
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - fee;

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
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee, 'Unexpected GSM GHO balance');
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
    GsmAtoken gsm = new GsmAtoken(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE);
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
    GsmAtoken gsm = new GsmAtoken(
      address(GHO_TOKEN),
      address(USDC_TOKEN),
      USDC_ATOKEN,
      POOL,
      address(GHO_GSM_FIXED_PRICE_STRATEGY)
    );
    gsm.initialize(address(this), TREASURY, DEFAULT_GSM_USDC_EXPOSURE - 1);
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

    _sellAsset(GHO_GSM, USDC_TOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);

    assertEq(
      DEFAULT_GSM_USDC_AMOUNT - USDC_TOKEN.balanceOf(ALICE),
      exactAssetAmount,
      'Unexpected asset amount sold'
    );
    assertEq(ghoBought + fee, grossAmount, 'Unexpected GHO gross amount');
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoBought, 'Unexpected GHO bought amount');
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee, 'Unexpected GHO fee amount');

    (uint256 assetAmount, uint256 exactGhoBought, uint256 grossAmount2, uint256 fee2) = GHO_GSM
      .getAssetAmountForSellAsset(ghoBought);
    assertEq(GHO_TOKEN.balanceOf(ALICE), exactGhoBought, 'Unexpected GHO bought amount');
    assertEq(assetAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected estimation of sold assets');
    assertEq(grossAmount, grossAmount2, 'Unexpected GHO gross amount');
    assertEq(fee, fee2, 'Unexpected GHO fee amount');
  }

  function testGetGhoAmountForSellAssetWithZeroFee() public {
    GHO_GSM.updateFeeStrategy(address(0));

    (uint256 exactAssetAmount, uint256 ghoBought, uint256 grossAmount, uint256 fee) = GHO_GSM
      .getGhoAmountForSellAsset(DEFAULT_GSM_USDC_AMOUNT);
    assertEq(fee, 0, 'Unexpected GHO fee amount');

    _sellAsset(GHO_GSM, USDC_TOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);

    assertEq(
      DEFAULT_GSM_USDC_AMOUNT - USDC_TOKEN.balanceOf(ALICE),
      exactAssetAmount,
      'Unexpected asset amount sold'
    );
    assertEq(ghoBought, grossAmount, 'Unexpected GHO gross amount');
    assertEq(GHO_TOKEN.balanceOf(ALICE), ghoBought, 'Unexpected GHO bought amount');
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), 0, 'Unexpected GHO fee amount');

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
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - sellFee;

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
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), sellFee + buyFee, 'Unexpected GSM GHO balance');
    assertEq(
      GHO_GSM.getAvailableUnderlyingExposure(),
      DEFAULT_GSM_USDC_EXPOSURE,
      'Unexpected available underlying exposure'
    );
    assertEq(GHO_GSM.getAvailableLiquidity(), 0, 'Unexpected available liquidity');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testBuyAssetSendToOther() public {
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - sellFee;

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
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), sellFee + buyFee, 'Unexpected GSM GHO balance');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testBuyAssetWithSig() public {
    uint256 deadline = block.timestamp + 1 hours;
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - sellFee;

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
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), sellFee + buyFee, 'Unexpected GSM GHO balance');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testBuyAssetWithSigExactDeadline() public {
    // EIP-2612 states the execution must be allowed in case deadline is equal to block.timestamp
    uint256 deadline = block.timestamp;
    uint256 sellFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    uint256 buyFee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_BUY_FEE);
    uint256 ghoOut = DEFAULT_GSM_GHO_AMOUNT - sellFee;

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
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), sellFee + buyFee, 'Unexpected GSM GHO balance');
    assertEq(GHO_GSM.getExposureCap(), DEFAULT_GSM_USDC_EXPOSURE, 'Unexpected exposure capacity');
  }

  function testBuyThenSellAtMaximumBucketCapacity() public {
    // Use zero fees to simplify amount calculations
    vm.expectEmit(true, true, false, true, address(GHO_GSM));
    emit FeeStrategyUpdated(address(GHO_GSM_FIXED_FEE_STRATEGY), address(0));
    GHO_GSM.updateFeeStrategy(address(0));

    // Supply assets to the GSM first
    mintUsdc(ALICE, DEFAULT_GSM_USDC_EXPOSURE);
    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_EXPOSURE);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_EXPOSURE, DEFAULT_CAPACITY, 0);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_EXPOSURE, ALICE);

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
    GsmAtoken gsm = new GsmAtoken(
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

    mintGho(address(GHO_GSM), 100e18);
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), 100e18, 'Unexpected GSM GHO before balance');
    assertEq(GHO_TOKEN.balanceOf(ALICE), 0, 'Unexpected target GHO before balance');
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(address(GHO_TOKEN), ALICE, 100e18);
    GHO_GSM.rescueTokens(address(GHO_TOKEN), ALICE, 100e18);
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), 0, 'Unexpected GSM GHO after balance');
    assertEq(GHO_TOKEN.balanceOf(ALICE), 100e18, 'Unexpected target GHO after balance');
  }

  function testRescueGhoTokensWithAccruedFees() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);
    assertGt(fee, 0, 'Fee not greater than zero');

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, fee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee, 'Unexpected GSM GHO balance');

    mintGho(address(GHO_GSM), 1);
    assertEq(GHO_TOKEN.balanceOf(BOB), 0, 'Unexpected target GHO balance before');
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee + 1, 'Unexpected GSM GHO balance before');

    vm.expectRevert('INSUFFICIENT_GHO_TO_RESCUE');
    GHO_GSM.rescueTokens(address(GHO_TOKEN), BOB, fee);

    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(address(GHO_TOKEN), BOB, 1);
    GHO_GSM.rescueTokens(address(GHO_TOKEN), BOB, 1);

    assertEq(GHO_TOKEN.balanceOf(BOB), 1, 'Unexpected target GHO balance after');
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee, 'Unexpected GSM GHO balance after');
  }

  function testRevertRescueGhoTokens() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    vm.expectRevert('INSUFFICIENT_GHO_TO_RESCUE');
    GHO_GSM.rescueTokens(address(GHO_TOKEN), ALICE, 1);
  }

  function testRescueUnderlyingTokens() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    simulateAusdcYield(DEFAULT_GSM_USDC_AMOUNT);

    assertEq(USDC_TOKEN.balanceOf(ALICE), 0, 'Unexpected USDC balance before');
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(USDC_ATOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.rescueTokens(USDC_ATOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);
    assertEq(IERC20(USDC_ATOKEN).balanceOf(ALICE), DEFAULT_GSM_USDC_AMOUNT, 'Unexpected USDC balance after');
  }

  function testRescueUnderlyingTokensWithAccruedFees() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    uint256 currentGSMBalance = DEFAULT_GSM_USDC_AMOUNT;
    assertEq(
      IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM)),
      currentGSMBalance,
      'Unexpected GSM USDC balance before'
    );

    simulateAusdcYield(DEFAULT_GSM_USDC_AMOUNT);
    assertEq(
      IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM)),
      currentGSMBalance + DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected GSM USDC balance before, post-mint'
    );
    assertEq(IERC20(USDC_ATOKEN).balanceOf(ALICE), 0, 'Unexpected target USDC balance before');

    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit TokensRescued(USDC_ATOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.rescueTokens(USDC_ATOKEN, ALICE, DEFAULT_GSM_USDC_AMOUNT);
    assertEq(
      IERC20(USDC_ATOKEN).balanceOf(address(GHO_GSM)),
      currentGSMBalance,
      'Unexpected GSM USDC balance after'
    );
    assertEq(
      IERC20(USDC_ATOKEN).balanceOf(ALICE),
      DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected target USDC balance after'
    );
  }

  function testRevertRescueUnderlyingTokens() public {
    GHO_GSM.grantRole(GSM_TOKEN_RESCUER_ROLE, address(this));

    vm.expectRevert('INSUFFICIENT_EXOGENOUS_ASSET_TO_RESCUE');
    GHO_GSM.rescueTokens(USDC_ATOKEN, ALICE, 1);
  }

  function testSeize() public {
    assertEq(GHO_GSM.getIsSeized(), false, 'Unexpected seize status before');

    uint256 treasuryBalanceBefore = IERC20(USDC_ATOKEN).balanceOf(TREASURY);

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();
    
    // we use real aave treasury here so this assertion doesnt make sense
    // assertEq(USDC_TOKEN.balanceOf(TREASURY), 0, 'Unexpected USDC before token balance');
    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    vm.expectEmit(true, false, false, true, address(GHO_GSM));
    emit Seized(
      address(GHO_GSM_LAST_RESORT_LIQUIDATOR),
      BOB,
      DEFAULT_GSM_USDC_AMOUNT,
      DEFAULT_GSM_GHO_AMOUNT
    );
    uint256 seizedAmount = GHO_GSM.seize();

    assertEq(GHO_GSM.getIsSeized(), true, 'Unexpected seize status after');
    assertEq(seizedAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected seized amount');
    assertEq(
      IERC20(USDC_ATOKEN).balanceOf(TREASURY),
      treasuryBalanceBefore + DEFAULT_GSM_USDC_AMOUNT,
      'Unexpected USDC after token balance'
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

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    uint256 seizedAmount = GHO_GSM.seize();
    assertEq(seizedAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected seized amount');

    vm.expectRevert('GSM_SEIZED');
    GHO_GSM.buyAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.expectRevert('GSM_SEIZED');
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.expectRevert('GSM_SEIZED');
    GHO_GSM.seize();
  }

  function testBurnAfterSeize() public {
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    uint256 seizedAmount = GHO_GSM.seize();
    assertEq(seizedAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected seized amount');

    vm.expectRevert('FACILITATOR_BUCKET_LEVEL_NOT_ZERO');
    GHO_TOKEN.removeFacilitator(address(GHO_GSM));

    mintGho(address(GHO_GSM_LAST_RESORT_LIQUIDATOR), DEFAULT_GSM_GHO_AMOUNT);
    vm.startPrank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT);
    vm.expectEmit(true, false, false, true, address(GHO_GSM));
    emit BurnAfterSeize(address(GHO_GSM_LAST_RESORT_LIQUIDATOR), DEFAULT_GSM_GHO_AMOUNT, 0);
    uint256 burnedAmount = GHO_GSM.burnAfterSeize(DEFAULT_GSM_GHO_AMOUNT);
    vm.stopPrank();
    assertEq(burnedAmount, DEFAULT_GSM_GHO_AMOUNT, 'Unexpected burned amount of GHO');

    vm.expectEmit(true, false, false, true, address(GHO_TOKEN));
    emit FacilitatorRemoved(address(GHO_GSM));
    GHO_TOKEN.removeFacilitator(address(GHO_GSM));
  }

  function testBurnAfterSeizeGreaterAmount() public {
    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();

    vm.prank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    uint256 seizedAmount = GHO_GSM.seize();
    assertEq(seizedAmount, DEFAULT_GSM_USDC_AMOUNT, 'Unexpected seized amount');

    mintGho(address(GHO_GSM_LAST_RESORT_LIQUIDATOR), DEFAULT_GSM_GHO_AMOUNT + 1);
    vm.startPrank(address(GHO_GSM_LAST_RESORT_LIQUIDATOR));
    GHO_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_GHO_AMOUNT + 1);
    vm.expectEmit(true, false, false, true, address(GHO_GSM));
    emit BurnAfterSeize(address(GHO_GSM_LAST_RESORT_LIQUIDATOR), DEFAULT_GSM_GHO_AMOUNT, 0);
    uint256 burnedAmount = GHO_GSM.burnAfterSeize(DEFAULT_GSM_GHO_AMOUNT + 1);
    vm.stopPrank();
    assertEq(burnedAmount, DEFAULT_GSM_GHO_AMOUNT, 'Unexpected burned amount of GHO');
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
    uint256 fee = DEFAULT_GSM_GHO_AMOUNT.percentMul(DEFAULT_GSM_SELL_FEE);

    uint256 treasuryBalanceBefore = GHO_TOKEN.balanceOf(address(TREASURY));

    mintUsdc(ALICE, DEFAULT_GSM_USDC_AMOUNT);

    vm.startPrank(ALICE);
    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    vm.expectEmit(true, true, true, true, address(GHO_GSM));
    emit SellAsset(ALICE, ALICE, DEFAULT_GSM_USDC_AMOUNT, DEFAULT_GSM_GHO_AMOUNT, fee);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);
    vm.stopPrank();
    assertEq(GHO_TOKEN.balanceOf(address(GHO_GSM)), fee, 'Unexpected GSM GHO balance');
    assertEq(GHO_GSM.getAccruedFees(), fee, 'Unexpected GSM accrued fees');

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
    assertEq(GHO_TOKEN.balanceOf(TREASURY), treasuryBalanceBefore + fee, 'Unexpected GHO balance in treasury');
    assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');
  }

  function testDistributeYieldToTreasuryDoNothing() public {
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
    assertEq(GHO_GSM.getAccruedFees(), 0, 'Unexpected GSM accrued fees');

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

    // Alice as configurator
    GHO_GSM.grantRole(GSM_CONFIGURATOR_ROLE, ALICE);
    vm.startPrank(address(ALICE));

    GHO_GSM.updateFeeStrategy(address(0));

    USDC_TOKEN.approve(address(GHO_GSM), DEFAULT_GSM_USDC_AMOUNT);
    GHO_GSM.sellAsset(DEFAULT_GSM_USDC_AMOUNT, ALICE);

    assertEq(
      GHO_GSM.getAvailableUnderlyingExposure(),
      DEFAULT_GSM_USDC_EXPOSURE - DEFAULT_GSM_USDC_AMOUNT,
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
    GsmAtoken gsm,
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
    GsmAtoken gsm,
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
    vm.prank(0xA91661efEe567b353D55948C0f051C1A16E503A5);
    IERC20(USDC_ATOKEN).transfer(address(GHO_GSM), amount);
  }
}
