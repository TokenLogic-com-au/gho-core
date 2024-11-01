// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IGsm} from './interfaces/IGsm.sol';
import {Gsm4626, GPv2SafeERC20, IERC20, SafeCast, IGhoToken} from './Gsm4626.sol';
import {IPool} from 'aave-v3-core/contracts/interfaces/IPool.sol';
import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';


interface StaticAtoken {
  function deposit(uint256 assets, address receiver, uint16 referralCode, bool depositToAave) external returns (uint256);
  function redeem(uint256 shares, address receiver, address owner, bool withdrawFromAave) external returns (uint256);
  function previewDeposit(uint256) external view returns (uint256);
}

/**
 * @title Gsm4626Adapter
 * @author Aave
 * @notice GHO Stability Module. It provides buy/sell facilities to go to/from an underlying asset to/from GHO.
 * @dev To be covered by a proxy contract.
 */
contract Gsm4626Adapter is EIP712 {
  using GPv2SafeERC20 for IERC20;
  using SafeCast for uint256;

  bytes32 public constant BUY_ASSET_WITH_SIG_TYPEHASH =
    keccak256(
      'BuyAssetWithSig(address originator,uint256 minAmount,address receiver,uint256 nonce,uint256 deadline)'
    );

  bytes32 public constant SELL_ASSET_WITH_SIG_TYPEHASH =
    keccak256(
      'SellAssetWithSig(address originator,uint256 maxAmount,address receiver,uint256 nonce,uint256 deadline)'
    );

  Gsm4626 public immutable GSM;
  address public immutable UNDERLYING;

  mapping(address => uint256) public nonces;

  constructor(
    address gsm,
    address underlyingAsset
  ) EIP712('GSMConverter', '1') {
    require(gsm != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(underlyingAsset != address(0), 'ZERO_ADDRESS_NOT_VALID');
    GSM = Gsm4626(gsm);
    IERC20(underlyingAsset).approve(GSM.UNDERLYING_ASSET(), type(uint256).max);
    IERC20(GSM.UNDERLYING_ASSET()).approve(gsm,  type(uint256).max);
    UNDERLYING = underlyingAsset;
  }

  function buyAsset(
    uint256 minAmount,
    address receiver
  ) external returns (uint256, uint256) {
    return _buyAsset(msg.sender, minAmount, receiver);
  }
  
  function buyAssetWithSig(
    address originator,
    uint256 minAmount,
    address receiver,
    uint256 deadline,
    bytes calldata signature
  ) external returns (uint256, uint256) {
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

  function sellAsset(
    uint256 maxAmount,
    address receiver
  ) external returns (uint256, uint256) {
    return _sellAsset(msg.sender, maxAmount, receiver);
  }

  function sellAssetWithSig(
    address originator,
    uint256 maxAmount,
    address receiver,
    uint256 deadline,
    bytes calldata signature
  ) external returns (uint256, uint256) {
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

  function DOMAIN_SEPARATOR() external view returns (bytes32) {
    return _domainSeparatorV4();
  }

  
  function getGhoAmountForBuyAsset(
    uint256 minAssetAmount
  ) external view returns (uint256, uint256, uint256, uint256) {
    return GSM.getGhoAmountForBuyAsset(minAssetAmount);
  }

  function getGhoAmountForSellAsset(
    uint256 maxAssetAmount
  ) external view returns (uint256, uint256, uint256, uint256) {
    return GSM.getGhoAmountForSellAsset(maxAssetAmount);
  }

  function getAssetAmountForBuyAsset(
    uint256 maxGhoAmount
  ) external view returns (uint256, uint256, uint256, uint256) {
    return GSM.getAssetAmountForBuyAsset(maxGhoAmount);
  }

  function getAssetAmountForSellAsset(
    uint256 minGhoAmount
  ) external view returns (uint256, uint256, uint256, uint256) {
    return GSM.getAssetAmountForSellAsset(minGhoAmount);
  }

  
  function getAvailableUnderlyingExposure() external view returns (uint256) {
    return GSM.getAvailableUnderlyingExposure();
  }

  
  function getExposureCap() external view returns (uint128) {
    return GSM.getExposureCap();
  }

  
  function getAvailableLiquidity() external view returns (uint256) {
    return GSM.getAvailableLiquidity();
  }

  
  function getFeeStrategy() external view returns (address) {
    return GSM.getFeeStrategy();
  }

  
  function getIsFrozen() external view returns (bool) {
    return GSM.getIsFrozen();
  }

  
  function getIsSeized() external view returns (bool) {
    return GSM.getIsSeized();
  }

  
  function canSwap() external view returns (bool) {
    return GSM.canSwap();
  }

  function _buyAsset(
    address originator,
    uint256 minAmount,
    address receiver
  ) internal returns (uint256, uint256) {
    IERC20(GSM.GHO_TOKEN()).transferFrom(originator, address(this), minAmount);
    (uint256 aTokenBought, uint256 ghoSold) = GSM.buyAsset(minAmount, receiver);
    uint256 underlyingWithdrawn = StaticAtoken(GSM.UNDERLYING_ASSET()).redeem(
      aTokenBought,
      receiver, 
      address(this),
      true
    );
    return (underlyingWithdrawn, ghoSold);
  }

  function _sellAsset(
    address originator,
    uint256 maxAmount,
    address receiver
  ) internal returns (uint256, uint256) {
    IERC20(UNDERLYING).transferFrom(originator, address(this), maxAmount);
    uint256 shares = StaticAtoken(GSM.UNDERLYING_ASSET()).deposit(maxAmount, address(this), 0, true);
    IERC20(GSM.UNDERLYING_ASSET()).balanceOf(address(this));
    return GSM.sellAsset(shares, receiver);
  }

}