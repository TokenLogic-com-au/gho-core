# GSM V2

Forum post draft: https://hackmd.io/uuy0IHwuRtaNWfaL245cwg

## Overview

Underlying is currently sitting idle in the GSM, time to put it to work.

From now on, after the GSM receives Underluing, it deposits the underlying into the Aave V3 Pool. Before the GSM sends Underlying, it withdraws the required amount from the Aave V3 Pool.

GSM will also allow harvesting the yield from aave v3 pool back to the treasury.

Here's a quick sketch:

![diagram](https://i.imgur.com/wOp49Z8.png)

## Key Components

This PR includes an proof of concept of the implementation for this new GSM.

This implementation is not considered complete in any sense, and is included as a study of the proposed changes and the impact they could bring to the current audited implementation. For us the main goal is to keep the coverage needed for new audits to a bare minimum.

Proposed changes are simple, small, and interact only with trusted code (Aave V3 Pool deposit/withdraw).

A Harvester role could be added to restrict who can call `distributeYieldToTreasury`

`distributeYieldToTreasury` & `distributeFeesToTreasury` functions could be merged into a single function

To reduce new storage footprint, the underlying Atoken address could be fetched from pool config dinamically.

### Changes

All modifications to the original Gsm implementation are between `/// NEW` and `/// END NEW` blocks.

GSM diff: https://www.diffchecker.com/NPZQTJKj/

Test diff: https://www.diffchecker.com/4eIOqZ6H/

### Storage variables

Two new storage variables are added in this implementation. Both aditions are pretty much self-explanatory.

```Solidity
  address public immutable UNDERLYING_ATOKEN;
  address public immutable POOL;
```

### Changes to existing functions

**Constructor**:

We introduce two new constructor params in this new version to assign the new storage variables. We also bump the EIP712 version.

```Solidity
  constructor(
    address ghoToken,
    address underlyingAsset,
    address underlyingAtoken,
    address pool,
    address priceStrategy
  ) EIP712('GSM', '2') {

(...)

    require(underlyingAtoken != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(pool != address(0), 'ZERO_ADDRESS_NOT_VALID');

    UNDERLYING_ATOKEN = underlyingAtoken;
    POOL = pool;
```

**initialize**:

To allow the GSM to deposit and withdraw from the pool at will, we add two maximum approvals to both the underlying token and the respective Atoken. These approvals could be made on the fly before deposit/withdraw to prevent hanging approvals.

We also include the migration of the underlying to the aToken.

```Solidity
    IERC20(UNDERLYING_ATOKEN).approve(POOL, type(uint256).max);
    IERC20 underlying = IERC20(UNDERLYING_ASSET);
    underlying.approve(POOL, type(uint256).max);
    uint256 underlyingBalance = underlying.balanceOf(address(this));
    if (underlyingBalance > 0) {
      IPool(POOL).deposit(address(underlying), underlyingBalance, address(this), 0);
    }
```

**rescueTokens**:

Since the underlying now sits in aTokens, we change the logic of rescuing the underlying to target the aToken.

```Solidity
    if (token == UNDERLYING_ATOKEN) {
      uint256 rescuableBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this)) - _currentExposure;
      require(rescuableBalance >= amount, 'INSUFFICIENT_EXOGENOUS_ASSET_TO_RESCUE');
    }
```

**seize**:

The seize function also changes the target from the underlying token to the aToken.

```Solidity
    uint256 aTokenBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this));
    if (aTokenBalance > 0) {
      IERC20(UNDERLYING_ATOKEN).safeTransfer(_ghoTreasury, aTokenBalance);
    }

    emit Seized(msg.sender, _ghoTreasury, aTokenBalance, ghoMinted);
    return aTokenBalance;
```

**GSM_REVISION**:

We bump the version number from `1` to `2`.

```Solidity
return 2;
```

**\_buyAsset**:

In this function we add a single line of code to withdraw the necessary underlying from the Pool before we transfer the underlying to the user.

```Solidity
    IPool(POOL).withdraw(UNDERLYING_ASSET, assetAmount, address(this));
```

**\_sellAsset**:

In this function we query the current underlying balance of the GSM and deposit all underlying into the pool.

```Solidity
    IPool(POOL).deposit(UNDERLYING_ASSET, underlyingBalance, address(this), 0);
```

### New functions

**distributeYieldToTreasury**:

This function allows the treasury to collect the yield generated from the aTokens held.

```Solidity
    function distributeYieldToTreasury() external {
      uint256 currentExposure = _currentExposure + 1e6;
      uint256 aTokenBalance = IERC20(UNDERLYING_ATOKEN).balanceOf(address(this));
      if (aTokenBalance > currentExposure) {
        uint256 accruedFees = aTokenBalance - currentExposure;
        IERC20(UNDERLYING_ATOKEN).transfer(_ghoTreasury, accruedFees);
        emit FeesDistributedToTreasury(_ghoTreasury, UNDERLYING_ATOKEN, accruedFees);
      }
    }
```

We leave 1 aUSDC in the contract to make sure no rounding errors occur if a swap is made immediately after the yield gets distributed.

## Security Considerations

When updating from the previous version of the GSM, it's recommended to atomically bundle the `initialize` call with a `transfer` of some aToken to the GSM. This makes sure the GSM holds aToken more than the `_currentExposure`, and allows users to safely use the GSM in the same block. This problem only exists when `_currentExposure == aToken.balanceOf(GSM)`, at time/block = 0. As time and blocks increase the `_curentExposure` will always be less than `aToken.balanceOf(GSM)`;

## Tests

Tests are still incomplete, but we have ported 100% of the existing GSM tests to target our new GSM version with minimal changes.

On our test setup we (1) fork mainnet, (2) deploy the new implementation, (3) upgrade the current GSM to the new version.

We also included some simple tests to cover the newly added functionality.
