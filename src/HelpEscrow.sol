// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HelpMeshContext} from "./HelpMeshContext.sol";
import {IHelpAttestations} from "./interfaces/IHelpAttestations.sol";
import {ISponsorPool} from "./interfaces/ISponsorPool.sol";

/// @notice Locks a request reward until the requester confirms, the auto-release window passes, or an arbiter splits it.
/// @dev Pause blocks new funding only. Refunds, confirms, and payouts stay open so funds cannot be trapped.
///      No function sends escrowed tokens anywhere except the helper or the original funding source.
contract HelpEscrow is HelpMeshContext, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ELIGIBILITY_SIGNER_ROLE = keccak256("ELIGIBILITY_SIGNER_ROLE");
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint64 public constant MIN_AUTO_RELEASE_WINDOW = 1 hours;
    uint64 public constant MAX_AUTO_RELEASE_WINDOW = 30 days;
    uint64 public constant MIN_SESSION_DURATION = 1 hours;
    uint64 public constant MAX_SESSION_DURATION = 7 days;
    uint128 public constant ABSOLUTE_MAX_AMOUNT = 1_000_000e6;

    bytes32 public constant POOL_VOUCHER_TYPEHASH = keccak256(
        "PoolVoucher(uint64 poolId,bytes32 requestId,address requester,uint128 amount,uint64 openUntil,uint64 expiry)"
    );

    enum State {
        None,
        Open,
        Assigned,
        Started,
        Completed,
        Released,
        Refunded,
        Disputed,
        Resolved
    }

    enum Source {
        Requester,
        Pool
    }

    enum ReleaseBy {
        Confirm,
        AutoRelease
    }

    struct Escrow {
        address requester;
        address helper;
        address token;
        uint128 amount;
        Source source;
        uint64 poolId;
        State state;
        uint64 openUntil;
        uint64 startedAt;
        uint64 completedAt;
    }

    /// @notice `requestId` is the unique nonce. A voucher can fund a request only once.
    struct PoolVoucher {
        uint64 poolId;
        bytes32 requestId;
        address requester;
        uint128 amount;
        uint64 openUntil;
        uint64 expiry;
    }

    mapping(bytes32 requestId => Escrow) public escrows;
    mapping(address token => bool) public tokenAllowed;

    uint64 public autoReleaseWindow = 72 hours;
    uint64 public maxSessionDuration = 24 hours;
    uint128 public maxAmount;

    IHelpAttestations public immutable attestations;
    ISponsorPool public immutable sponsorPool;

    error NotRequester();
    error NotHelper();
    error NotParty();
    error BadState();
    error TokenNotAllowed();
    error AmountTooHigh();
    error ZeroAmount();
    error Expired();
    error TooEarly();
    error AlreadyExists();
    error SameParty();
    error InvalidSignature();
    error InvalidBps();
    error SessionActive();
    error UnknownPool();
    error PoolIsPaused();
    error InsufficientPool();
    error ParamOutOfBounds();

    event Funded(
        bytes32 indexed requestId,
        address indexed requester,
        address token,
        uint128 amount,
        Source source,
        uint64 poolId,
        uint64 openUntil
    );
    event HelperAssigned(bytes32 indexed requestId, address indexed helper);
    event AssignmentReleased(bytes32 indexed requestId);
    event Started(bytes32 indexed requestId);
    event Completed(bytes32 indexed requestId);
    event Released(bytes32 indexed requestId, address indexed helper, uint128 amount, ReleaseBy by);
    event Refunded(bytes32 indexed requestId, address indexed to, uint128 amount);
    event Disputed(bytes32 indexed requestId, address indexed by);
    event Resolved(bytes32 indexed requestId, uint128 helperAmount, uint128 refundAmount);
    event AutoReleaseWindowSet(uint64 window);
    event MaxSessionDurationSet(uint64 duration);
    event MaxAmountSet(uint128 maxAmount);
    event TokenAllowedSet(address indexed token, bool allowed);

    constructor(
        address admin,
        address trustedForwarder,
        IHelpAttestations attestations_,
        ISponsorPool sponsorPool_,
        uint128 maxAmount_
    ) HelpMeshContext(admin, trustedForwarder) EIP712("HelpEscrow", "1") {
        if (address(attestations_) == address(0) || address(sponsorPool_) == address(0)) {
            revert ZeroAddress();
        }
        if (maxAmount_ == 0 || maxAmount_ > ABSOLUTE_MAX_AMOUNT) revert ParamOutOfBounds();
        attestations = attestations_;
        sponsorPool = sponsorPool_;
        maxAmount = maxAmount_;
    }

    function setAutoReleaseWindow(uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (window < MIN_AUTO_RELEASE_WINDOW || window > MAX_AUTO_RELEASE_WINDOW) revert ParamOutOfBounds();
        autoReleaseWindow = window;
        emit AutoReleaseWindowSet(window);
    }

    function setMaxSessionDuration(uint64 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration < MIN_SESSION_DURATION || duration > MAX_SESSION_DURATION) revert ParamOutOfBounds();
        maxSessionDuration = duration;
        emit MaxSessionDurationSet(duration);
    }

    function setMaxAmount(uint128 maxAmount_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxAmount_ == 0 || maxAmount_ > ABSOLUTE_MAX_AMOUNT) revert ParamOutOfBounds();
        maxAmount = maxAmount_;
        emit MaxAmountSet(maxAmount_);
    }

    function setTokenAllowed(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        tokenAllowed[token] = allowed;
        emit TokenAllowedSet(token, allowed);
    }

    /// @notice Blocks new funding only. Exits stay available.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function fundFromRequester(bytes32 requestId, address token, uint128 amount, uint64 openUntil)
        external
        nonReentrant
        whenNotPaused
    {
        _fundFromRequester(requestId, token, amount, openUntil);
    }

    function fundFromRequesterWithPermit(
        bytes32 requestId,
        address token,
        uint128 amount,
        uint64 openUntil,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        IERC20Permit(token).permit(_msgSender(), address(this), amount, deadline, v, r, s);
        _fundFromRequester(requestId, token, amount, openUntil);
    }

    function fundFromPool(PoolVoucher calldata voucher, bytes calldata signature) external nonReentrant whenNotPaused {
        _verifyVoucher(voucher, signature);
        address token = _validatedPoolToken(voucher);
        _create(
            voucher.requestId, voucher.requester, token, voucher.amount, Source.Pool, voucher.poolId, voucher.openUntil
        );
        sponsorPool.draw(voucher.poolId, voucher.amount, address(this));
        emit Funded(
            voucher.requestId, voucher.requester, token, voucher.amount, Source.Pool, voucher.poolId, voucher.openUntil
        );
    }

    function assignHelper(bytes32 requestId, address helper) external nonReentrant onlyRole(OPERATOR_ROLE) {
        if (helper == address(0)) revert ZeroAddress();
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Open) revert BadState();
        if (block.timestamp > escrow.openUntil) revert Expired();
        if (helper == escrow.requester) revert SameParty();
        escrow.helper = helper;
        escrow.state = State.Assigned;
        emit HelperAssigned(requestId, helper);
    }

    function releaseAssignment(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Assigned) revert BadState();
        if (_msgSender() != escrow.helper) revert NotHelper();
        escrow.helper = address(0);
        escrow.state = State.Open;
        emit AssignmentReleased(requestId);
    }

    function start(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Assigned) revert BadState();
        if (_msgSender() != escrow.helper) revert NotHelper();
        escrow.startedAt = uint64(block.timestamp);
        escrow.state = State.Started;
        emit Started(requestId);
    }

    function complete(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Started) revert BadState();
        if (_msgSender() != escrow.helper) revert NotHelper();
        escrow.completedAt = uint64(block.timestamp);
        escrow.state = State.Completed;
        emit Completed(requestId);
    }

    function confirm(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Started && escrow.state != State.Completed) revert BadState();
        if (_msgSender() != escrow.requester) revert NotRequester();
        _release(requestId, ReleaseBy.Confirm);
    }

    function cancel(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = escrows[requestId];
        if (_msgSender() != escrow.requester) revert NotRequester();
        State state = escrow.state;
        if (state == State.Open || state == State.Assigned) {
            _refundAll(requestId);
        } else if (state == State.Started) {
            if (block.timestamp <= uint256(escrow.startedAt) + maxSessionDuration) revert SessionActive();
            _refundAll(requestId);
        } else {
            revert BadState();
        }
    }

    function expireOpen(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Open) revert BadState();
        if (block.timestamp <= escrow.openUntil) revert TooEarly();
        _refundAll(requestId);
    }

    function dispute(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Started && escrow.state != State.Completed) revert BadState();
        address caller = _msgSender();
        if (caller != escrow.requester && caller != escrow.helper) revert NotParty();
        escrow.state = State.Disputed;
        emit Disputed(requestId, caller);
    }

    /// @param helperBps Share of `amount` paid to the helper, from 0 to 10000. The remainder returns to the source.
    function resolve(bytes32 requestId, uint256 helperBps) external nonReentrant onlyRole(ARBITER_ROLE) {
        if (helperBps > 10_000) revert InvalidBps();
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Disputed) revert BadState();

        // helperAmount <= amount, and amount is uint128, so the result fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 helperAmount = uint128(uint256(escrow.amount) * helperBps / 10_000);
        uint128 refundAmount = escrow.amount - helperAmount;
        address helper = escrow.helper;
        escrow.state = State.Resolved;

        if (helperAmount > 0) IERC20(escrow.token).safeTransfer(helper, helperAmount);
        if (refundAmount > 0) _sendToSource(escrow, refundAmount);
        emit Resolved(requestId, helperAmount, refundAmount);
    }

    function autoRelease(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.Completed) revert BadState();
        if (block.timestamp < uint256(escrow.completedAt) + autoReleaseWindow) revert TooEarly();
        _release(requestId, ReleaseBy.AutoRelease);
    }

    function _msgSender() internal view override(Context, HelpMeshContext) returns (address) {
        return HelpMeshContext._msgSender();
    }

    function _msgData() internal view override(Context, HelpMeshContext) returns (bytes calldata) {
        return HelpMeshContext._msgData();
    }

    function _contextSuffixLength() internal view override(Context, HelpMeshContext) returns (uint256) {
        return HelpMeshContext._contextSuffixLength();
    }

    function hashPoolVoucher(PoolVoucher calldata voucher) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    POOL_VOUCHER_TYPEHASH,
                    voucher.poolId,
                    voucher.requestId,
                    voucher.requester,
                    voucher.amount,
                    voucher.openUntil,
                    voucher.expiry
                )
            )
        );
    }

    function _fundFromRequester(bytes32 requestId, address token, uint128 amount, uint64 openUntil) internal {
        address requester = _msgSender();
        if (!tokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert ZeroAmount();
        if (amount > maxAmount) revert AmountTooHigh();
        if (openUntil <= block.timestamp) revert Expired();
        _create(requestId, requester, token, amount, Source.Requester, 0, openUntil);
        IERC20(token).safeTransferFrom(requester, address(this), amount);
        emit Funded(requestId, requester, token, amount, Source.Requester, 0, openUntil);
    }

    function _verifyVoucher(PoolVoucher calldata voucher, bytes calldata signature) internal view {
        if (block.timestamp > voucher.expiry) revert Expired();
        (address recovered, ECDSA.RecoverError err, bytes32 errArg) =
            ECDSA.tryRecover(hashPoolVoucher(voucher), signature);
        // A successful recovery always reports a zero error argument. Length and malleability failures do not.
        if (err != ECDSA.RecoverError.NoError || errArg != bytes32(0) || !hasRole(ELIGIBILITY_SIGNER_ROLE, recovered)) {
            revert InvalidSignature();
        }
    }

    function _validatedPoolToken(PoolVoucher calldata voucher) internal view returns (address token) {
        if (voucher.requester == address(0)) revert ZeroAddress();
        if (voucher.amount == 0) revert ZeroAmount();
        if (voucher.amount > maxAmount) revert AmountTooHigh();
        if (voucher.openUntil <= block.timestamp) revert Expired();

        // rulesHash, totalDeposited, and totalDisbursed are public accounting. Spending checks are the fields below.
        // slither-disable-next-line unused-return
        (address owner, address poolToken,, uint128 maxPerRequest, uint128 balance,,, bool poolPaused) =
            sponsorPool.pools(voucher.poolId);

        if (owner == address(0)) revert UnknownPool();
        if (poolPaused) revert PoolIsPaused();
        if (!tokenAllowed[poolToken]) revert TokenNotAllowed();
        if (voucher.amount > maxPerRequest) revert AmountTooHigh();
        if (voucher.amount > balance) revert InsufficientPool();
        token = poolToken;
    }

    function _create(
        bytes32 requestId,
        address requester,
        address token,
        uint128 amount,
        Source source,
        uint64 poolId,
        uint64 openUntil
    ) internal {
        Escrow storage escrow = escrows[requestId];
        if (escrow.state != State.None) revert AlreadyExists();
        escrow.requester = requester;
        escrow.token = token;
        escrow.amount = amount;
        escrow.source = source;
        escrow.poolId = poolId;
        escrow.state = State.Open;
        escrow.openUntil = openUntil;
    }

    function _release(bytes32 requestId, ReleaseBy by) internal {
        Escrow storage escrow = escrows[requestId];
        address helper = escrow.helper;
        address requester = escrow.requester;
        uint128 amount = escrow.amount;
        address token = escrow.token;
        IHelpAttestations.Kind kind =
            escrow.source == Source.Pool ? IHelpAttestations.Kind.Sponsored : IHelpAttestations.Kind.Paid;
        escrow.state = State.Released;
        IERC20(token).safeTransfer(helper, amount);
        attestations.record(requestId, helper, requester, kind);
        emit Released(requestId, helper, amount, by);
    }

    function _refundAll(bytes32 requestId) internal {
        Escrow storage escrow = escrows[requestId];
        uint128 amount = escrow.amount;
        address to = escrow.source == Source.Pool ? address(sponsorPool) : escrow.requester;
        escrow.state = State.Refunded;
        _sendToSource(escrow, amount);
        emit Refunded(requestId, to, amount);
    }

    function _sendToSource(Escrow storage escrow, uint128 amount) internal {
        if (escrow.source == Source.Requester) {
            IERC20(escrow.token).safeTransfer(escrow.requester, amount);
        } else {
            IERC20(escrow.token).forceApprove(address(sponsorPool), amount);
            sponsorPool.giveBack(escrow.poolId, amount);
        }
    }
}
