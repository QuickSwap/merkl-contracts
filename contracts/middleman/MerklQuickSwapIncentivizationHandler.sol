// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../DistributionCreator.sol";

/// @title MerklQuickSwapIncentivizationHandler
/// @author QuickSwap.
/// @notice Manages the transfer of rewards sent by QuickSwap to the
/// `DistributionCreator` contract
/// @dev This contract is built under the assumption that the `DistributionCreator` contract has already whitelisted
/// this contract for it to distribute rewards without having to sign a message
contract MerklQuickSwapIncentivizationHandler is Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                      PARAMETERS                                                    
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    address public operatorAddress;

    /// @notice Maps a gauge, incentive token pair to its reward parameters
    mapping(address => mapping(address => DistributionParameters)) public gaugeParams;


    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                   MODIFIER / EVENT                                                 
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    modifier onlyByOwnerOperator() {
        require(msg.sender == operatorAddress || msg.sender == owner(), "Not owner or operator");
        _;
    }

    event GaugeSet(address indexed gauge, address indexed incentiveTokenAddress);

    constructor(address _operatorAddress) Ownable() {
        operatorAddress = _operatorAddress;
    }

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                      REFERENCES                                                    
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Address of the Merkl contract managing rewards to be distributed
    /// @dev Address is the same across the different chains on which it is deployed
    function merklDistributionCreator() public view virtual returns (DistributionCreator) {
        return DistributionCreator(0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd);
    }

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                  EXTERNAL FUNCTIONS                                                
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Specifies the reward distribution parameters for `poolAddress`
    function setGauge(
        address poolAddress,
        address incentiveTokenAddress,
        DistributionParameters memory params
    ) external onlyByOwnerOperator {
        if (poolAddress == address(0) || incentiveTokenAddress == address(0)) revert InvalidParams();
        gaugeParams[poolAddress][incentiveTokenAddress] = params;
        emit GaugeSet(poolAddress, incentiveTokenAddress);
    }

    /// @notice Sets the operator of the contract
    function setOperator(address _operatorAddress) external onlyByOwnerOperator {
        operatorAddress = _operatorAddress;
    }

    /// @notice Function called by QuickSwap to stream rewards to `poolAddress`
    /// @dev Params for the incentivization of the pool must have been set prior to any call for
    /// a `(poolAddress,incentiveTokenAddress)` pair
    function incentivizePool(
        address [] calldata poolAddresses,
        address,
        address,
        address [] calldata incentiveTokenAddresses,
        uint256,
        uint256 [] calldata amounts
    ) external onlyByOwnerOperator {
        if (poolAddresses.length != incentiveTokenAddresses.length) revert InvalidParams();
        if (amounts.length != incentiveTokenAddresses.length) revert InvalidParams();
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            address incentiveTokenAddress = incentiveTokenAddresses[i];
            address poolAddress = poolAddresses[i];

            IERC20(incentiveTokenAddress).safeTransferFrom(msg.sender, address(this), amount);
            DistributionParameters memory params = gaugeParams[poolAddress][incentiveTokenAddress];
            if (params.uniV3Pool == address(0)) revert InvalidParams();
            DistributionCreator creator = merklDistributionCreator();
            // Minimum amount of incentive tokens to be distributed per hour
            uint256 minAmount = creator.rewardTokenMinAmounts(incentiveTokenAddress) * params.numEpoch;
            params.epochStart = uint32(block.timestamp);
            params.amount = amount;
            if (amount > 0) {
                if (amount > minAmount) {
                    _handleIncentiveTokenAllowance(IERC20(incentiveTokenAddress), address(creator), amount);
                    merklDistributionCreator().createDistribution(params);
                }
            }
        }
        
    }

    /// @notice Restores the allowance for the ANGLE token to the `DistributionCreator` contract
    function _handleIncentiveTokenAllowance(IERC20 incentiveTokenAddress, address spender, uint256 amount) internal {
        uint256 currentAllowance = incentiveTokenAddress.allowance(address(this), spender);
        if (currentAllowance < amount) incentiveTokenAddress.safeIncreaseAllowance(spender, amount - currentAllowance);
    }

    /// @notice Recover tokens sent to this contract
    function recoverTokens(address token) external onlyByOwnerOperator {
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(operatorAddress, amount);
    }
}