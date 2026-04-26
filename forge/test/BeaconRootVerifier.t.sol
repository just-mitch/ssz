// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {BeaconRootVerifier} from "../src/BeaconRootVerifier.sol";

contract BeaconRootVerifierTest is Test {
    address constant BEACON_ROOTS = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;
    address constant SYSTEM_CALLER = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    // EIP-4788 deployed bytecode (from the EIP).
    bytes constant BEACON_ROOTS_CODE =
        hex"3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500";

    BeaconRootVerifier verifier;

    function setUp() public {
        vm.etch(BEACON_ROOTS, BEACON_ROOTS_CODE);
        verifier = new BeaconRootVerifier();
    }

    function _writeRoot(uint64 timestamp, bytes32 root) internal {
        vm.warp(timestamp);
        vm.prank(SYSTEM_CALLER);
        (bool ok,) = BEACON_ROOTS.call(abi.encode(root));
        require(ok, "system write failed");
    }

    function test_verifySingle_cold() public {
        uint64 ts = 1_700_000_000;
        bytes32 root = keccak256("beacon-root-1");
        _writeRoot(ts, root);

        // Measure cold call cost end-to-end (one verify).
        uint256 g0 = gasleft();
        verifier.verify(ts, root);
        uint256 used = g0 - gasleft();
        console.log("verify (cold) gas:", used);
    }

    function test_verifyMany_amortized() public {
        uint256 n = 10;
        uint64[] memory timestamps = new uint64[](n);
        bytes32[] memory roots = new bytes32[](n);

        // Write n distinct roots into the ring buffer.
        for (uint256 i = 0; i < n; ++i) {
            uint64 ts = uint64(1_700_000_000 + i * 12);
            bytes32 root = keccak256(abi.encode("root", i));
            _writeRoot(ts, root);
            timestamps[i] = ts;
            roots[i] = root;
        }

        uint256 g0 = gasleft();
        verifier.verifyMany(timestamps, roots);
        uint256 used = g0 - gasleft();
        console.log("verifyMany total gas:", used);
        console.log("verifyMany per-root gas:", used / n);
    }

    function test_verify_revertsOnMismatch() public {
        uint64 ts = 1_700_000_000;
        bytes32 root = keccak256("real");
        _writeRoot(ts, root);
        vm.expectRevert(BeaconRootVerifier.BeaconRootMismatch.selector);
        verifier.verify(ts, keccak256("fake"));
    }
}
