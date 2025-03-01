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
    EIP1271_INVALID_SIGNATURE,
    EIP1271_VALID_SIGNATURE,
    SIG_VALIDATION_FAILED,
    SIG_VALIDATION_SUCCEEDED
} from "../../../../../common/Constants.sol";
import {UnauthorizedCaller} from "../../../../../common/Errors.sol";

import {BaseModule} from "../BaseModule.sol";
import {IModule} from "@erc6900/reference-implementation/interfaces/IModule.sol";
import {IValidationModule} from "@erc6900/reference-implementation/interfaces/IValidationModule.sol";

import {BaseERC712CompliantModule} from "../../../shared/erc712/BaseERC712CompliantModule.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import {IValidationModule} from "@erc6900/reference-implementation/interfaces/IValidationModule.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @notice This validation module allows the MSCA to be validated by a ECDSA secp256k1 curve signature or a 1271
 * signature.
 * `entityId` is required.
 */
contract SingleSignerValidationModule is IValidationModule, BaseModule, BaseERC712CompliantModule {
    using MessageHashUtils for bytes32;

    // A string in the format "vendor.module.semver". The vendor and module names MUST NOT contain a period character.
    string public constant MODULE_ID = "circle.single-signer-validation-module.1.0.0";
    // keccak256("circle.single-signer-validation-module.1.0.0")
    bytes32 private constant _HASHED_MODULE_ID = 0xb7a07c87bdb512080dfe47da0b1e70c517ba5218ba354e91def18b15077c58a4;
    // keccak256("1.0.0")
    bytes32 private constant _HASHED_MODULE_VERSION = 0x06c015bd22b4c69690933c1058878ebdfef31f9aaae40bbe86d8a09fe1b2972c;
    // keccak256("SingleSignerValidationMessage(bytes message)")
    bytes32 private constant _MODULE_TYPEHASH = 0x98b95f3602725ed42dccfe2fc6c94df5b37193d13336bd177cd68345785e4f47;
    // entityId => account => signer
    // this module supports composition that other validation can rely on entity id in this validation to validate
    // the signature
    // `account` is included in the parameter of validateRuntime/validateSignature or userOp.sender of validateUserOp
    mapping(uint32 entityId => mapping(address account => address)) public signers;

    event SignerTransferred(
        address indexed account, uint32 indexed entityId, address indexed newSigner, address previousSigner
    );

    /// @dev Transfers signer of the account validation to a new signer.
    /// @param entityId The entityId for the account and the signer.
    /// @param newSigner The address of the new signer.
    function transferSigner(uint32 entityId, address newSigner) external {
        _transferSigner(entityId, newSigner);
    }

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external override {
        if (data.length == 0) {
            // the caller already checks before calling into it, this is just a safety check
            return;
        }
        (uint32 entityId, address owner) = abi.decode(data, (uint32, address));
        _transferSigner(entityId, owner);
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata data) external override {
        if (data.length == 0) {
            // the caller already checks before calling into it, this is just a safety check
            return;
        }
        uint32 entityId = abi.decode(data, (uint32));
        _transferSigner(entityId, address(0));
    }

    /// @inheritdoc IValidationModule
    function validateUserOp(uint32 entityId, PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        view
        override
        returns (uint256 validationData)
    {
        if (
            SignatureChecker.isValidSignatureNow(
                signers[entityId][userOp.sender], userOpHash.toEthSignedMessageHash(), userOp.signature
            )
        ) {
            return SIG_VALIDATION_SUCCEEDED;
        }
        return SIG_VALIDATION_FAILED;
    }

    /// @inheritdoc IValidationModule
    function validateRuntime(
        address account,
        uint32 entityId,
        address sender,
        uint256 value,
        bytes calldata data,
        bytes calldata authorization
    ) external view override {
        (value, data, authorization);
        // the sender should be the signer of the account or itself
        if (sender == signers[entityId][account] || sender == account) {
            return;
        }
        revert UnauthorizedCaller();
    }

    /// @inheritdoc IValidationModule
    /// @notice Note that the hash is wrapped in an EIP-712 struct to prevent cross-account replay attacks. The
    /// replay-safe hash may be retrieved by calling the public function `getReplaySafeMessageHash`.
    function validateSignature(address account, uint32 entityId, address sender, bytes32 hash, bytes memory signature)
        external
        view
        override
        returns (bytes4)
    {
        (sender);
        bytes32 replaySafeHash = getReplaySafeMessageHash(account, hash);
        if (SignatureChecker.isValidSignatureNow(signers[entityId][account], replaySafeHash, signature)) {
            return EIP1271_VALID_SIGNATURE;
        }
        return EIP1271_INVALID_SIGNATURE;
    }

    /// @inheritdoc IModule
    function moduleId() external pure returns (string memory) {
        return MODULE_ID;
    }

    /// @inheritdoc BaseModule
    function supportsInterface(bytes4 interfaceId) public view override(BaseModule, IERC165) returns (bool) {
        return interfaceId == type(IValidationModule).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferSigner(uint32 entityId, address newOwner) internal {
        address oldOwner = signers[entityId][msg.sender];
        signers[entityId][msg.sender] = newOwner;
        emit SignerTransferred(msg.sender, entityId, newOwner, oldOwner);
    }

    /// @inheritdoc BaseERC712CompliantModule
    function _getModuleTypeHash() internal pure override returns (bytes32) {
        return _MODULE_TYPEHASH;
    }

    /// @inheritdoc BaseERC712CompliantModule
    function _getModuleNameHash() internal pure override returns (bytes32) {
        return _HASHED_MODULE_ID;
    }

    /// @inheritdoc BaseERC712CompliantModule
    function _getModuleVersionHash() internal pure override returns (bytes32) {
        return _HASHED_MODULE_VERSION;
    }
}
