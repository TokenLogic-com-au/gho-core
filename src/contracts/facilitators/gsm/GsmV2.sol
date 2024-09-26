// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {VersionedInitializable} from '@aave/core-v3/contracts/protocol/libraries/aave-upgradeability/VersionedInitializable.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {GPv2SafeERC20} from '@aave/core-v3/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {IGhoFacilitator} from '../../gho/interfaces/IGhoFacilitator.sol';
import {IGhoToken} from '../../gho/interfaces/IGhoToken.sol';
import {IGsmPriceStrategy} from './priceStrategy/interfaces/IGsmPriceStrategy.sol';
import {IGsmFeeStrategy} from './feeStrategy/interfaces/IGsmFeeStrategy.sol';
import {IGsm} from './interfaces/IGsm.sol';
/// NEW
import {IPool} from 'aave-v3-core/contracts/interfaces/IPool.sol';
/// END NEW

/**
 * @title GsmV2
 * @author Aave
 * @notice GHO Stability Module. It provides buy/sell facilities to go to/from an underlying asset to/from GHO.
 * @dev To be covered by a proxy contract.
 */
contract GsmV2 is AccessControl, VersionedInitializable, EIP712, IGsm {
  using GPv2SafeERC20 for IERC20;
  using SafeCast for uint256;

  /// @inheritdoc IGsm
  bytes32 public constant CONFIGURATOR_ROLE = keccak256('CONFIGURATOR_ROLE');

  /// @inheritdoc IGsm
  bytes32 public constant TOKEN_RESCUER_ROLE = keccak256('TOKEN_RESCUER_ROLE');

  /// @inheritdoc IGsm
  bytes32 public constant SWAP_FREEZER_ROLE = keccak256('SWAP_FREEZER_ROLE');

  /// @inheritdoc IGsm
  bytes32 public constant LIQUIDATOR_ROLE = keccak256('LIQUIDATOR_ROLE');

  /// @inheritdoc IGsm
  bytes32 public constant BUY_ASSET_WITH_SIG_TYPEHASH =
    keccak256(
      'BuyAssetWithSig(address originator,uint256 minAmount,address receiver,uint256 nonce,uint256 deadline)'
    );

  /// @inheritdoc IGsm
  bytes32 public constant SELL_ASSET_WITH_SIG_TYPEHASH =
    keccak256(
      'SellAssetWithSig(address originator,uint256 maxAmount,address receiver,uint256 nonce,uint256 deadline)'
    );

  /// @inheritdoc IGsm
  address public immutable GHO_TOKEN;

  /// @inheritdoc IGsm
  address public immutable UNDERLYING_ASSET;

  /// @inheritdoc IGsm
  address public immutable PRICE_STRATEGY;

  /// @inheritdoc IGsm
  mapping(address => uint256) public nonces;

  address internal _ghoTreasury;
  address internal _feeStrategy;
  bool internal _isFrozen;
  bool internal _isSeized;
  uint128 internal _exposureCap;
  uint128 internal _currentExposure;
  uint128 internal _accruedFees;

  /// NEW
  address public immutable UNDERLYING_ATOKEN;
  address public immutable POOL;
  /// END NEW

  /**
   * @dev Require GSM to not be frozen for functions marked by this modifier
   */
  modifier notFrozen() {
    require(!_isFrozen, 'GSM_FROZEN');
    _;
  }

  /**
   * @dev Require GSM to not be seized for functions marked by this modifier
   */
  modifier notSeized() {
    require(!_isSeized, 'GSM_SEIZED');
    _;
  }

  /**
   * @dev Constructor
   * @param ghoToken The address of the GHO token contract
   * @param underlyingAsset The address of the collateral asset
   * @param underlyingAtoken The address of the collateral aToken
   * @param pool The address of the Aave V3 Pool
   * @param priceStrategy The address of the price strategy
   */
  /// NEW
  constructor(
    address ghoToken,
    address underlyingAsset,
    address underlyingAtoken,
    address pool,
    address priceStrategy
  ) EIP712('GSM', '2') {
    /// END NEW
    require(ghoToken != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(underlyingAsset != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(
      IGsmPriceStrategy(priceStrategy).UNDERLYING_ASSET() == underlyingAsset,
      'INVALID_PRICE_STRATEGY'
    );
    /// NEW
    require(underlyingAtoken != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(pool != address(0), 'ZERO_ADDRESS_NOT_VALID');

    UNDERLYING_ATOKEN = underlyingAtoken;
    POOL = pool;
    /// END NEW

    GHO_TOKEN = ghoToken;
    UNDERLYING_ASSET = underlyingAsset;
    PRICE_STRATEGY = priceStrategy;
  }

  /**
   * @notice GSM initializer
   * @param admin The address of the default admin role
   * @param ghoTreasury The address of the GHO treasury
   * @param exposureCap Maximum amount of user-supplied underlying asset in GSM
   */
  function initialize(
    address admin,
    address ghoTreasury,
    uint128 exposureCap
  ) external initializer {
    require(admin != address(0), 'ZERO_ADDRESS_NOT_VALID');
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(CONFIGURATOR_ROLE, admin);
    _updateGhoTreasury(ghoTreasury);
    _updateExposureCap(exposureCap);
    /// NEW
    IERC20(UNDERLYING_ASSET).approve(POOL, type(uint256).max);
    IERC20(UNDERLYING_ATOKEN).approve(POOL, type(uint256).max);
    /// END NEW
  }

  /// @inheritdoc IGsm
  function buyAsset(
    uint256 minAmount,
    address receiver
  ) external notFrozen notSeized returns (uint256, uint256) {
    return _buyAsset(msg.sender, minAmount, receiver);
  }

  /// @inheritdoc IGsm
  function buyAssetWithSig(
    address originator,
    uint256 minAmount,
    address receiver,
    uint256 deadline,
    bytes calldata signature
  ) external notFrozen notSeized returns (uint256, uint256) {
    require(deadline >= block.timestamp, 'SIGNATURE_DEADLINE_EXPIRED');
    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        _domainSeparatorV4(),
        BUY_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(originator, minAmount, receiver, nonces[originator]++, deadline)
      )
    );
    require(
      SignatureChecker.isValidSignatureNow(originator, digest, signature),
      'SIGNATURE_INVALID'
    );

    return _buyAsset(originator, minAmount, receiver);
  }

  /// @inheritdoc IGsm
  function sellAsset(
    uint256 maxAmount,
    address receiver
  ) external notFrozen notSeized returns (uint256, uint256) {
    return _sellAsset(msg.sender, maxAmount, receiver);
  }

  /// @inheritdoc IGsm
  function sellAssetWithSig(
    address originator,
    uint256 maxAmount,
    address receiver,
    uint256 deadline,
    bytes calldata signature
  ) external notFrozen notSeized returns (uint256, uint256) {
    require(deadline >= block.timestamp, 'SIGNATURE_DEADLINE_EXPIRED');
    bytes32 digest = keccak256(
      abi.encode(
        '\x19\x01',
        _domainSeparatorV4(),
        SELL_ASSET_WITH_SIG_TYPEHASH,
        abi.encode(originator, maxAmount, receiver, nonces[originator]++, deadline)
      )
    );
    require(
      SignatureChecker.isValidSignatureNow(originator, digest, signature),
      'SIGNATURE_INVALID'
    );

    return _sellAsset(originator, maxAmount, receiver);
  }

  /// @inheritdoc IGsm
  function rescueTokens(
    address token,
    address to,
    uint256 amount
  ) external onlyRole(TOKEN_RESCUER_ROLE) {
    require(amount > 0, 'INVALID_AMOUNT');
    if (token == GHO_TOKEN) {
      uint256 rescuableBalance = IERC20(token).balanceOf(address(this)) - _accruedFees;
      require(rescuableBalance >= amount, 'INSUFFICIENT_GHO_TO_RESCUE');
    }
    /// NEW
    if (token == UNDERLYING_ATOKEN) {
      /// _currentExposure + 1 to account for off-by-one precision problems
      /// errors on the side of the GSM backing
      uint256 rescuableBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this)) -
        (_currentExposure + 1);
      require(rescuableBalance >= amount, 'INSUFFICIENT_EXOGENOUS_ASSET_TO_RESCUE');
    }
    /// END NEW
    IERC20(token).safeTransfer(to, amount);
    emit TokensRescued(token, to, amount);
  }

  /// @inheritdoc IGsm
  function setSwapFreeze(bool enable) external onlyRole(SWAP_FREEZER_ROLE) {
    if (enable) {
      require(!_isFrozen, 'GSM_ALREADY_FROZEN');
    } else {
      require(_isFrozen, 'GSM_ALREADY_UNFROZEN');
    }
    _isFrozen = enable;
    emit SwapFreeze(msg.sender, enable);
  }

  /// @inheritdoc IGsm
  function seize() external notSeized onlyRole(LIQUIDATOR_ROLE) returns (uint256) {
    _isSeized = true;
    _currentExposure = 0;
    _updateExposureCap(0);

    (, uint256 ghoMinted) = IGhoToken(GHO_TOKEN).getFacilitatorBucket(address(this));
    /// NEW
    uint256 aTokenBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this));
    if (aTokenBalance > 0) {
      IERC20(UNDERLYING_ATOKEN).safeTransfer(_ghoTreasury, aTokenBalance);
    }

    emit Seized(msg.sender, _ghoTreasury, aTokenBalance, ghoMinted);
    return aTokenBalance;
    /// END NEW
  }

  /// @inheritdoc IGsm
  function burnAfterSeize(uint256 amount) external onlyRole(LIQUIDATOR_ROLE) returns (uint256) {
    require(_isSeized, 'GSM_NOT_SEIZED');
    require(amount > 0, 'INVALID_AMOUNT');

    (, uint256 ghoMinted) = IGhoToken(GHO_TOKEN).getFacilitatorBucket(address(this));
    if (amount > ghoMinted) {
      amount = ghoMinted;
    }
    IGhoToken(GHO_TOKEN).transferFrom(msg.sender, address(this), amount);
    IGhoToken(GHO_TOKEN).burn(amount);

    emit BurnAfterSeize(msg.sender, amount, (ghoMinted - amount));
    return amount;
  }

  /// @inheritdoc IGsm
  function updateFeeStrategy(address feeStrategy) external onlyRole(CONFIGURATOR_ROLE) {
    _updateFeeStrategy(feeStrategy);
  }

  /// @inheritdoc IGsm
  function updateExposureCap(uint128 exposureCap) external onlyRole(CONFIGURATOR_ROLE) {
    _updateExposureCap(exposureCap);
  }

  /// @inheritdoc IGhoFacilitator
  function distributeFeesToTreasury() public virtual override {
    uint256 accruedFees = _accruedFees;
    if (accruedFees > 0) {
      _accruedFees = 0;
      IERC20(GHO_TOKEN).transfer(_ghoTreasury, accruedFees);
      emit FeesDistributedToTreasury(_ghoTreasury, GHO_TOKEN, accruedFees);
    }
  }
  /// NEW
  /// Could make sense to merge this code into the function above
  /// also possible to make this function permissioned by adding a harvester role
  function distributeYieldToTreasury() public {
    /// _currentExposure + 1 to account for off-by-one precision problems
    /// errors on the side of the GSM backing
    uint256 currentExposure = _currentExposure + 1;
    uint256 aTokenBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this));
    if (aTokenBalance > currentExposure) {
      uint256 accruedFees = aTokenBalance - currentExposure;
      IERC20(UNDERLYING_ATOKEN).transfer(_ghoTreasury, accruedFees);
      emit FeesDistributedToTreasury(_ghoTreasury, UNDERLYING_ATOKEN, accruedFees);
    }
  }
  /// END NEW

  /// @inheritdoc IGhoFacilitator
  function updateGhoTreasury(address newGhoTreasury) external override onlyRole(CONFIGURATOR_ROLE) {
    _updateGhoTreasury(newGhoTreasury);
  }

  /// @inheritdoc IGsm
  function DOMAIN_SEPARATOR() external view returns (bytes32) {
    return _domainSeparatorV4();
  }

  /// @inheritdoc IGsm
  function getGhoAmountForBuyAsset(
    uint256 minAssetAmount
  ) external view returns (uint256, uint256, uint256, uint256) {
    return _calculateGhoAmountForBuyAsset(minAssetAmount);
  }

  /// @inheritdoc IGsm
  function getGhoAmountForSellAsset(
    uint256 maxAssetAmount
  ) external view returns (uint256, uint256, uint256, uint256) {
    return _calculateGhoAmountForSellAsset(maxAssetAmount);
  }

  /// @inheritdoc IGsm
  function getAssetAmountForBuyAsset(
    uint256 maxGhoAmount
  ) external view returns (uint256, uint256, uint256, uint256) {
    bool withFee = _feeStrategy != address(0);
    uint256 grossAmount = withFee
      ? IGsmFeeStrategy(_feeStrategy).getGrossAmountFromTotalBought(maxGhoAmount)
      : maxGhoAmount;
    // round down so maxGhoAmount is guaranteed
    uint256 assetAmount = IGsmPriceStrategy(PRICE_STRATEGY).getGhoPriceInAsset(grossAmount, false);
    uint256 finalGrossAmount = IGsmPriceStrategy(PRICE_STRATEGY).getAssetPriceInGho(
      assetAmount,
      true
    );
    uint256 finalFee = withFee ? IGsmFeeStrategy(_feeStrategy).getBuyFee(finalGrossAmount) : 0;
    return (assetAmount, finalGrossAmount + finalFee, finalGrossAmount, finalFee);
  }

  /// @inheritdoc IGsm
  function getAssetAmountForSellAsset(
    uint256 minGhoAmount
  ) external view returns (uint256, uint256, uint256, uint256) {
    bool withFee = _feeStrategy != address(0);
    uint256 grossAmount = withFee
      ? IGsmFeeStrategy(_feeStrategy).getGrossAmountFromTotalSold(minGhoAmount)
      : minGhoAmount;
    // round up so minGhoAmount is guaranteed
    uint256 assetAmount = IGsmPriceStrategy(PRICE_STRATEGY).getGhoPriceInAsset(grossAmount, true);
    uint256 finalGrossAmount = IGsmPriceStrategy(PRICE_STRATEGY).getAssetPriceInGho(
      assetAmount,
      false
    );
    uint256 finalFee = withFee ? IGsmFeeStrategy(_feeStrategy).getSellFee(finalGrossAmount) : 0;
    return (assetAmount, finalGrossAmount - finalFee, finalGrossAmount, finalFee);
  }

  /// @inheritdoc IGsm
  function getAvailableUnderlyingExposure() external view returns (uint256) {
    return _exposureCap > _currentExposure ? _exposureCap - _currentExposure : 0;
  }

  /// @inheritdoc IGsm
  function getExposureCap() external view returns (uint128) {
    return _exposureCap;
  }

  /// @inheritdoc IGsm
  function getAvailableLiquidity() external view returns (uint256) {
    /// NEW
    return _currentExposure != 0 ? (_currentExposure - 1) : _currentExposure;
    /// END NEW
  }

  /// @inheritdoc IGsm
  function getFeeStrategy() external view returns (address) {
    return _feeStrategy;
  }

  /// @inheritdoc IGsm
  function getAccruedFees() external view returns (uint256) {
    return _accruedFees;
  }

  /// @inheritdoc IGsm
  function getIsFrozen() external view returns (bool) {
    return _isFrozen;
  }

  /// @inheritdoc IGsm
  function getIsSeized() external view returns (bool) {
    return _isSeized;
  }

  /// @inheritdoc IGsm
  function canSwap() external view returns (bool) {
    return !_isFrozen && !_isSeized;
  }

  /// @inheritdoc IGhoFacilitator
  function getGhoTreasury() external view override returns (address) {
    return _ghoTreasury;
  }

  /// @inheritdoc IGsm
  function GSM_REVISION() public pure virtual override returns (uint256) {
    /// NEW
    return 2;
    /// END NEW
  }

  /**
   * @dev Buys an underlying asset with GHO
   * @param originator The originator of the request
   * @param minAmount The minimum amount of the underlying asset desired for purchase
   * @param receiver The recipient address of the underlying asset being purchased
   * @return The amount of underlying asset bought
   * @return The amount of GHO sold by the user
   */
  function _buyAsset(
    address originator,
    uint256 minAmount,
    address receiver
  ) internal returns (uint256, uint256) {
    (
      uint256 assetAmount,
      uint256 ghoSold,
      uint256 grossAmount,
      uint256 fee
    ) = _calculateGhoAmountForBuyAsset(minAmount);

    _beforeBuyAsset(originator, assetAmount, receiver);

    require(assetAmount > 0, 'INVALID_AMOUNT');
    /// NEW
    require(
      _currentExposure - 1 >= assetAmount,
      'INSUFFICIENT_AVAILABLE_EXOGENOUS_ASSET_LIQUIDITY'
    );
    /// END NEW

    _currentExposure -= uint128(assetAmount);
    _accruedFees += fee.toUint128();
    IGhoToken(GHO_TOKEN).transferFrom(originator, address(this), ghoSold);
    IGhoToken(GHO_TOKEN).burn(grossAmount);

    /// NEW
    IPool(POOL).withdraw(UNDERLYING_ASSET, assetAmount, address(this));
    /// END NEW

    IERC20(UNDERLYING_ASSET).safeTransfer(receiver, assetAmount);

    emit BuyAsset(originator, receiver, assetAmount, ghoSold, fee);
    return (assetAmount, ghoSold);
  }

  /**
   * @dev Hook that is called before `buyAsset`.
   * @dev This can be used to add custom logic
   * @param originator Originator of the request
   * @param amount The amount of the underlying asset desired for purchase
   * @param receiver Recipient address of the underlying asset being purchased
   */
  function _beforeBuyAsset(address originator, uint256 amount, address receiver) internal virtual {}

  /**
   * @dev Sells an underlying asset for GHO
   * @param originator The originator of the request
   * @param maxAmount The maximum amount of the underlying asset desired to sell
   * @param receiver The recipient address of the GHO being purchased
   * @return The amount of underlying asset sold
   * @return The amount of GHO bought by the user
   */
  function _sellAsset(
    address originator,
    uint256 maxAmount,
    address receiver
  ) internal returns (uint256, uint256) {
    (
      uint256 assetAmount,
      uint256 ghoBought,
      uint256 grossAmount,
      uint256 fee
    ) = _calculateGhoAmountForSellAsset(maxAmount);

    _beforeSellAsset(originator, assetAmount, receiver);

    require(assetAmount > 0, 'INVALID_AMOUNT');
    require(_currentExposure + assetAmount <= _exposureCap, 'EXOGENOUS_ASSET_EXPOSURE_TOO_HIGH');

    _currentExposure += uint128(assetAmount);
    _accruedFees += fee.toUint128();
    IERC20(UNDERLYING_ASSET).safeTransferFrom(originator, address(this), assetAmount);

    IGhoToken(GHO_TOKEN).mint(address(this), grossAmount);
    IGhoToken(GHO_TOKEN).transfer(receiver, ghoBought);

    /// NEW
    uint256 underlyingBalance = IERC20(UNDERLYING_ASSET).balanceOf(address(this));
    IPool(POOL).deposit(UNDERLYING_ASSET, underlyingBalance, address(this), 0);
    /// END NEW

    emit SellAsset(originator, receiver, assetAmount, grossAmount, fee);
    return (assetAmount, ghoBought);
  }

  /**
   * @dev Hook that is called before `sellAsset`.
   * @dev This can be used to add custom logic
   * @param originator Originator of the request
   * @param amount The amount of the underlying asset desired to sell
   * @param receiver Recipient address of the GHO being purchased
   */
  function _beforeSellAsset(
    address originator,
    uint256 amount,
    address receiver
  ) internal virtual {}

  /**
   * @dev Returns the amount of GHO sold in exchange of buying underlying asset
   * @param assetAmount The amount of underlying asset to buy
   * @return The exact amount of asset the user purchases
   * @return The total amount of GHO the user sells (gross amount in GHO plus fee)
   * @return The gross amount of GHO
   * @return The fee amount in GHO, applied on top of gross amount of GHO
   */
  function _calculateGhoAmountForBuyAsset(
    uint256 assetAmount
  ) internal view returns (uint256, uint256, uint256, uint256) {
    bool withFee = _feeStrategy != address(0);
    // pick the highest GHO amount possible for given asset amount
    uint256 grossAmount = IGsmPriceStrategy(PRICE_STRATEGY).getAssetPriceInGho(assetAmount, true);
    uint256 fee = withFee ? IGsmFeeStrategy(_feeStrategy).getBuyFee(grossAmount) : 0;
    uint256 ghoSold = grossAmount + fee;
    uint256 finalGrossAmount = withFee
      ? IGsmFeeStrategy(_feeStrategy).getGrossAmountFromTotalBought(ghoSold)
      : ghoSold;
    // pick the lowest asset amount possible for given GHO amount
    uint256 finalAssetAmount = IGsmPriceStrategy(PRICE_STRATEGY).getGhoPriceInAsset(
      finalGrossAmount,
      false
    );
    uint256 finalFee = ghoSold - finalGrossAmount;
    return (finalAssetAmount, finalGrossAmount + finalFee, finalGrossAmount, finalFee);
  }

  /**
   * @dev Returns the amount of GHO bought in exchange of a given amount of underlying asset
   * @param assetAmount The amount of underlying asset to sell
   * @return The exact amount of asset the user sells
   * @return The total amount of GHO the user buys (gross amount in GHO minus fee)
   * @return The gross amount of GHO
   * @return The fee amount in GHO, applied to the gross amount of GHO
   */
  function _calculateGhoAmountForSellAsset(
    uint256 assetAmount
  ) internal view returns (uint256, uint256, uint256, uint256) {
    bool withFee = _feeStrategy != address(0);
    // pick the lowest GHO amount possible for given asset amount
    uint256 grossAmount = IGsmPriceStrategy(PRICE_STRATEGY).getAssetPriceInGho(assetAmount, false);
    uint256 fee = withFee ? IGsmFeeStrategy(_feeStrategy).getSellFee(grossAmount) : 0;
    uint256 ghoBought = grossAmount - fee;
    uint256 finalGrossAmount = withFee
      ? IGsmFeeStrategy(_feeStrategy).getGrossAmountFromTotalSold(ghoBought)
      : ghoBought;
    // pick the highest asset amount possible for given GHO amount
    uint256 finalAssetAmount = IGsmPriceStrategy(PRICE_STRATEGY).getGhoPriceInAsset(
      finalGrossAmount,
      true
    );
    uint256 finalFee = finalGrossAmount - ghoBought;
    return (finalAssetAmount, finalGrossAmount - finalFee, finalGrossAmount, finalFee);
  }

  /**
   * @dev Updates Fee Strategy
   * @param feeStrategy The address of the new Fee Strategy
   */
  function _updateFeeStrategy(address feeStrategy) internal {
    address oldFeeStrategy = _feeStrategy;
    _feeStrategy = feeStrategy;
    emit FeeStrategyUpdated(oldFeeStrategy, feeStrategy);
  }

  /**
   * @dev Updates Exposure Cap
   * @param exposureCap The value of the new Exposure Cap
   */
  function _updateExposureCap(uint128 exposureCap) internal {
    uint128 oldExposureCap = _exposureCap;
    _exposureCap = exposureCap;
    emit ExposureCapUpdated(oldExposureCap, exposureCap);
  }

  /**
   * @dev Updates GHO Treasury Address
   * @param newGhoTreasury The address of the new GHO Treasury
   */
  function _updateGhoTreasury(address newGhoTreasury) internal {
    require(newGhoTreasury != address(0), 'ZERO_ADDRESS_NOT_VALID');
    address oldGhoTreasury = _ghoTreasury;
    _ghoTreasury = newGhoTreasury;
    emit GhoTreasuryUpdated(oldGhoTreasury, newGhoTreasury);
  }

  /// @inheritdoc VersionedInitializable
  function getRevision() internal pure virtual override returns (uint256) {
    return GSM_REVISION();
  }
}