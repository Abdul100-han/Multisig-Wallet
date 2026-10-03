// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title MultiSigWallet
/// @notice M-of-N wallet. Owners submit calls, confirm or revoke them, and execute once the threshold is met.
/// @dev Execution uses checks-effects-interactions. `executed` is written before the external call so a
///      reentrant callback cannot run the same transaction a second time. That flag does not freeze other
///      wallet functions for the duration of the call.
contract MultiSigWallet {
    /// @notice Emitted when the wallet receives ETH.
    /// @param sender Payer.
    /// @param amount Wei received.
    /// @param balance Wallet balance after the transfer.
    event Deposit(address indexed sender, uint256 amount, uint256 balance);

    /// @notice Emitted when an owner submits a transaction.
    /// @param owner Submitter.
    /// @param txIndex Index assigned in `transactions`.
    /// @param to Call destination.
    /// @param value Wei forwarded with the call.
    /// @param data Calldata forwarded to `to`.
    event SubmitTransaction(
        address indexed owner,
        uint256 indexed txIndex,
        address indexed to,
        uint256 value,
        bytes data
    );

    /// @notice Emitted when an owner confirms a transaction.
    /// @param owner Confirming owner.
    /// @param txIndex Confirmed transaction index.
    event ConfirmTransaction(address indexed owner, uint256 indexed txIndex);

    /// @notice Emitted when an owner revokes a prior confirmation.
    /// @param owner Revoking owner.
    /// @param txIndex Transaction index.
    event RevokeConfirmation(address indexed owner, uint256 indexed txIndex);

    /// @notice Emitted after a transaction's external call succeeds.
    /// @param owner Owner who executed the transaction.
    /// @param txIndex Executed transaction index.
    event ExecuteTransaction(address indexed owner, uint256 indexed txIndex);

    /// @notice Caller is not an owner.
    error NotOwner();

    /// @notice No transaction is stored at `txIndex`.
    error TxDoesNotExist(uint256 txIndex);

    /// @notice Transaction was already executed.
    error TxAlreadyExecuted(uint256 txIndex);

    /// @notice Caller has already confirmed this transaction.
    error TxAlreadyConfirmed(uint256 txIndex);

    /// @notice Caller has no active confirmation to revoke.
    error TxNotConfirmed(uint256 txIndex);

    /// @notice Confirmation count is below the threshold required to execute.
    /// @param txIndex Transaction index.
    /// @param numConfirmations Confirmations currently recorded.
    /// @param numConfirmationsRequired Threshold configured at deployment.
    error CannotExecuteTx(uint256 txIndex, uint256 numConfirmations, uint256 numConfirmationsRequired);

    /// @notice The low-level call returned `success == false`.
    error TxFailed(uint256 txIndex);

    /// @notice An owner address was the zero address.
    error InvalidOwner();

    /// @notice The same owner was supplied more than once.
    error OwnerNotUnique();

    /// @notice Threshold was zero or greater than the number of owners.
    error InvalidRequirement(uint256 ownersCount, uint256 numConfirmationsRequired);

    /// @notice A stored call that owners confirm and then execute.
    /// @param to Destination of the call.
    /// @param value Wei sent with the call.
    /// @param data Calldata of the call.
    /// @param executed True after a successful execution is committed.
    /// @param numConfirmations Number of active owner confirmations.
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 numConfirmations;
    }

    /// @dev Owner set is fixed after construction. `getOwners` returns this list.
    address[] private owners;

    /// @notice True when `account` is an owner.
    mapping(address account => bool) public isOwner;

    /// @notice Minimum number of owner confirmations required before execution.
    uint256 public immutable numConfirmationsRequired;

    /// @dev Append-only transaction log. Dynamic `bytes` are exposed through `getTransaction`.
    Transaction[] private transactions;

    /// @notice Whether `owner` has an active confirmation on `txIndex`.
    mapping(uint256 txIndex => mapping(address owner => bool)) public isConfirmed;

    /// @dev Reverts unless `msg.sender` is an owner.
    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    /// @dev Reverts when `_txIndex` is outside `transactions`.
    modifier txExists(uint256 _txIndex) {
        if (_txIndex >= transactions.length) revert TxDoesNotExist(_txIndex);
        _;
    }

    /// @dev Reverts when the transaction has already been executed.
    modifier notExecuted(uint256 _txIndex) {
        if (transactions[_txIndex].executed) revert TxAlreadyExecuted(_txIndex);
        _;
    }

    /// @dev Reverts when `msg.sender` has already confirmed the transaction.
    modifier notConfirmed(uint256 _txIndex) {
        if (isConfirmed[_txIndex][msg.sender]) revert TxAlreadyConfirmed(_txIndex);
        _;
    }

    /// @notice Deploys a wallet with a fixed owner set and confirmation threshold.
    /// @param _owners Accounts permitted to submit, confirm, revoke, and execute. Duplicates and `address(0)` are rejected.
    /// @param _numConfirmationsRequired Confirmations required to execute. Must be in `1..=_owners.length`.
    constructor(address[] memory _owners, uint256 _numConfirmationsRequired) {
        uint256 ownersCount = _owners.length;
        if (_numConfirmationsRequired == 0 || _numConfirmationsRequired > ownersCount) {
            revert InvalidRequirement(ownersCount, _numConfirmationsRequired);
        }

        for (uint256 i; i < ownersCount;) {
            address owner = _owners[i];
            if (owner == address(0)) revert InvalidOwner();
            if (isOwner[owner]) revert OwnerNotUnique();

            isOwner[owner] = true;
            owners.push(owner);

            unchecked {
                ++i;
            }
        }

        numConfirmationsRequired = _numConfirmationsRequired;
    }

    /// @notice Accepts plain ETH transfers so the wallet can fund value calls.
    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    /// @notice Appends a transaction. It starts unexecuted and with zero confirmations.
    /// @dev `bytes calldata` matches the requested signature at the ABI level and avoids an extra memory copy before the storage write.
    /// @param _to Destination of the eventual call.
    /// @param _value Wei to forward. May be zero.
    /// @param _data Calldata to forward. May be empty.
    function submitTransaction(address _to, uint256 _value, bytes calldata _data) external onlyOwner {
        uint256 txIndex = transactions.length;
        transactions.push(
            Transaction({to: _to, value: _value, data: _data, executed: false, numConfirmations: 0})
        );

        emit SubmitTransaction(msg.sender, txIndex, _to, _value, _data);
    }

    /// @notice Records the caller's confirmation and increments the transaction's confirmation count.
    /// @param _txIndex Index of a pending transaction the caller has not yet confirmed.
    function confirmTransaction(uint256 _txIndex)
        external
        onlyOwner
        txExists(_txIndex)
        notExecuted(_txIndex)
        notConfirmed(_txIndex)
    {
        isConfirmed[_txIndex][msg.sender] = true;
        transactions[_txIndex].numConfirmations += 1;

        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    /// @notice Removes the caller's confirmation and decrements the transaction's confirmation count.
    /// @dev Reverts with `TxNotConfirmed` when the caller has no active confirmation.
    /// @param _txIndex Index of a pending transaction.
    function revokeConfirmation(uint256 _txIndex) external onlyOwner txExists(_txIndex) notExecuted(_txIndex) {
        if (!isConfirmed[_txIndex][msg.sender]) revert TxNotConfirmed(_txIndex);

        isConfirmed[_txIndex][msg.sender] = false;
        transactions[_txIndex].numConfirmations -= 1;

        emit RevokeConfirmation(msg.sender, _txIndex);
    }

    /// @notice Executes a pending transaction once `numConfirmations` reaches the threshold.
    /// @dev Checks-effects-interactions: `executed` is set before the call. A failed call reverts the whole
    ///      transaction, so the flag is only persisted when the call returns success. Returndata is discarded;
    ///      failure always reverts with `TxFailed`.
    /// @param _txIndex Index of a pending transaction with enough confirmations.
    function executeTransaction(uint256 _txIndex) external onlyOwner txExists(_txIndex) notExecuted(_txIndex) {
        Transaction storage transaction = transactions[_txIndex];
        uint256 confirmations = transaction.numConfirmations;
        uint256 required = numConfirmationsRequired;
        if (confirmations < required) {
            revert CannotExecuteTx(_txIndex, confirmations, required);
        }

        transaction.executed = true;

        (bool success,) = transaction.to.call{value: transaction.value}(transaction.data);
        if (!success) revert TxFailed(_txIndex);

        emit ExecuteTransaction(msg.sender, _txIndex);
    }

    /// @notice Returns the owner list in constructor order.
    /// @return Owner addresses.
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /// @notice Returns how many transactions have been submitted.
    /// @return Length of the transaction log.
    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    /// @notice Returns the stored fields of one transaction, including its calldata.
    /// @param _txIndex Transaction index. Reverts if it does not exist.
    /// @return to Call destination.
    /// @return value Wei forwarded with the call.
    /// @return data Calldata forwarded to `to`.
    /// @return executed Whether the transaction has been executed.
    /// @return numConfirmations Active confirmation count.
    function getTransaction(uint256 _txIndex)
        external
        view
        txExists(_txIndex)
        returns (address to, uint256 value, bytes memory data, bool executed, uint256 numConfirmations)
    {
        Transaction storage transaction = transactions[_txIndex];
        return (
            transaction.to, transaction.value, transaction.data, transaction.executed, transaction.numConfirmations
        );
    }
}
