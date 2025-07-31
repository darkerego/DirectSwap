// SPDX-License-Identifier: MIT
pragma solidity >=0.8.26;



struct Deployment {
    uint256 cid;
    address uniswapV2Router;
    address uniswapV2Factory;
    address uniswapV3Router;
    address uniswapV3Factory;
    address wrappedEther;
    address nativeEther;


}



contract DeploymentAddresses {
    Deployment internal deployment;
    error NetworkNotImplemented(uint256);
    event Deployed(uint256 chainId);
    constructor() {
        deployment.nativeEther = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        uint256 cid;
        assembly {
          cid := chainid()
        }
        deployment.cid = cid;
        if (cid == 8453) {
            deployment.uniswapV2Router = 0x6BDED42c6DA8FBf0d2bA55B2fa120C5e0c8D7891;
            deployment.uniswapV2Factory = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
            deployment.uniswapV3Router= 0x2626664c2603336E57B271c5C0b26F421741e481;
            deployment.uniswapV3Factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
            deployment.wrappedEther = 0x4200000000000000000000000000000000000006;

        } else {
            revert NetworkNotImplemented(deployment.cid);
        }
        emit Deployed(deployment.cid);
    }


}