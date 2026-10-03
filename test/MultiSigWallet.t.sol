// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

/// @notice Recipient that accepts plain ETH transfers from the wallet.
contract EthReceiver {
    receive() external payable {}
}

/// @notice Foundry suite for MultiSigWallet submission, confirmation, revocation, and execution.
contract MultiSigWalletTest is Test {
    event Deposit(address indexed sender, uint256 amount, uint256 balance);
    event SubmitTransaction(
        address indexed owner, uint256 indexed txIndex, address indexed to, uint256 value, bytes data
    );
    event ConfirmTransaction(address indexed owner, uint256 indexed txIndex);
    event RevokeConfirmation(address indexed owner, uint256 indexed txIndex);
    event ExecuteTransaction(address indexed owner, uint256 indexed txIndex);

    uint256 internal constant THRESHOLD = 2;
    uint256 internal constant OWNER_BALANCE = 100 ether;
    uint256 internal constant WALLET_BALANCE = 50 ether;

    address internal owner1;
    address internal owner2;
    address internal owner3;
    address internal stranger;

    MultiSigWallet internal wallet;
    EthReceiver internal recipient;

    function setUp() public {
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        owner3 = makeAddr("owner3");
        stranger = makeAddr("stranger");

        vm.deal(owner1, OWNER_BALANCE);
        vm.deal(owner2, OWNER_BALANCE);
        vm.deal(owner3, OWNER_BALANCE);

        wallet = new MultiSigWallet(_owners(), THRESHOLD);
        vm.deal(address(wallet), WALLET_BALANCE);

        recipient = new EthReceiver();
    }

    function test_DeploymentState() public view {
        address[] memory owners = wallet.getOwners();

        assertEq(owners.length, 3);
        assertEq(owners[0], owner1);
        assertEq(owners[1], owner2);
        assertEq(owners[2], owner3);

        assertTrue(wallet.isOwner(owner1));
        assertTrue(wallet.isOwner(owner2));
        assertTrue(wallet.isOwner(owner3));
        assertFalse(wallet.isOwner(stranger));
        assertFalse(wallet.isOwner(address(0)));

        assertEq(wallet.numConfirmationsRequired(), THRESHOLD);
        assertEq(wallet.getTransactionCount(), 0);

        assertEq(owner1.balance, OWNER_BALANCE);
        assertEq(owner2.balance, OWNER_BALANCE);
        assertEq(owner3.balance, OWNER_BALANCE);
        assertEq(address(wallet).balance, WALLET_BALANCE);
    }

    function test_RevertIf_InvalidConstructorArgs() public {
        address[] memory owners = _owners();

        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidRequirement.selector, uint256(3), uint256(0)));
        new MultiSigWallet(owners, 0);

        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidRequirement.selector, uint256(3), uint256(4)));
        new MultiSigWallet(owners, 4);

        address[] memory emptyOwners = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidRequirement.selector, uint256(0), uint256(1)));
        new MultiSigWallet(emptyOwners, 1);

        owners[0] = address(0);
        vm.expectRevert(MultiSigWallet.InvalidOwner.selector);
        new MultiSigWallet(owners, THRESHOLD);

        owners[0] = owner1;
        owners[2] = owner1;
        vm.expectRevert(MultiSigWallet.OwnerNotUnique.selector);
        new MultiSigWallet(owners, THRESHOLD);
    }

    function test_Deposit() public {
        uint256 amount = 1 ether;
        uint256 balanceBefore = address(wallet).balance;

        vm.deal(address(this), amount);
        vm.expectEmit(true, false, false, true, address(wallet));
        emit Deposit(address(this), amount, balanceBefore + amount);

        (bool success,) = payable(address(wallet)).call{value: amount}("");

        assertTrue(success);
        assertEq(address(wallet).balance, balanceBefore + amount);
        assertEq(address(this).balance, 0);
    }

    function test_SubmitTransaction() public {
        uint256 value = 1 ether;
        bytes memory data = hex"aabbcc";
        uint256 txIndex = wallet.getTransactionCount();

        vm.expectEmit(true, true, true, true, address(wallet));
        emit SubmitTransaction(owner1, txIndex, address(recipient), value, data);

        vm.prank(owner1);
        wallet.submitTransaction(address(recipient), value, data);

        assertEq(wallet.getTransactionCount(), txIndex + 1);

        (address to, uint256 storedValue, bytes memory storedData, bool executed, uint256 numConfirmations) =
            wallet.getTransaction(txIndex);

        assertEq(to, address(recipient));
        assertEq(storedValue, value);
        assertEq(storedData, data);
        assertFalse(executed);
        assertEq(numConfirmations, 0);
        assertFalse(wallet.isConfirmed(txIndex, owner1));
    }

    function test_RevertIf_NonOwnerSubmits() public {
        uint256 countBefore = wallet.getTransactionCount();

        vm.expectRevert(MultiSigWallet.NotOwner.selector);
        vm.prank(stranger);
        wallet.submitTransaction(address(recipient), 1 ether, "");

        assertEq(wallet.getTransactionCount(), countBefore);
    }

    function test_ConfirmTransaction() public {
        uint256 txIndex = _submit(owner1, address(recipient), 1 ether, "");

        vm.expectEmit(true, true, false, true, address(wallet));
        emit ConfirmTransaction(owner1, txIndex);
        vm.prank(owner1);
        wallet.confirmTransaction(txIndex);

        assertTrue(wallet.isConfirmed(txIndex, owner1));
        assertFalse(wallet.isConfirmed(txIndex, owner2));
        (, , , bool executed, uint256 numConfirmations) = wallet.getTransaction(txIndex);
        assertFalse(executed);
        assertEq(numConfirmations, 1);

        vm.prank(owner2);
        wallet.confirmTransaction(txIndex);

        assertTrue(wallet.isConfirmed(txIndex, owner2));
        (, , , , numConfirmations) = wallet.getTransaction(txIndex);
        assertEq(numConfirmations, THRESHOLD);
    }

    function test_RevertIf_DoubleConfirm() public {
        uint256 txIndex = _submit(owner1, address(recipient), 1 ether, "");

        vm.prank(owner1);
        wallet.confirmTransaction(txIndex);

        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyConfirmed.selector, txIndex));
        vm.prank(owner1);
        wallet.confirmTransaction(txIndex);

        (, , , , uint256 numConfirmations) = wallet.getTransaction(txIndex);
        assertEq(numConfirmations, 1);
        assertTrue(wallet.isConfirmed(txIndex, owner1));
    }

    function test_RevokeConfirmation() public {
        uint256 txIndex = _submit(owner1, address(recipient), 1 ether, "");

        vm.prank(owner1);
        wallet.confirmTransaction(txIndex);
        vm.prank(owner2);
        wallet.confirmTransaction(txIndex);

        vm.expectEmit(true, true, false, true, address(wallet));
        emit RevokeConfirmation(owner1, txIndex);
        vm.prank(owner1);
        wallet.revokeConfirmation(txIndex);

        assertFalse(wallet.isConfirmed(txIndex, owner1));
        assertTrue(wallet.isConfirmed(txIndex, owner2));
        (, , , bool executed, uint256 numConfirmations) = wallet.getTransaction(txIndex);
        assertFalse(executed);
        assertEq(numConfirmations, 1);
    }

    function test_ExecuteTransaction_Success() public {
        uint256 value = 1 ether;
        uint256 walletBefore = address(wallet).balance;
        uint256 recipientBefore = address(recipient).balance;
        uint256 txIndex = _submit(owner1, address(recipient), value, "");

        vm.prank(owner1);
        wallet.confirmTransaction(txIndex);
        vm.prank(owner2);
        wallet.confirmTransaction(txIndex);

        vm.expectEmit(true, true, false, true, address(wallet));
        emit ExecuteTransaction(owner3, txIndex);
        vm.prank(owner3);
        wallet.executeTransaction(txIndex);

        (address to, uint256 storedValue, , bool executed, uint256 numConfirmations) = wallet.getTransaction(txIndex);
        assertEq(to, address(recipient));
        assertEq(storedValue, value);
        assertTrue(executed);
        assertEq(numConfirmations, THRESHOLD);
        assertEq(address(recipient).balance, recipientBefore + value);
        assertEq(address(wallet).balance, walletBefore - value);
    }

    function test_RevertIf_ExecutionWithoutEnoughConfirmations() public {
        uint256 txIndex = _submit(owner1, address(recipient), 1 ether, "");
        uint256 walletBefore = address(wallet).balance;
        uint256 recipientBefore = address(recipient).balance;

        vm.prank(owner1);
        wallet.confirmTransaction(txIndex);

        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.CannotExecuteTx.selector, txIndex, uint256(1), THRESHOLD)
        );
        vm.prank(owner2);
        wallet.executeTransaction(txIndex);

        (, , , bool executed, uint256 numConfirmations) = wallet.getTransaction(txIndex);
        assertFalse(executed);
        assertEq(numConfirmations, 1);
        assertEq(address(wallet).balance, walletBefore);
        assertEq(address(recipient).balance, recipientBefore);
    }

    function test_RevertIf_DoubleExecute() public {
        uint256 value = 1 ether;
        uint256 txIndex = _submit(owner1, address(recipient), value, "");
        _confirm(owner1, txIndex);
        _confirm(owner2, txIndex);

        vm.prank(owner1);
        wallet.executeTransaction(txIndex);

        uint256 walletAfter = address(wallet).balance;
        uint256 recipientAfter = address(recipient).balance;

        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyExecuted.selector, txIndex));
        vm.prank(owner2);
        wallet.executeTransaction(txIndex);

        (, , , bool executed,) = wallet.getTransaction(txIndex);
        assertTrue(executed);
        assertEq(address(wallet).balance, walletAfter);
        assertEq(address(recipient).balance, recipientAfter);
    }

    /// @dev Deposits `amount` wei, then sends that same amount out once the threshold is met.
    function testFuzz_DepositAndExecute(uint96 amount) public {
        uint256 value = uint256(amount);
        uint256 walletBefore = address(wallet).balance;
        uint256 recipientBefore = address(recipient).balance;

        vm.deal(address(this), value);
        (bool deposited,) = payable(address(wallet)).call{value: value}("");
        assertTrue(deposited);
        assertEq(address(wallet).balance, walletBefore + value);

        uint256 txIndex = _submit(owner1, address(recipient), value, "");
        _confirm(owner1, txIndex);
        _confirm(owner2, txIndex);

        vm.prank(owner3);
        wallet.executeTransaction(txIndex);

        (address to, uint256 storedValue, bytes memory data, bool executed, uint256 numConfirmations) =
            wallet.getTransaction(txIndex);

        assertEq(to, address(recipient));
        assertEq(storedValue, value);
        assertEq(data.length, 0);
        assertTrue(executed);
        assertEq(numConfirmations, THRESHOLD);
        assertEq(address(recipient).balance, recipientBefore + value);
        assertEq(address(wallet).balance, walletBefore);
    }

    function _owners() internal view returns (address[] memory owners) {
        owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;
    }

    function _submit(address owner, address to, uint256 value, bytes memory data) internal returns (uint256 txIndex) {
        txIndex = wallet.getTransactionCount();
        vm.prank(owner);
        wallet.submitTransaction(to, value, data);
    }

    function _confirm(address owner, uint256 txIndex) internal {
        vm.prank(owner);
        wallet.confirmTransaction(txIndex);
    }
}
