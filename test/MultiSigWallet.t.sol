// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

contract EthReceiver {
    receive() external payable {}
}

contract RevertingTarget {
    error Boom();

    function fail() external pure {
        revert Boom();
    }
}

/// @dev Owner that tries to execute the same transaction again from inside `receive`.
contract ReenteringOwner {
    MultiSigWallet public wallet;
    uint256 public txIndex;
    bool public reenteredSuccessfully;

    function bind(MultiSigWallet _wallet) external {
        wallet = _wallet;
    }

    function setTxIndex(uint256 _txIndex) external {
        txIndex = _txIndex;
    }

    function confirm() external {
        wallet.confirmTransaction(txIndex);
    }

    receive() external payable {
        try wallet.executeTransaction(txIndex) {
            reenteredSuccessfully = true;
        } catch {
            reenteredSuccessfully = false;
        }
    }
}

contract MultiSigWalletTest is Test {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    MultiSigWallet internal wallet;

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = alice;
        owners[1] = bob;
        owners[2] = carol;
        wallet = new MultiSigWallet(owners, 2);
        vm.deal(address(wallet), 10 ether);
    }

    function testSubmitConfirmAndExecute() public {
        EthReceiver recipient = new EthReceiver();

        vm.prank(alice);
        wallet.submitTransaction(address(recipient), 1 ether, "");

        assertEq(wallet.getTransactionCount(), 1);
        (address to, uint256 value, bytes memory stored, bool executed, uint256 confirmations) = wallet.getTransaction(0);
        assertEq(to, address(recipient));
        assertEq(value, 1 ether);
        assertEq(stored.length, 0);
        assertFalse(executed);
        assertEq(confirmations, 0);

        vm.prank(alice);
        wallet.confirmTransaction(0);
        vm.prank(bob);
        wallet.confirmTransaction(0);

        (, , , executed, confirmations) = wallet.getTransaction(0);
        assertFalse(executed);
        assertEq(confirmations, 2);
        assertTrue(wallet.isConfirmed(0, alice));

        vm.prank(bob);
        wallet.executeTransaction(0);

        (, , , executed, confirmations) = wallet.getTransaction(0);
        assertTrue(executed);
        assertEq(confirmations, 2);
        assertEq(address(recipient).balance, 1 ether);
        assertEq(address(wallet).balance, 9 ether);
    }

    function testRevokeDropsBelowThreshold() public {
        vm.startPrank(alice);
        wallet.submitTransaction(bob, 0, "");
        wallet.confirmTransaction(0);
        vm.stopPrank();

        vm.prank(bob);
        wallet.confirmTransaction(0);

        vm.prank(alice);
        wallet.revokeConfirmation(0);

        assertFalse(wallet.isConfirmed(0, alice));
        (, , , , uint256 confirmations) = wallet.getTransaction(0);
        assertEq(confirmations, 1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.CannotExecuteTx.selector, uint256(0), uint256(1), uint256(2))
        );
        wallet.executeTransaction(0);
    }

    function testCannotExecuteBeforeThreshold() public {
        vm.startPrank(alice);
        wallet.submitTransaction(bob, 0, "");
        wallet.confirmTransaction(0);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.CannotExecuteTx.selector, uint256(0), uint256(1), uint256(2))
        );
        wallet.executeTransaction(0);
        vm.stopPrank();
    }

    function test_RevertWhen_CallFails() public {
        RevertingTarget target = new RevertingTarget();
        bytes memory data = abi.encodeWithSelector(RevertingTarget.fail.selector);

        vm.prank(alice);
        wallet.submitTransaction(address(target), 0, data);
        vm.prank(alice);
        wallet.confirmTransaction(0);
        vm.prank(bob);
        wallet.confirmTransaction(0);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxFailed.selector, uint256(0)));
        wallet.executeTransaction(0);

        (, , , bool executed,) = wallet.getTransaction(0);
        assertFalse(executed);
    }

    function testReentrancyCannotExecuteTwice() public {
        ReenteringOwner attacker = new ReenteringOwner();
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = address(attacker);
        MultiSigWallet guarded = new MultiSigWallet(owners, 2);
        attacker.bind(guarded);
        vm.deal(address(guarded), 2 ether);

        vm.prank(alice);
        guarded.submitTransaction(address(attacker), 1 ether, "");
        attacker.setTxIndex(0);

        vm.prank(alice);
        guarded.confirmTransaction(0);
        attacker.confirm();

        vm.prank(alice);
        guarded.executeTransaction(0);

        assertFalse(attacker.reenteredSuccessfully());
        assertEq(address(attacker).balance, 1 ether);
        (, , , bool executed,) = guarded.getTransaction(0);
        assertTrue(executed);
    }

    function testRevokeWithoutConfirmation() public {
        vm.prank(alice);
        wallet.submitTransaction(bob, 0, "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxNotConfirmed.selector, uint256(0)));
        wallet.revokeConfirmation(0);
    }

    function testNonOwnerCannotSubmit() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(MultiSigWallet.NotOwner.selector);
        wallet.submitTransaction(bob, 0, "");
    }

    function testGetOwners() public view {
        address[] memory owners = wallet.getOwners();
        assertEq(owners.length, 3);
        assertEq(owners[0], alice);
        assertEq(owners[1], bob);
        assertEq(owners[2], carol);
    }

    function testDuplicateConfirmReverts() public {
        vm.startPrank(alice);
        wallet.submitTransaction(bob, 0, "");
        wallet.confirmTransaction(0);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyConfirmed.selector, uint256(0)));
        wallet.confirmTransaction(0);
        vm.stopPrank();
    }

    function testConstructorRejectsBadThreshold() public {
        address[] memory owners = new address[](1);
        owners[0] = alice;
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidRequirement.selector, uint256(1), uint256(0)));
        new MultiSigWallet(owners, 0);
    }
}
