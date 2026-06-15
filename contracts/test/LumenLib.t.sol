// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LumenLib} from "lumen/LumenLib.sol";

/// @dev External wrapper so `vm.expectRevert` can observe library reverts at a
///      deeper call stack than the test contract itself.
contract LumenLibHarness {
    function bpsToAmounts(uint256 total, uint256[] memory shares) external pure returns (uint256[] memory) {
        return LumenLib.bpsToAmounts(total, shares);
    }

    function receiptDigest(
        uint256 chainId,
        string memory capability,
        address sender,
        address token,
        address[] memory recipients,
        uint256[] memory amounts,
        bytes32 idempotencyKey,
        uint256 deadline
    ) external pure returns (bytes32) {
        return LumenLib.receiptDigest(chainId, capability, sender, token, recipients, amounts, idempotencyKey, deadline);
    }
}

/// @title LumenLibTest
/// @notice Unit + fuzz tests for the stateless Lumen helper library.
///
/// Test strategy:
///   1. Domain separator changes only with chain id (sanity).
///   2. receiptDigest is deterministic and reverts on length mismatch / empty.
///   3. invoiceDigest is deterministic.
///   4. recurringAuthDigest is deterministic.
///   5. bpsToAmounts:
///        - reverts on empty / oversize bps / sum mismatch
///        - invariant: sum(out) == total for any total & valid shares
///        - last recipient absorbs remainder
contract LumenLibTest is Test {
    using LumenLib for uint256;

    uint256 internal constant ATLANTIC_CHAIN_ID = 688689;
    uint256 internal constant PACIFIC_CHAIN_ID = 1672;

    LumenLibHarness internal harness;

    function setUp() public {
        harness = new LumenLibHarness();
    }

    // -------------------------------------------------------------------------
    // Domain separator
    // -------------------------------------------------------------------------

    function test_domainSeparator_changesWithChainId() public pure {
        bytes32 atlantic = LumenLib.domainSeparator(ATLANTIC_CHAIN_ID);
        bytes32 pacific = LumenLib.domainSeparator(PACIFIC_CHAIN_ID);
        assertTrue(atlantic != bytes32(0), "separator must be non-zero");
        assertTrue(atlantic != pacific, "separators must differ across chains");
    }

    function test_domainSeparator_isDeterministic() public pure {
        bytes32 a = LumenLib.domainSeparator(ATLANTIC_CHAIN_ID);
        bytes32 b = LumenLib.domainSeparator(ATLANTIC_CHAIN_ID);
        assertEq(a, b, "domain separator must be pure");
    }

    // -------------------------------------------------------------------------
    // Receipt digest
    // -------------------------------------------------------------------------

    function _singletonRecipients(address r) internal pure returns (address[] memory rs) {
        rs = new address[](1);
        rs[0] = r;
    }

    function _singletonAmounts(uint256 a) internal pure returns (uint256[] memory as_) {
        as_ = new uint256[](1);
        as_[0] = a;
    }

    function test_receiptDigest_isDeterministic() public pure {
        address[] memory r = _singletonRecipients(address(0xBEEF));
        uint256[] memory a = _singletonAmounts(123);

        bytes32 d1 = LumenLib.receiptDigest(
            ATLANTIC_CHAIN_ID, "pay.once", address(0xCAFE), address(0xDEAD), r, a, bytes32("k"), 999
        );
        bytes32 d2 = LumenLib.receiptDigest(
            ATLANTIC_CHAIN_ID, "pay.once", address(0xCAFE), address(0xDEAD), r, a, bytes32("k"), 999
        );
        assertEq(d1, d2, "receipt digest must be pure");
    }

    function test_receiptDigest_changesWithCapability() public pure {
        address[] memory r = _singletonRecipients(address(0xBEEF));
        uint256[] memory a = _singletonAmounts(1);
        bytes32 d1 = LumenLib.receiptDigest(1, "pay.once", address(1), address(2), r, a, 0x0, 1);
        bytes32 d2 = LumenLib.receiptDigest(1, "pay.split", address(1), address(2), r, a, 0x0, 1);
        assertTrue(d1 != d2, "capability change must alter digest");
    }

    function test_receiptDigest_revertsOnLengthMismatch() public {
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(LumenLib.LengthMismatch.selector, 2, 1));
        harness.receiptDigest(1, "x", address(0), address(0), r, a, 0x0, 0);
    }

    function test_receiptDigest_revertsOnEmpty() public {
        address[] memory r = new address[](0);
        uint256[] memory a = new uint256[](0);
        vm.expectRevert(LumenLib.EmptyRecipients.selector);
        harness.receiptDigest(1, "x", address(0), address(0), r, a, 0x0, 0);
    }

    // -------------------------------------------------------------------------
    // Invoice digest
    // -------------------------------------------------------------------------

    function test_invoiceDigest_isDeterministic() public pure {
        bytes32 d1 = LumenLib.invoiceDigest(1, bytes32("inv-1"), address(1), address(2), address(3), 1000, 42, "memo");
        bytes32 d2 = LumenLib.invoiceDigest(1, bytes32("inv-1"), address(1), address(2), address(3), 1000, 42, "memo");
        assertEq(d1, d2);
    }

    function test_invoiceDigest_changesWithMemo() public pure {
        bytes32 d1 = LumenLib.invoiceDigest(1, bytes32("i"), address(1), address(2), address(3), 1, 1, "a");
        bytes32 d2 = LumenLib.invoiceDigest(1, bytes32("i"), address(1), address(2), address(3), 1, 1, "b");
        assertTrue(d1 != d2);
    }

    // -------------------------------------------------------------------------
    // Recurring auth digest
    // -------------------------------------------------------------------------

    function test_recurringAuthDigest_isDeterministic() public pure {
        bytes32 d1 = LumenLib.recurringAuthDigest(1, bytes32("p"), address(1), address(2), address(3), 100, 86400, 0, 0, 12);
        bytes32 d2 = LumenLib.recurringAuthDigest(1, bytes32("p"), address(1), address(2), address(3), 100, 86400, 0, 0, 12);
        assertEq(d1, d2);
    }

    // -------------------------------------------------------------------------
    // Escrow digest + release-key match
    // -------------------------------------------------------------------------

    function test_escrowOfferDigest_isDeterministic() public pure {
        bytes32 d1 = LumenLib.escrowOfferDigest(
            1, bytes32("e1"), address(1), address(2), address(3), 1000, bytes32("rkh"), 999, "deliver-q3"
        );
        bytes32 d2 = LumenLib.escrowOfferDigest(
            1, bytes32("e1"), address(1), address(2), address(3), 1000, bytes32("rkh"), 999, "deliver-q3"
        );
        assertEq(d1, d2);
    }

    function test_escrowOfferDigest_changesWithReleaseKeyHash() public pure {
        bytes32 d1 = LumenLib.escrowOfferDigest(
            1, bytes32("e"), address(1), address(2), address(3), 10, bytes32("a"), 1, "m"
        );
        bytes32 d2 = LumenLib.escrowOfferDigest(
            1, bytes32("e"), address(1), address(2), address(3), 10, bytes32("b"), 1, "m"
        );
        assertTrue(d1 != d2);
    }

    function test_releaseKeyMatches_acceptsCorrectKey() public pure {
        bytes32 key = keccak256("my-shared-secret");
        bytes32 hash = keccak256(abi.encode(key));
        assertTrue(LumenLib.releaseKeyMatches(key, hash));
    }

    function test_releaseKeyMatches_rejectsWrongKey() public pure {
        bytes32 key = keccak256("my-shared-secret");
        bytes32 hash = keccak256(abi.encode(key));
        bytes32 wrong = keccak256("other-secret");
        assertFalse(LumenLib.releaseKeyMatches(wrong, hash));
    }

    function testFuzz_releaseKeyMatches_isOneWay(bytes32 key) public pure {
        bytes32 hash = keccak256(abi.encode(key));
        assertTrue(LumenLib.releaseKeyMatches(key, hash));
    }

    // -------------------------------------------------------------------------
    // Tip claim digest
    // -------------------------------------------------------------------------

    function test_tipClaimDigest_isDeterministic() public pure {
        bytes32 d1 = LumenLib.tipClaimDigest(
            1, bytes32("t1"), address(1), address(2), address(3), 50, 999, "thanks"
        );
        bytes32 d2 = LumenLib.tipClaimDigest(
            1, bytes32("t1"), address(1), address(2), address(3), 50, 999, "thanks"
        );
        assertEq(d1, d2);
    }

    function test_tipClaimDigest_changesWithAmount() public pure {
        bytes32 d1 = LumenLib.tipClaimDigest(1, bytes32("t"), address(1), address(2), address(3), 10, 1, "m");
        bytes32 d2 = LumenLib.tipClaimDigest(1, bytes32("t"), address(1), address(2), address(3), 11, 1, "m");
        assertTrue(d1 != d2);
    }

    // -------------------------------------------------------------------------
    // bpsToAmounts — table tests
    // -------------------------------------------------------------------------

    function test_bpsToAmounts_singleRecipient_takesAll() public pure {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;
        uint256[] memory out = LumenLib.bpsToAmounts(1_000_000, shares);
        assertEq(out.length, 1);
        assertEq(out[0], 1_000_000);
    }

    function test_bpsToAmounts_halfHalf() public pure {
        uint256[] memory shares = new uint256[](2);
        shares[0] = 5_000;
        shares[1] = 5_000;
        uint256[] memory out = LumenLib.bpsToAmounts(1_000, shares);
        assertEq(out[0], 500);
        assertEq(out[1], 500);
    }

    function test_bpsToAmounts_remainderGoesToLast() public pure {
        // 3-way split of 100 wei at 3333/3333/3334 bps:
        // 100 * 3333 / 10000 = 33; 100 * 3333 / 10000 = 33; last = 100 - 66 = 34.
        uint256[] memory shares = new uint256[](3);
        shares[0] = 3_333;
        shares[1] = 3_333;
        shares[2] = 3_334;
        uint256[] memory out = LumenLib.bpsToAmounts(100, shares);
        assertEq(out[0], 33);
        assertEq(out[1], 33);
        assertEq(out[2], 34);
        assertEq(out[0] + out[1] + out[2], 100, "sum must equal total");
    }

    function test_bpsToAmounts_revertsOnEmpty() public {
        uint256[] memory shares = new uint256[](0);
        vm.expectRevert(LumenLib.EmptyRecipients.selector);
        harness.bpsToAmounts(100, shares);
    }

    function test_bpsToAmounts_revertsOnSumMismatch() public {
        uint256[] memory shares = new uint256[](2);
        shares[0] = 5_000;
        shares[1] = 4_999; // sum 9999, not 10000
        vm.expectRevert(abi.encodeWithSelector(LumenLib.SharesSumMismatch.selector, 9_999, 10_000));
        harness.bpsToAmounts(100, shares);
    }

    function test_bpsToAmounts_revertsOnOversizeShare() public {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_001;
        vm.expectRevert(abi.encodeWithSelector(LumenLib.InvalidBps.selector, 10_001));
        harness.bpsToAmounts(100, shares);
    }

    // -------------------------------------------------------------------------
    // bpsToAmounts — fuzz invariant: sum(out) == total
    // -------------------------------------------------------------------------

    function testFuzz_bpsToAmounts_sumInvariant(uint128 total, uint16 firstShareBps) public pure {
        // Bound firstShareBps to a valid range [0, 10000].
        uint256 first = uint256(firstShareBps) % (LumenLib.BPS_DENOMINATOR + 1);
        uint256 second = LumenLib.BPS_DENOMINATOR - first;

        uint256[] memory shares = new uint256[](2);
        shares[0] = first;
        shares[1] = second;

        uint256[] memory out = LumenLib.bpsToAmounts(total, shares);
        assertEq(out[0] + out[1], total, "split must preserve total");
    }

    function testFuzz_bpsToAmounts_threeWaySumInvariant(uint96 total, uint16 a, uint16 b) public pure {
        // Bound a, b so a+b in [0, 10000], then c = 10000 - a - b.
        uint256 av = uint256(a) % (LumenLib.BPS_DENOMINATOR + 1);
        uint256 bv = uint256(b) % (LumenLib.BPS_DENOMINATOR - av + 1);
        uint256 cv = LumenLib.BPS_DENOMINATOR - av - bv;

        uint256[] memory shares = new uint256[](3);
        shares[0] = av;
        shares[1] = bv;
        shares[2] = cv;

        uint256[] memory out = LumenLib.bpsToAmounts(total, shares);
        assertEq(out[0] + out[1] + out[2], total, "3-way split must preserve total");
    }
}
