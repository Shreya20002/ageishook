// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPayable {
    function debt(address account) external view returns (uint256);

    receive() external payable;
}

interface IPayer {
    function pay(uint256 amount) external;

    receive() external payable;
}

interface ISubscriptionService {
    function subscribe(
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external;

    function unsubscribe(
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external;
}

interface ISystemContract is IPayable, ISubscriptionService {}

interface IReactive is IPayer {
    struct LogRecord {
        uint256 chain_id;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
        bytes data;
        uint256 block_number;
        uint256 op_code;
        uint256 block_hash;
        uint256 tx_hash;
        uint256 log_index;
    }

    event Callback(
        uint256 indexed chain_id,
        address indexed _contract,
        uint64 indexed gas_limit,
        bytes payload
    );

    function react(LogRecord calldata log) external;
}

abstract contract ReactiveBase is IReactive {
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    ISystemContract public immutable service;
    IPayable public immutable vendor;
    bool public immutable vm;

    mapping(address => bool) private authorizedSenders;

    modifier authorizedSenderOnly() {
        require(authorizedSenders[msg.sender], "Authorized sender only");
        _;
    }

    modifier vmOnly() {
        require(vm, "VM only");
        _;
    }

    modifier rnOnly() {
        require(!vm, "RN only");
        _;
    }

    constructor(address serviceAddress) {
        service = ISystemContract(payable(serviceAddress));
        vendor = IPayable(payable(serviceAddress));
        authorizedSenders[serviceAddress] = true;
        vm = serviceAddress.code.length == 0;
    }

    receive() external payable virtual {}

    function pay(uint256 amount) external authorizedSenderOnly {
        _pay(payable(msg.sender), amount);
    }

    function coverDebt() external {
        uint256 amount = vendor.debt(address(this));
        _pay(payable(address(vendor)), amount);
    }

    function isAuthorizedSender(address sender) external view returns (bool) {
        return authorizedSenders[sender];
    }

    function _authorizeSender(address sender) internal {
        authorizedSenders[sender] = true;
    }

    function _pay(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Insufficient funds");
        if (amount == 0) {
            return;
        }

        (bool success,) = recipient.call{value: amount}(new bytes(0));
        require(success, "Transfer failed");
    }
}
