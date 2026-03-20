// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ReactivePrimitives.sol";

contract ReactiveContract is ReactiveBase {
    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    address public immutable originContract;
    address public immutable callbackTarget;
    bytes32 public immutable monitoredPoolId;
    uint64 public immutable callbackGasLimit;
    uint256 public immutable emergencyAlertTopic;

    event EmergencyAlertObserved(bytes32 indexed poolId, string reason, uint256 detectedAt);
    event PauseCallbackTriggered(
        bytes32 indexed poolId,
        string reason,
        uint256 destinationChainId,
        address callbackTarget
    );

    constructor(
        address serviceAddress,
        uint256 originChainId_,
        uint256 destinationChainId_,
        address guardianHookAddress,
        bytes32 poolId,
        uint64 callbackGasLimit_
    ) payable ReactiveBase(serviceAddress) {
        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        originContract = guardianHookAddress;
        callbackTarget = guardianHookAddress;
        monitoredPoolId = poolId;
        callbackGasLimit = callbackGasLimit_;
        emergencyAlertTopic = uint256(keccak256("EmergencyAlert(bytes32,string,uint256)"));

        if (!vm) {
            service.subscribe(
                originChainId_,
                guardianHookAddress,
                emergencyAlertTopic,
                uint256(poolId),
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function react(LogRecord calldata log) external override vmOnly {
        if (
            log.chain_id != originChainId
                || log._contract != originContract
                || log.topic_0 != emergencyAlertTopic
                || bytes32(log.topic_1) != monitoredPoolId
        ) {
            return;
        }

        (string memory reason, uint256 detectedAt) = abi.decode(log.data, (string, uint256));
        emit EmergencyAlertObserved(monitoredPoolId, reason, detectedAt);

        bytes memory payload = abi.encodeWithSignature(
            "reactivePause(address,bytes32,string)", address(0), monitoredPoolId, reason
        );
        emit Callback(destinationChainId, callbackTarget, callbackGasLimit, payload);
        emit PauseCallbackTriggered(monitoredPoolId, reason, destinationChainId, callbackTarget);
    }
}
