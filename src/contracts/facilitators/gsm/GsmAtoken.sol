// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IGsm} from './interfaces/IGsm.sol';
import {Gsm, GPv2SafeERC20, IERC20, SafeCast, IGhoToken} from './Gsm.sol';
import {IPool} from 'aave-v3-core/contracts/interfaces/IPool.sol';

/**
 * @title GsmAtoken
 * @author Aave
 * @notice GHO Stability Module. It provides buy/sell facilities to go to/from an underlying asset to/from GHO.
 * @dev To be covered by a proxy contract.
 */
contract GsmAtoken is Gsm {
  using GPv2SafeERC20 for IERC20;
  using SafeCast for uint256;

  address public immutable UNDERLYING_ATOKEN;
  address public immutable POOL;

  constructor(
    address ghoToken, 
    address underlyingAsset,
    address underlyingAtoken,
    address pool,
    address priceStrategy
  ) Gsm(ghoToken, underlyingAsset, priceStrategy) {
    require(underlyingAtoken != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(pool != address(0), 'ZERO_ADDRESS_NOT_VALID');
    UNDERLYING_ATOKEN = underlyingAtoken;
    POOL = pool;
  }

  function initialize(
    address admin,
    address ghoTreasury,
    uint128 exposureCap
  ) external override initializer {
    require(admin != address(0), 'ZERO_ADDRESS_NOT_VALID');
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(CONFIGURATOR_ROLE, admin);
    _updateGhoTreasury(ghoTreasury);
    _updateExposureCap(exposureCap);

    IERC20(UNDERLYING_ATOKEN).approve(POOL, type(uint256).max);
    IERC20 underlying = IERC20(UNDERLYING_ASSET);
    underlying.approve(POOL, type(uint256).max);
    uint256 underlyingBalance = underlying.balanceOf(address(this));
    if (underlyingBalance > 0) {
      IPool(POOL).deposit(address(underlying), underlyingBalance, address(this), 0);
    }
  }

  function rescueTokens(
    address token,
    address to,
    uint256 amount
  ) external override onlyRole(TOKEN_RESCUER_ROLE) {
    require(amount > 0, 'INVALID_AMOUNT');
    if (token == GHO_TOKEN) {
      uint256 rescuableBalance = IERC20(token).balanceOf(address(this)) - _accruedFees;
      require(rescuableBalance >= amount, 'INSUFFICIENT_GHO_TO_RESCUE');
    }
    if (token == UNDERLYING_ATOKEN) {
      uint256 rescuableBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this)) - _currentExposure;
      require(rescuableBalance >= amount, 'INSUFFICIENT_EXOGENOUS_ASSET_TO_RESCUE');
    }
    IERC20(token).safeTransfer(to, amount);
    emit TokensRescued(token, to, amount);
  }

  function seize() external override notSeized onlyRole(LIQUIDATOR_ROLE) returns (uint256) {
    _isSeized = true;
    _currentExposure = 0;
    _updateExposureCap(0);

    (, uint256 ghoMinted) = IGhoToken(GHO_TOKEN).getFacilitatorBucket(address(this));

    uint256 aTokenBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this));
    if (aTokenBalance > 0) {
      IERC20(UNDERLYING_ATOKEN).safeTransfer(_ghoTreasury, aTokenBalance);
    }

    emit Seized(msg.sender, _ghoTreasury, aTokenBalance, ghoMinted);
    return aTokenBalance;
  }

  /// Could make sense to merge this code into the distributeFeesToTreasury function
  /// also possible to make this function permissioned by adding a harvester role
  function distributeYieldToTreasury() external {
    uint256 currentExposure = _currentExposure + 1e6;
    uint256 aTokenBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this));
    if (aTokenBalance > currentExposure) {
      uint256 accruedFees = aTokenBalance - currentExposure;
      IERC20(UNDERLYING_ATOKEN).transfer(_ghoTreasury, accruedFees);
      emit FeesDistributedToTreasury(_ghoTreasury, UNDERLYING_ATOKEN, accruedFees);
    }
  }

  function GSM_REVISION() public pure virtual override returns (uint256) {
    return 2;
  }

  function _beforeBuyAsset(address, uint256 amount, address) internal override {
    /// the check bellow is made in the main _buyAsset function, but is needed here anyway
    require(amount > 0, 'INVALID_AMOUNT');
    IPool(POOL).withdraw(UNDERLYING_ASSET, amount, address(this));
  }

  function _afterSellAsset(address, uint256 amount, address) internal override {
    IPool(POOL).deposit(UNDERLYING_ASSET, amount, address(this), 0);
  }

}