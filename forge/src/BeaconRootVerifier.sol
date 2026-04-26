// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract BeaconRootVerifier {
    address constant BEACON_ROOTS = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;

    error BeaconRootMismatch();
    error BeaconRootCallFailed();

    function verify(uint64 timestamp, bytes32 expected) external view {
        (bool ok, bytes memory ret) = BEACON_ROOTS.staticcall(abi.encode(timestamp));
        if (!ok || ret.length != 32) revert BeaconRootCallFailed();
        bytes32 actual;
        assembly {
            actual := mload(add(ret, 32))
        }
        if (actual != expected) revert BeaconRootMismatch();
    }

    function verifyMany(uint64[] calldata timestamps, bytes32[] calldata expected) external view {
        uint256 n = timestamps.length;
        for (uint256 i = 0; i < n; ++i) {
            (bool ok, bytes memory ret) = BEACON_ROOTS.staticcall(abi.encode(timestamps[i]));
            if (!ok || ret.length != 32) revert BeaconRootCallFailed();
            bytes32 actual;
            assembly {
                actual := mload(add(ret, 32))
            }
            if (actual != expected[i]) revert BeaconRootMismatch();
        }
    }
}
