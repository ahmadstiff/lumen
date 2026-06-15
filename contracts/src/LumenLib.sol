// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  LumenLib
/// @notice Pure helper library for the Lumen agent-native payment skill.
/// @dev    Lumen is stateless by design: it never deploys custom payment
///         contracts. This library exists *solely* to produce deterministic
///         EIP-712 hashes and validate amount arithmetic. It holds no state,
///         emits no events, and is intended to be `using LumenLib for …` or
///         called via foundry tests / off-chain signature recovery.
///
///         All functions are `pure`. All revert reasons are constants so the
///         skill scripts can pattern-match them.
library LumenLib {
    // -------------------------------------------------------------------------
    // EIP-712 domain
    // -------------------------------------------------------------------------

    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId)")
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId)");

    /// @dev keccak256("Lumen")
    bytes32 internal constant LUMEN_NAME_HASH = keccak256(bytes("Lumen"));

    /// @dev keccak256("1")
    bytes32 internal constant LUMEN_VERSION_HASH = keccak256(bytes("1"));

    // -------------------------------------------------------------------------
    // Type hashes
    // -------------------------------------------------------------------------

    /// @dev keccak256(
    ///         "PaymentReceipt(string capability,address sender,address token,"
    ///         "address[] recipients,uint256[] amounts,bytes32 idempotencyKey,uint256 deadline)"
    ///       )
    bytes32 internal constant PAYMENT_RECEIPT_TYPEHASH =
        keccak256(
            "PaymentReceipt(string capability,address sender,address token,"
            "address[] recipients,uint256[] amounts,bytes32 idempotencyKey,uint256 deadline)"
        );

    /// @dev keccak256(
    ///         "Invoice(bytes32 invoiceId,address issuer,address payer,address token,"
    ///         "uint256 amount,uint256 dueAt,string memo)"
    ///       )
    bytes32 internal constant INVOICE_TYPEHASH =
        keccak256(
            "Invoice(bytes32 invoiceId,address issuer,address payer,address token,"
            "uint256 amount,uint256 dueAt,string memo)"
        );

    /// @dev keccak256(
    ///         "RecurringAuthorization(bytes32 planId,address subscriber,address merchant,"
    ///         "address token,uint256 amountPerPeriod,uint256 periodSeconds,uint256 startAt,"
    ///         "uint256 endAt,uint256 maxPeriods)"
    ///       )
    bytes32 internal constant RECURRING_AUTH_TYPEHASH =
        keccak256(
            "RecurringAuthorization(bytes32 planId,address subscriber,address merchant,"
            "address token,uint256 amountPerPeriod,uint256 periodSeconds,uint256 startAt,"
            "uint256 endAt,uint256 maxPeriods)"
        );

    /// @dev keccak256(
    ///         "EscrowOffer(bytes32 escrowId,address payer,address payee,address token,"
    ///         "uint256 amount,bytes32 releaseKeyHash,uint256 expiry,string memo)"
    ///       )
    /// @notice `releaseKeyHash` is keccak256(releaseKey). The payer reveals `releaseKey`
    ///         off-chain (via signed message or direct disclosure) to authorize the
    ///         payee's claim. Anyone with `releaseKey` such that keccak256(it) ==
    ///         releaseKeyHash can complete the escrow off-chain.
    bytes32 internal constant ESCROW_OFFER_TYPEHASH =
        keccak256(
            "EscrowOffer(bytes32 escrowId,address payer,address payee,address token,"
            "uint256 amount,bytes32 releaseKeyHash,uint256 expiry,string memo)"
        );

    /// @dev keccak256(
    ///         "TipClaim(bytes32 ticketId,address sender,address recipient,address token,"
    ///         "uint256 amount,uint256 expiry,string memo)"
    ///       )
    bytes32 internal constant TIP_CLAIM_TYPEHASH =
        keccak256(
            "TipClaim(bytes32 ticketId,address sender,address recipient,address token,"
            "uint256 amount,uint256 expiry,string memo)"
        );

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Basis-points denominator (10000 = 100%).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // -------------------------------------------------------------------------
    // Errors — match the error codes emitted by scripts/lib/common.sh.
    // -------------------------------------------------------------------------

    error LengthMismatch(uint256 recipientsLen, uint256 amountsLen);
    error EmptyRecipients();
    error SharesSumMismatch(uint256 actual, uint256 expected);
    error InvalidBps(uint256 bps);

    // -------------------------------------------------------------------------
    // Domain separator
    // -------------------------------------------------------------------------

    /// @notice Produces the EIP-712 domain separator for Lumen on `chainId`.
    /// @dev    Domain is intentionally `verifyingContract`-less so the same
    ///         signed payload is portable across Pharos networks for the
    ///         stateless capabilities (the chain id is what distinguishes them).
    function domainSeparator(uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, LUMEN_NAME_HASH, LUMEN_VERSION_HASH, chainId)
        );
    }

    // -------------------------------------------------------------------------
    // Payment receipt hash
    // -------------------------------------------------------------------------

    /// @notice EIP-712 digest for a Lumen payment receipt.
    /// @dev    The digest is the `signTypedData` value (0x1901 || domain || structHash).
    function receiptDigest(
        uint256 chainId,
        string memory capability,
        address sender,
        address token,
        address[] memory recipients,
        uint256[] memory amounts,
        bytes32 idempotencyKey,
        uint256 deadline
    ) internal pure returns (bytes32) {
        if (recipients.length != amounts.length) {
            revert LengthMismatch(recipients.length, amounts.length);
        }
        if (recipients.length == 0) revert EmptyRecipients();

        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_RECEIPT_TYPEHASH,
                keccak256(bytes(capability)),
                sender,
                token,
                keccak256(abi.encodePacked(recipients)),
                keccak256(abi.encodePacked(amounts)),
                idempotencyKey,
                deadline
            )
        );

        return _toTypedDataHash(domainSeparator(chainId), structHash);
    }

    // -------------------------------------------------------------------------
    // Invoice hash
    // -------------------------------------------------------------------------

    /// @notice EIP-712 digest for a Lumen invoice signed by the issuer.
    function invoiceDigest(
        uint256 chainId,
        bytes32 invoiceId,
        address issuer,
        address payer,
        address token,
        uint256 amount,
        uint256 dueAt,
        string memory memo
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                INVOICE_TYPEHASH, invoiceId, issuer, payer, token, amount, dueAt, keccak256(bytes(memo))
            )
        );
        return _toTypedDataHash(domainSeparator(chainId), structHash);
    }

    // -------------------------------------------------------------------------
    // Escrow + Tip digests
    // -------------------------------------------------------------------------

    /// @notice EIP-712 digest for an off-chain escrow offer signed by the payer.
    /// @dev    The payee redeems by revealing a `releaseKey` such that
    ///         keccak256(releaseKey) == releaseKeyHash, then can call the
    ///         payer's pre-approved transfer path. If `expiry` passes without
    ///         release, the payer reclaims (off-chain bookkeeping in Lumen).
    function escrowOfferDigest(
        uint256 chainId,
        bytes32 escrowId,
        address payer,
        address payee,
        address token,
        uint256 amount,
        bytes32 releaseKeyHash,
        uint256 expiry,
        string memory memo
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ESCROW_OFFER_TYPEHASH,
                escrowId,
                payer,
                payee,
                token,
                amount,
                releaseKeyHash,
                expiry,
                keccak256(bytes(memo))
            )
        );
        return _toTypedDataHash(domainSeparator(chainId), structHash);
    }

    /// @notice Verifies that `releaseKey` hashes to `releaseKeyHash`.
    /// @dev    Pure convenience used in both off-chain checks and tests.
    function releaseKeyMatches(bytes32 releaseKey, bytes32 releaseKeyHash)
        internal
        pure
        returns (bool)
    {
        return keccak256(abi.encode(releaseKey)) == releaseKeyHash;
    }

    /// @notice EIP-712 digest for an anonymous tip claim ticket.
    function tipClaimDigest(
        uint256 chainId,
        bytes32 ticketId,
        address sender,
        address recipient,
        address token,
        uint256 amount,
        uint256 expiry,
        string memory memo
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TIP_CLAIM_TYPEHASH,
                ticketId,
                sender,
                recipient,
                token,
                amount,
                expiry,
                keccak256(bytes(memo))
            )
        );
        return _toTypedDataHash(domainSeparator(chainId), structHash);
    }

    // -------------------------------------------------------------------------
    // Recurring authorization hash
    // -------------------------------------------------------------------------

    /// @notice EIP-712 digest for a recurring payment authorization.
    /// @dev    `maxPeriods == 0` means "open-ended until endAt".
    function recurringAuthDigest(
        uint256 chainId,
        bytes32 planId,
        address subscriber,
        address merchant,
        address token,
        uint256 amountPerPeriod,
        uint256 periodSeconds,
        uint256 startAt,
        uint256 endAt,
        uint256 maxPeriods
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                RECURRING_AUTH_TYPEHASH,
                planId,
                subscriber,
                merchant,
                token,
                amountPerPeriod,
                periodSeconds,
                startAt,
                endAt,
                maxPeriods
            )
        );
        return _toTypedDataHash(domainSeparator(chainId), structHash);
    }

    // -------------------------------------------------------------------------
    // Split-share math
    // -------------------------------------------------------------------------

    /// @notice Convert basis-point shares to absolute amounts that sum exactly
    ///         to `total`. The last recipient absorbs the rounding remainder
    ///         so `sum(out) == total` is invariant.
    /// @dev    Reverts if `shares.length == 0`, any share > BPS_DENOMINATOR,
    ///         or sum of shares != BPS_DENOMINATOR.
    function bpsToAmounts(uint256 total, uint256[] memory shares)
        internal
        pure
        returns (uint256[] memory amounts)
    {
        uint256 n = shares.length;
        if (n == 0) revert EmptyRecipients();

        amounts = new uint256[](n);
        uint256 runningSum;
        uint256 sharesSum;

        unchecked {
            // We bound n; the multiplications are checked.
            for (uint256 i = 0; i < n - 1; ++i) {
                if (shares[i] > BPS_DENOMINATOR) revert InvalidBps(shares[i]);
                sharesSum += shares[i];
                uint256 amt = (total * shares[i]) / BPS_DENOMINATOR;
                amounts[i] = amt;
                runningSum += amt;
            }
        }

        // Last share must close out the sum to 100% bps.
        if (shares[n - 1] > BPS_DENOMINATOR) revert InvalidBps(shares[n - 1]);
        uint256 finalSharesSum = sharesSum + shares[n - 1];
        if (finalSharesSum != BPS_DENOMINATOR) {
            revert SharesSumMismatch(finalSharesSum, BPS_DENOMINATOR);
        }

        // Last recipient gets the remainder so total is invariant.
        amounts[n - 1] = total - runningSum;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _toTypedDataHash(bytes32 separator, bytes32 structHash) private pure returns (bytes32) {
        // \x19\x01 prefix per EIP-712.
        return keccak256(abi.encodePacked(hex"1901", separator, structHash));
    }
}
