// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HelpMeshContext} from "./HelpMeshContext.sol";
import {ISponsorPool} from "./interfaces/ISponsorPool.sol";

/// @notice Donated balances with public rules. Deposits are irrevocable: owners cannot withdraw.
/// @dev Only the wired escrow can move funds out, and only back to itself. Refunds come back through {giveBack}.
contract SponsorPool is HelpMeshContext, ReentrancyGuard, ISponsorPool {
    using SafeERC20 for IERC20;

    struct Pool {
        address owner;
        address token;
        bytes32 rulesHash;
        uint128 maxPerRequest;
        uint128 balance;
        uint128 totalDeposited;
        uint128 totalDisbursed;
        bool paused;
    }

    mapping(uint64 poolId => Pool) public pools;
    mapping(uint64 poolId => mapping(address donor => uint256 amount)) public depositedBy;

    uint64 public nextPoolId;
    address public escrow;

    error UnknownPool();
    error NotPoolOwner();
    error NotEscrow();
    error BadRecipient();
    error EscrowAlreadySet();
    error ZeroAmount();
    error PoolIsPaused();
    error AmountTooHigh();
    error InsufficientPool();

    event PoolCreated(
        uint64 indexed poolId, address indexed owner, address token, bytes32 rulesHash, uint128 maxPerRequest
    );
    event Deposited(uint64 indexed poolId, address indexed donor, uint128 amount);
    event Drawn(uint64 indexed poolId, address indexed to, uint128 amount);
    event Returned(uint64 indexed poolId, uint128 amount);
    event RulesChanged(uint64 indexed poolId, bytes32 rulesHash);
    event MaxPerRequestSet(uint64 indexed poolId, uint128 maxPerRequest);
    event PoolPaused(uint64 indexed poolId, bool paused);
    event EscrowSet(address indexed escrow);

    constructor(address admin, address trustedForwarder) HelpMeshContext(admin, trustedForwarder) {}

    /// @notice One-time wiring. Admin cannot retarget this after deposits exist.
    function setEscrow(address escrow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (escrow != address(0)) revert EscrowAlreadySet();
        if (escrow_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        emit EscrowSet(escrow_);
    }

    function createPool(address token, bytes32 rulesHash, uint128 maxPerRequest) external returns (uint64 poolId) {
        if (token == address(0)) revert ZeroAddress();
        if (maxPerRequest == 0) revert ZeroAmount();
        poolId = ++nextPoolId;
        pools[poolId] = Pool({
            owner: _msgSender(),
            token: token,
            rulesHash: rulesHash,
            maxPerRequest: maxPerRequest,
            balance: 0,
            totalDeposited: 0,
            totalDisbursed: 0,
            paused: false
        });
        emit PoolCreated(poolId, _msgSender(), token, rulesHash, maxPerRequest);
    }

    /// @notice Irrevocable donation. The contract keeps the tokens until escrow draws them for an eligible request.
    function deposit(uint64 poolId, uint128 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Pool storage pool = pools[poolId];
        if (pool.owner == address(0)) revert UnknownPool();
        address donor = _msgSender();
        pool.balance += amount;
        pool.totalDeposited += amount;
        depositedBy[poolId][donor] += amount;
        IERC20(pool.token).safeTransferFrom(donor, address(this), amount);
        emit Deposited(poolId, donor, amount);
    }

    /// @inheritdoc ISponsorPool
    function draw(uint64 poolId, uint128 amount, address to) external nonReentrant {
        if (msg.sender != escrow) revert NotEscrow();
        if (to != msg.sender) revert BadRecipient();
        Pool storage pool = pools[poolId];
        if (pool.owner == address(0)) revert UnknownPool();
        if (pool.paused) revert PoolIsPaused();
        if (amount == 0) revert ZeroAmount();
        if (amount > pool.maxPerRequest) revert AmountTooHigh();
        if (amount > pool.balance) revert InsufficientPool();
        pool.balance -= amount;
        pool.totalDisbursed += amount;
        IERC20(pool.token).safeTransfer(to, amount);
        emit Drawn(poolId, to, amount);
    }

    /// @inheritdoc ISponsorPool
    function giveBack(uint64 poolId, uint128 amount) external nonReentrant {
        if (msg.sender != escrow) revert NotEscrow();
        Pool storage pool = pools[poolId];
        if (pool.owner == address(0)) revert UnknownPool();
        if (amount == 0) revert ZeroAmount();
        if (amount > pool.totalDisbursed) revert InsufficientPool();
        pool.balance += amount;
        pool.totalDisbursed -= amount;
        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount);
        emit Returned(poolId, amount);
    }

    function setRulesHash(uint64 poolId, bytes32 newHash) external {
        Pool storage pool = _onlyOwner(poolId);
        pool.rulesHash = newHash;
        emit RulesChanged(poolId, newHash);
    }

    function setMaxPerRequest(uint64 poolId, uint128 maxPerRequest) external {
        if (maxPerRequest == 0) revert ZeroAmount();
        Pool storage pool = _onlyOwner(poolId);
        pool.maxPerRequest = maxPerRequest;
        emit MaxPerRequestSet(poolId, maxPerRequest);
    }

    function setPaused(uint64 poolId, bool paused) external {
        Pool storage pool = _onlyOwner(poolId);
        pool.paused = paused;
        emit PoolPaused(poolId, paused);
    }

    function _onlyOwner(uint64 poolId) internal view returns (Pool storage pool) {
        pool = pools[poolId];
        if (pool.owner == address(0)) revert UnknownPool();
        if (_msgSender() != pool.owner) revert NotPoolOwner();
    }
}
