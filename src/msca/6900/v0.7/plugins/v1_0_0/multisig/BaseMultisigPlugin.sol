/*
 * Copyright 2024 Circle Internet Group, Inc. All rights reserved.

 * SPDX-License-Identifier: GPL-3.0-or-later

 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

pragma solidity 0.8.24;

import {
    EMPTY_HASH, SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCEEDED, ZERO
} from "../../../../../../common/Constants.sol";

import {MessageHashUtils} from "../../../../../../libs/MessageHashUtils.sol";
import {NotImplemented} from "../../../../shared/common/Errors.sol";
import {BasePlugin} from "../../BasePlugin.sol";
import {UserOperation} from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import {
    AssociatedLinkedListSet,
    AssociatedLinkedListSetLib
} from "@modular-account-libs/libraries/AssociatedLinkedListSetLib.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title Base Multisig Plugin
/// @author Circle
/// @notice Base contract for multisig plugins.
/// Functions implemented in this contract are forked with modifications from
/// https://github.com/alchemyplatform/multisig-plugin/blob/170ec0df78aa20248ab6f792540b4d4d4e0f752c/src/MultisigPlugin.sol
abstract contract BaseMultisigPlugin is BasePlugin {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using AssociatedLinkedListSetLib for AssociatedLinkedListSet;

    error EmptyOwnersNotAllowed();
    error InvalidAddress();
    error InvalidNumSigsOnActualDigest(uint256 invalidNum);
    error InvalidMaxFeePerGas();
    error InvalidMaxPriorityFeePerGas();
    error InvalidOwner(bytes30 owner);
    error InvalidPreVerificationGas();
    error InvalidSigLength();
    error InvalidSigOffset();
    error InvalidContractSigLength();
    error OwnerDoesNotExist(bytes30 owner);
    error TooManyOwners(uint256 currentNumOwners, uint256 numOwnersToAdd);
    error ZeroOwnersInputNotAllowed();
    error InvalidUserOpDigest();

    enum FunctionId {
        USER_OP_VALIDATION_OWNER // require owner access

    }

    // Linked list of account owners, in account address-associated storage
    AssociatedLinkedListSet internal _owners;

    address public immutable ENTRYPOINT;
    string internal constant ADD_OWNERS_PERMISSION = "Add Owners";
    string internal constant UPDATE_MULTISIG_WEIGHTS_PERMISSION = "Update Multisig Weights";
    string internal constant REMOVE_OWNERS_PERMISSION = "Remove Owners";

    constructor(address entryPoint) {
        ENTRYPOINT = entryPoint;
    }

    /// @notice Check if the signatures are valid for the account.
    /// @param actualDigest The actual gas digest.
    /// @param minimalDigest Digest of user op with minimal required fields set:
    /// (address sender, uint256 nonce, bytes initCode, bytes callData), and remaining
    /// fields set to default values.
    /// @param account The account to check the signatures for.
    /// @param signatures The signatures to check.
    /// @return success True if the signatures are valid.
    /// @return firstFailure first failure, if failed is true.
    /// (Note: if all signatures are individually valid but do not satisfy the
    /// multisig, firstFailure will be set to the last signature's index.)
    function checkNSignatures(bytes32 actualDigest, bytes32 minimalDigest, address account, bytes memory signatures)
        public
        view
        virtual
        returns (bool success, uint256 firstFailure);

    /// @inheritdoc BasePlugin
    function userOpValidationFunction(uint8 functionId, UserOperation calldata userOp, bytes32 userOpHash)
        external
        view
        override
        returns (uint256)
    {
        if (functionId == uint8(FunctionId.USER_OP_VALIDATION_OWNER)) {
            // UserOp.sig format:
            // 0-n: k signatures, each sig is 65 bytes each (so n = 65 * k)
            // n-: contract signatures if any
            bytes32 actualUserOpDigest = userOpHash.toEthSignedMessageHash();
            bytes32 minimalUserOpDigest = _getMinimalUserOpDigest(userOp).toEthSignedMessageHash();
            // actualUserOpDigest must differ from minimalUserOpDigest in userOp
            // when actualUserOpDigest != minimalUserOpDigest, numSigsOnActualDigest is set to one
            if (actualUserOpDigest == minimalUserOpDigest) {
                revert InvalidUserOpDigest();
            }
            (bool success,) = checkNSignatures(actualUserOpDigest, minimalUserOpDigest, msg.sender, userOp.signature);

            return success ? SIG_VALIDATION_SUCCEEDED : SIG_VALIDATION_FAILED;
        }

        revert NotImplemented(msg.sig, functionId);
    }

    /// @dev get the minimal user op digest
    /// (user op hash with gas fields or paymasterAndData set to default values.)
    /// @param userOp The user operation
    /// @return minimal user op hash
    function _getMinimalUserOpDigest(UserOperation calldata userOp) internal view returns (bytes32) {
        address sender;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            sender := calldataload(userOp)
        }
        uint256 nonce = userOp.nonce;
        bytes32 hashInitCode = _calldataKeccak(userOp.initCode);
        bytes32 hashCallData = _calldataKeccak(userOp.callData);

        bytes32 userOpHash = keccak256(
            abi.encode(
                sender,
                nonce,
                hashInitCode,
                hashCallData,
                ZERO, // callGasLimit = 0
                ZERO, // verificationGasLimit = 0
                ZERO, // preVerificationGas = 0
                ZERO, // maxFeePerGas = 0
                ZERO, // maxPriorityFeePerGas = 0
                EMPTY_HASH // paymasterAndData = keccak256('')
            )
        );

        return keccak256(abi.encode(userOpHash, ENTRYPOINT, block.chainid));
    }

    /// @param data calldata to hash
    function _calldataKeccak(bytes calldata data) internal pure returns (bytes32 ret) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let mem := mload(0x40)
            let len := data.length
            calldatacopy(mem, data.offset, len)
            ret := keccak256(mem, len)
        }
    }

    /// @notice Check if the account has initialized this plugin yet
    /// @param account The account to check
    /// @return True if the account has initialized this plugin
    function _isInitialized(address account) internal view virtual override returns (bool) {
        return !_owners.isEmpty(account);
    }

    /// @dev Helper function to get a 65 byte signature from a multi-signature
    /// @dev Functions using this must make sure signatures is long enough to contain
    /// the signature (65 * pos + 65 bytes.)
    /// @param signatures signatures to split
    /// @param pos position in signatures
    function _signatureSplit(bytes memory signatures, uint256 pos)
        internal
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let signaturePos := mul(0x41, pos)
            r := mload(add(signatures, add(signaturePos, 0x20)))
            s := mload(add(signatures, add(signaturePos, 0x40)))
            v := byte(0, mload(add(signatures, add(signaturePos, 0x60))))
        }
    }
}
