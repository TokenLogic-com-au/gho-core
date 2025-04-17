// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import {ITransparentProxyFactory} from 'src/script/ITransparentProxyFactory.sol';
import {UpgradeableGhoToken} from 'src/contracts/gho/UpgradeableGhoToken.sol';

contract DeployGhoL2 is Script {
  // https://sonicscan.org/address/0xEB0682d148e874553008730f0686ea89db7DA412
  address internal constant TRANSPARENT_PROXY_FACTORY = 0xEB0682d148e874553008730f0686ea89db7DA412;

  // https://sonicscan.org/address/0x7b62461a3570c6AC8a9f8330421576e417B71EE7
  address internal constant EXECUTOR_LVL_1 = 0x7b62461a3570c6AC8a9f8330421576e417B71EE7;

  function run() external {
    uint256 deployerPrivateKey = vm.envUint('PRIVATE_KEY');
    vm.startBroadcast(deployerPrivateKey);
    _deploy();
    vm.stopBroadcast();
  }

  function _deploy() internal {
    UpgradeableGhoToken ghoTokenImpl = new UpgradeableGhoToken();
    ghoTokenImpl.initialize(EXECUTOR_LVL_1);

    bytes memory ghoInitParams = abi.encodeWithSignature('initialize(address)', EXECUTOR_LVL_1);
    address ghoProxy = ITransparentProxyFactory(TRANSPARENT_PROXY_FACTORY).create(
      address(ghoTokenImpl),
      EXECUTOR_LVL_1,
      ghoInitParams
    );
  }
}
