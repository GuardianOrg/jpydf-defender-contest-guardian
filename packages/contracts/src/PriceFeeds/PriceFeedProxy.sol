// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import "../Interfaces/IPriceFeedProxy.sol";
import "../Interfaces/IBorrowerOperations.sol";
import "../Interfaces/IJpyUsdRateProvider.sol";
// Imported only to bind the gas-griefing guard selector to upstream at COMPILE time
// (see _bubbleIfGasError). No core file is modified by importing it.
import {MainnetPriceFeedBase} from "./MainnetPriceFeedBase.sol";

interface IJpyUsdRateProviderSource {
    function jpyUsdRateProvider() external view returns (IJpyUsdRateProvider);
}

/**
 * @title PriceFeedProxy
 * @notice Swappable-source price feed: a fixed reference address whose underlying price
 *         source is switchable behind a 12h timelock. NOT a UUPS / delegatecall / storage
 *         proxy and not upgradeable in the storage sense — "proxy" here means indirection.
 * @dev Allows switching between different price feed sources without redeploying
 *      the protocol. The DF protocol should reference this proxy address, never
 *      the underlying source directly.
 *
 *      Use Cases:
 *      - WBTC: Switch from WBTC oracle to CBTC oracle if WBTC has issues
 *      - USD stablecoins: Switch underlying (USDT → USDC) when business terms change
 *      - JPYC/dJPY: Switch from fixed feed to Chainlink when oracle becomes available
 *      - WETH: Switch oracle provider if Chainlink feed is deprecated
 *
 *      Oracle failure handling:
 *      - Underlying feeds call borrowerOperations.shutdownFromOracleFailure() directly.
 *        Since BorrowerOperations checks msg.sender == address(priceFeed) (this proxy),
 *        and the caller is the underlying feed, the call reverts.
 *      - This proxy catches that revert, calls shutdownFromOracleFailure() itself
 *        (as the registered priceFeed), and returns lastGoodPrice.
 *      - If the source is completely bricked, the proxy falls back to its own
 *        cached last-good price for the active consumer path to prevent permanent DoS.
 *      - Composite / multi-stage feeds must be reviewed per feed before being wrapped.
 *        The production `CompositePriceFeed` used by sUSDS intentionally exposes only the
 *        primary -> lastGoodPrice path. Do not reintroduce an upstream LST-style secondary
 *        mode behind this proxy without a dedicated route/source design review.
 *
 *      Source switching (timelocked, governance-transparent):
 *      - Source changes follow a two-step timelock: proposeSource() → wait
 *        TIMELOCK_DELAY → confirmSource(). The timelock guarantees the swap cannot
 *        happen without TIMELOCK_DELAY of public notice (SourceProposed emits the
 *        executable time); it does NOT by itself eliminate price-jump MEV at the
 *        confirmSource block. The normal confirm path rejects material jumps against
 *        the old source's live price, or the proxy's cached last-good prices when the
 *        old source is unhealthy. Incident recovery / placeholder activation can use
 *        confirmSourceEmergency() to bypass only that price-jump guard after the same
 *        timelock and new-source smoke tests.
 *      - confirmSource smoke-tests the new source, always re-initialises the normal cache,
 *        and re-initialises the redemption cache only from fresh JPY provenance. An aged
 *        source cannot replace that cache and any later fallback is returned with failure=true.
 *      - Owner can cancel a pending proposal at any time.
 *
 *      Ownership:
 *      - Inherits OpenZeppelin Ownable2Step (v4.9.5). 2-step transfer
 *        (transferOwnership + acceptOwnership) prevents accidental loss of
 *        ownership via typos. The new owner must actively call acceptOwnership()
 *        to finalise the transfer.
 *      - Renounce is disabled. The source-swap authority is the only recovery path
 *        from future feed deprecation, placeholder activation, and shared JPY/USD
 *        oracle incidents, so ownership must be transferred to a governance /
 *        multisig address rather than burned.
 */
contract PriceFeedProxy is IPriceFeedProxy, Ownable2Step {
    // --- Constants ---

    /// @notice Minimum delay before a proposed source can be confirmed.
    uint256 public constant TIMELOCK_DELAY = 12 hours;
    uint256 public constant MAX_NORMAL_REDEMPTION_JPY_AGE = 30 hours;
    uint256 public constant MAX_SOURCE_SWITCH_DEVIATION_BPS = 100; // 1%
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint8 private constant JPY_PROVENANCE_INVALID = 0;
    uint8 private constant JPY_PROVENANCE_FRESH = 1;
    uint8 private constant JPY_PROVENANCE_AGED = 2;
    uint256 private constant JPY_PROVENANCE_GAS_STIPEND = 30_000;

    // --- State ---

    address public source;
    IBorrowerOperations public immutable borrowerOperations;

    /// @dev Proxy-level fallback price for the normal borrow/liquidation path.
    ///      Used if the source is completely bricked and lastGoodPrice() reverts.
    uint256 private _lastGoodPrice;
    /// @dev Proxy-level fallback price for the redemption path. Some sources intentionally
    ///      serve a distinct redemption price, so a bricked source must not collapse back to
    ///      the normal-path cache.
    uint256 private _lastGoodRedemptionPrice;

    // --- Timelock state ---
    address public proposedSource;
    uint256 public sourceProposedAt;

    struct SourceRead {
        bool healthy;
        bool redemptionPriceCacheable;
        uint256 price;
        uint256 redemptionPrice;
        uint256 urgentRedemptionPrice;
    }

    /**
     * @param _initialSource Initial price feed source address
     * @param _ownerAddress Owner address (typically deployer, then transferred to governance)
     * @param _borrowerOperations BorrowerOperations address for this collateral branch
     */
    constructor(address _initialSource, address _ownerAddress, address _borrowerOperations) {
        // Source must be a deployed contract. address(0) or an EOA would make
        // fetchPrice()/fetchRedemptionPrice() revert via Solidity's code-existence check
        // (which the try/catch in those functions does NOT catch), bricking redemption
        // system-wide since CollateralRegistry.redeemCollateral reads every branch unguarded.
        //
        // Scope of THIS guard (code.length): it blocks ONLY non-contract sources
        // (address(0) / EOA). It is not the full validity check — further screens run below:
        //   - a direct source exposing the PriceFeedProxy `source()` getter marker is rejected.
        //     This is a shallow type screen only; semantic forwarding and dependency cycles
        //     remain part of deployment and timelocked source-change review;
        //   - a deployed source that reverts on a cache-backed normal/redemption fetch is
        //     intentionally allowed: the F-01 warm just below uses the lastGoodPrice() view,
        //     and those runtime paths catch the revert and fall back to lastGoodPrice. The
        //     cache-free urgent fetch must succeed in the C-2 smoke-test below;
        //   - a deployed source that returns *mis-encoded* (wrong-ABI) data, an invalid (0/max)
        //     price, or a failure-flagged (oracleFailure==true) result is rejected — not here,
        //     but by the C-2 smoke-test at the end of this constructor (a wrong-ABI decode
        //     failure pierces try/catch; an invalid/failure-flagged success return is rejected
        //     explicitly), so it can never be set as an initial source that would brick or shut
        //     down the branch on its first fetch. A merely-reverting normal/redemption path is
        //     still tolerated there, while an urgent-path revert is rejected.
        // What stays the owner's responsibility (operationally, via Ownable2Step + the 12h
        // source-swap timelock — no on-chain check can verify it) is the source's *semantic*
        // honesty: returning a truthful, correctly-scaled price.
        if (_initialSource.code.length == 0) revert InvalidSource();
        if (_ownerAddress == address(0)) revert ZeroOwnerAddress();
        if (_borrowerOperations == address(0)) revert InvalidAddress();
        if (_isPriceFeedProxy(_initialSource)) revert InvalidSource();

        // Ownable's constructor already set owner to deployer; re-target to the
        // desired initial owner. Emits a second OwnershipTransferred event.
        _transferOwnership(_ownerAddress);

        source = _initialSource;
        borrowerOperations = IBorrowerOperations(_borrowerOperations);

        // F-01: warm the proxy-level cache from the initial source and reject a source that
        // cannot serve a valid (non-zero) price. lastGoodPrice() (a view) is used rather than
        // fetchPrice() so a source whose *live* fetch may revert — intentionally tolerated at
        // runtime by the try/catch in fetchPrice() — is still constructible (see
        // PriceFeedProxySourceValidation.t.sol), while a zero / bricked source is rejected at
        // deploy (fail-closed) instead of silently returning 0 to a downstream divisor
        // (TroveManager redemption divides jpydfLot by the redemption price).
        uint256 initialRedemptionPrice;
        try IPriceFeed(_initialSource).lastGoodPrice() returns (uint256 initPrice) {
            if (_isInvalidPrice(initPrice)) revert InvalidSource();
            _lastGoodPrice = initPrice;
            initialRedemptionPrice = initPrice;
        } catch {
            revert InvalidSource();
        }

        // C-2: smoke-test all fetch entrypoints the protocol reads with no try/catch (fetchPrice
        // via getUnbackedPortion...; fetchRedemptionPrice via RedemptionHelper / TroveManager
        // redemption math), and validate the SUCCESS-path result fail-closed — exactly as
        // confirmSource does at switch time. On a decodable, non-reverting return, reject a 0/max
        // sentinel OR an oracleFailure==true flag with InvalidSource. That revert fires inside the
        // success body which — like a return-data decode failure — is not caught by these external
        // call catches and so reverts the constructor. This rejects, at DEPLOY, an initial source
        // that is already failing or would serve an invalid price, instead of letting the branch
        // shut itself down (or, under a deploy miswire, stay live on a frozen price) on its first
        // fetch.
        //
        // Still tolerated (empty catch) for the cache-backed normal and redemption paths: a source
        // whose live fetch reverts can be served from the F-01 cache at runtime. Urgent redemption
        // has no cache by design, so its probe must succeed at construction. A wrong-ABI source's
        // decode failure still pierces try/catch and reverts here.
        try IPriceFeed(_initialSource).fetchPrice() returns (uint256 fp, bool fpFailure) {
            if (_isInvalidPrice(fp) || fpFailure) revert InvalidSource();
            _lastGoodPrice = fp;
        } catch {}
        try IPriceFeed(_initialSource).fetchRedemptionPrice() returns (uint256 rp, bool rpFailure) {
            if (_isInvalidPrice(rp) || rpFailure) revert InvalidSource();
            initialRedemptionPrice = rp;
        } catch {}
        try IPriceFeed(_initialSource).fetchUrgentRedemptionPrice() returns (uint256 up, bool upFailure) {
            if (_isInvalidPrice(up) || upFailure) revert InvalidSource();
        } catch (bytes memory err) {
            _bubbleIfGasError(err);
            revert InvalidSource();
        }

        if (_normalRedemptionJpyStatus(_initialSource) != JPY_PROVENANCE_FRESH) revert InvalidSource();
        _lastGoodRedemptionPrice = initialRedemptionPrice;

        emit SourceUpdated(address(0), _initialSource);
    }

    // =========================================================
    //  Price feed delegation
    // =========================================================

    /// @inheritdoc IPriceFeed
    function fetchPrice() external returns (uint256, bool) {
        try IPriceFeed(source).fetchPrice() returns (uint256 price, bool oracleFailure) {
            // A source-signalled failure follows the same temporary shutdown path as a revert.
            if (_isInvalidPrice(price) || oracleFailure) return _handleFailedFetch(false);
            _lastGoodPrice = price;
            // A recovered live normal price may be used before owner resume for liquidation,
            // the TCR<SCR check, and risk-reducing borrower adjustments. Risk increases and
            // normal redemption remain gated by the latched shutdown flag.
            return (price, false);
        } catch (bytes memory err) {
            _bubbleIfGasError(err);
            return _handleFailedFetch(false);
        }
    }

    /// @inheritdoc IPriceFeed
    function fetchRedemptionPrice() external returns (uint256, bool) {
        try IPriceFeed(source).fetchRedemptionPrice() returns (uint256 price, bool oracleFailure) {
            // F-02: see fetchPrice(). Route a failure-flagged-but-valid price through shutdown too.
            if (_isInvalidPrice(price) || oracleFailure) return _handleFailedFetch(true);

            // Stop only normal redemption once the shared JPY/USD round reaches 30h old.
            // The source call comes first so the first fresh round refreshes provenance and
            // reopens redemption automatically. This local gate deliberately does not invoke
            // _handleFailedFetch: borrowing, liquidation and urgent redemption remain unchanged.
            if (_normalRedemptionJpyStatus(source) != JPY_PROVENANCE_FRESH) return (price, true);

            _lastGoodRedemptionPrice = price;
            // A latched BO pause keeps normal redemption closed until the owner validates all
            // three price paths; the JPY-age gate above independently requires fresh provenance.
            return (price, borrowerOperations.isOracleFailureShutdown());
        } catch (bytes memory err) {
            _bubbleIfGasError(err);
            return _handleFailedFetch(true);
        }
    }

    /// @inheritdoc IPriceFeed
    function fetchUrgentRedemptionPrice() external returns (uint256, bool) {
        try IPriceFeed(source).fetchUrgentRedemptionPrice() returns (uint256 price, bool oracleFailure) {
            // Wind-down must never settle against a normal-path cache. There is deliberately
            // no third cache: only a source-policy-valid urgent quote is accepted.
            if (_isInvalidPrice(price) || oracleFailure) revert UrgentRedemptionPriceUnavailable(source);
            return (price, false);
        } catch (bytes memory err) {
            _bubbleIfGasError(err);
            revert UrgentRedemptionPriceUnavailable(source);
        }
    }

    /**
     * @dev Handles the case where the underlying feed reverted or returned an invalid price.
     *      Triggers temporary oracle-failure shutdown, then tries to read lastGoodPrice from the source.
     *      For the normal path, a valid source.lastGoodPrice() can refresh the proxy cache.
     *      For the redemption path, lastGoodPrice() is not path-specific, so the proxy only
     *      serves its own last known redemption price. This prevents a failing source with
     *      intentionally distinct normal/redemption prices from collapsing redemption math to
     *      the normal-path cache.
     */
    function _handleFailedFetch(bool _isRedemption) internal returns (uint256, bool) {
        // L-2: surface proxy-level fail-safe activation for monitoring (the source failed and
        // the proxy is taking over shutdown + fallback). Emitted on the failure path only.
        emit SourceFailureHandled(source);

        // shutdownFromOracleFailure reverts ONLY on caller-mismatch (this proxy is not the
        // branch's registered priceFeed = a deploy miswire); it is a no-op when already shut
        // down, so in correct wiring it never reverts. We do NOT propagate (that would let one
        // failing branch DoS the system-wide redemption loop) -- instead we serve lastGoodPrice
        // and raise ShutdownCallReverted so a miswired branch on a frozen price is observable.
        try borrowerOperations.shutdownFromOracleFailure() {}
        catch {
            emit ShutdownCallReverted(address(borrowerOperations), source);
        }

        if (_isRedemption) {
            return (_lastGoodRedemptionPrice, true);
        }

        // Try to read lastGoodPrice from source; fall back to proxy cache if bricked.
        // Reject 0 AND type(uint256).max (via _isInvalidPrice, not a bare > 0): an invalid
        // sentinel from a misbehaving source must never be cached or served, because
        // redemption/liquidation ignore the failure bool and would consume it directly.
        try IPriceFeed(source).lastGoodPrice() returns (uint256 sourceLastGood) {
            if (!_isInvalidPrice(sourceLastGood)) {
                _lastGoodPrice = sourceLastGood;
                return (sourceLastGood, true);
            }
        } catch {}

        return (_lastGoodPrice, true);
    }

    /// @inheritdoc IPriceFeedProxy
    function resumeFromOracleFailure() external onlyOwner {
        if (!borrowerOperations.isOracleFailureShutdown()) revert OracleFailureShutdownNotActive();

        SourceRead memory read = _readSourceIfHealthy(source);
        if (!read.healthy) revert SourceNotHealthy();

        _lastGoodPrice = read.price;
        if (read.redemptionPriceCacheable) _lastGoodRedemptionPrice = read.redemptionPrice;
        borrowerOperations.resumeFromOracleFailure();

        emit OracleFailureShutdownResumed(source, read.price, read.redemptionPrice);
    }

    /**
     * @dev Returns true if price is zero or max uint256 (sentinel/invalid values).
     */
    function _isInvalidPrice(uint256 _price) internal pure returns (bool) {
        return _price == 0 || _price == type(uint256).max;
    }

    /// @dev Re-revert the underlying gas-griefing guard unchanged; otherwise a
    ///      gas-starved call would be misclassified as an oracle failure.
    function _bubbleIfGasError(bytes memory _err) private pure {
        if (_err.length == 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(_err, 0x20))
            }
            // F-04: bind to upstream's selector at COMPILE time. If upstream renames or removes
            // this error, this file fails to compile (instead of silently misclassifying a
            // gas-starved call as an oracle failure and forcing an unnecessary shutdown).
            if (sel == MainnetPriceFeedBase.InsufficientGasForExternalCall.selector) {
                assembly {
                    revert(add(_err, 0x20), mload(_err))
                }
            }
        }
    }

    /// @inheritdoc IPriceFeed
    function lastGoodPrice() external view returns (uint256) {
        try IPriceFeed(source).lastGoodPrice() returns (uint256 sourceLastGood) {
            // Reject 0 AND type(uint256).max, mirroring _handleFailedFetch / fetchPrice.
            if (!_isInvalidPrice(sourceLastGood)) return sourceLastGood;
        } catch {}
        return _lastGoodPrice;
    }

    // =========================================================
    //  Timelocked source switching
    //  (timelock guarantees 12h public notice; it does NOT by itself eliminate price-jump
    //   MEV at the confirmSource block — submit confirmSource privately when prices may differ)
    // =========================================================

    /// @inheritdoc IPriceFeedProxy
    function proposeSource(address _newSource) external onlyOwner {
        // Reject non-contract sources (address(0) / EOA): a no-code source makes the
        // proxy's fetch revert un-catchably and DoS all redemptions. A source exposing the
        // PriceFeedProxy `source()` marker is also rejected as a shallow direct-proxy screen.
        // It does not traverse semantic forwarding or prove dependency-graph acyclicity; those
        // checks remain the owner's responsibility under the timelock (see constructor note).
        if (_newSource.code.length == 0) revert InvalidSource();
        if (_newSource == source) revert SameSource();
        if (_isPriceFeedProxy(_newSource)) revert InvalidSource();

        // If overwriting a pending proposal, emit cancellation for the old one
        if (proposedSource != address(0)) {
            emit SourceProposalCancelled(proposedSource);
        }

        proposedSource = _newSource;
        sourceProposedAt = block.timestamp;

        emit SourceProposed(_newSource, block.timestamp + TIMELOCK_DELAY);
    }

    /// @inheritdoc IPriceFeedProxy
    function confirmSource() external onlyOwner {
        _confirmSource(false);
    }

    /// @inheritdoc IPriceFeedProxy
    function confirmSourceEmergency() external onlyOwner {
        _confirmSource(true);
    }

    function _confirmSource(bool _bypassPriceGuard) internal {
        if (proposedSource == address(0)) revert NoProposalPending();
        if (block.timestamp < sourceProposedAt + TIMELOCK_DELAY) revert TimelockNotElapsed();
        // Defense-in-depth: re-check at execution time that the proposed source still has
        // code (it could have been removed between proposal and confirmation).
        if (proposedSource.code.length == 0) revert InvalidSource();
        // Redundant with proposeSource's check, but keeps confirm self-contained.
        if (proposedSource == source) revert SameSource();
        // Re-check the shallow direct-proxy marker after the timelock so proposal-time
        // classification cannot be bypassed by changed code or corrupted pending state.
        // This marker does not traverse forwarding dependencies or prove acyclicity.
        if (_isPriceFeedProxy(proposedSource)) revert InvalidSource();

        address oldSource = source;
        SourceRead memory oldRead;
        // The emergency path is the recovery route for a broken source. Do not call that
        // source here: it may consume all forwarded gas and otherwise make itself impossible
        // to replace. The validated proxy caches remain the continuity reference for the event.
        if (!_bypassPriceGuard) oldRead = _readSourceIfHealthy(oldSource);

        // F-03 / F-06: smoke-test the new source so the switch fails CLOSED if the new source
        // cannot serve a valid, ABI-decodable price *right now*. A reverting source reverts here;
        // a mis-encoded (wrong-ABI) source's return-data decode failure pierces try/catch and
        // also reverts here — both reject the switch instead of bricking redemption later
        // (CollateralRegistry.redeemCollateral reads every branch's feed with no try/catch).
        // Re-initialise the normal cache to the NEW source. Re-initialise the redemption cache
        // only from fresh JPY provenance; an aged source cannot replace the last fresh quote,
        // and any later fallback is returned with failure=true so consumers cannot settle on it.
        (uint256 newPrice, bool newOracleFailure) = IPriceFeed(proposedSource).fetchPrice();
        // Reject an invalid price AND a live-but-failing source (valid price + oracleFailure==true
        // without reverting) — consistent with fetchPrice's F-02 handling, so confirm only accepts
        // a source actually serving good data right now.
        if (_isInvalidPrice(newPrice) || newOracleFailure) revert InvalidSource();
        // C-1: validate fetchRedemptionPrice() too. Redemption divides by it (RedemptionHelper.sol
        // / TroveManager.sol) and reads it with no try/catch, so a source valid on fetchPrice() but
        // wrong-ABI / reverting / failure-flagged on fetchRedemptionPrice() would still DoS all
        // redemptions. A wrong-ABI return-data decode failure pierces try/catch and reverts here.
        (uint256 newRedemptionPrice, bool newRedemptionFailure) = IPriceFeed(proposedSource).fetchRedemptionPrice();
        if (_isInvalidPrice(newRedemptionPrice) || newRedemptionFailure) revert InvalidSource();
        (uint256 newUrgentRedemptionPrice, bool newUrgentRedemptionFailure) =
            IPriceFeed(proposedSource).fetchUrgentRedemptionPrice();
        if (_isInvalidPrice(newUrgentRedemptionPrice) || newUrgentRedemptionFailure) revert InvalidSource();

        uint256 referencePrice = oldRead.healthy ? oldRead.price : _lastGoodPrice;
        uint256 referenceRedemptionPrice =
            oldRead.healthy && oldRead.redemptionPriceCacheable ? oldRead.redemptionPrice : _lastGoodRedemptionPrice;
        uint256 referenceUrgentRedemptionPrice =
            oldRead.healthy ? oldRead.urgentRedemptionPrice : _lastGoodRedemptionPrice;

        // Normal confirmation never becomes an implicit emergency path merely because the old
        // source failed between proposal and execution. The proxy caches are initialized and
        // updated only from validated prices, so they provide the continuity reference while the
        // old source is unavailable. A deliberate jump remains possible through the explicitly
        // named emergency entrypoint, which keeps the same timelock and new-source smoke tests.
        if (!_bypassPriceGuard) {
            _requireWithinSwitchDeviation(referencePrice, newPrice);
            _requireWithinSwitchDeviation(referenceRedemptionPrice, newRedemptionPrice);
            _requireWithinSwitchDeviation(referenceUrgentRedemptionPrice, newUrgentRedemptionPrice);
        }

        _cacheConfirmedSourcePrices(proposedSource, newPrice, newRedemptionPrice);

        source = proposedSource;

        proposedSource = address(0);
        sourceProposedAt = 0;

        emit SourceUpdated(oldSource, source);
        emit SourceSwitchValidated(
            oldSource,
            source,
            oldRead.healthy,
            _bypassPriceGuard,
            referencePrice,
            newPrice,
            referenceRedemptionPrice,
            newRedemptionPrice
        );
    }

    function _readSourceIfHealthy(address _source) internal returns (SourceRead memory read) {
        try IPriceFeed(_source).fetchPrice() returns (uint256 price, bool oracleFailure) {
            if (_isInvalidPrice(price) || oracleFailure) return read;
            read.price = price;
        } catch {
            return read;
        }

        try IPriceFeed(_source).fetchRedemptionPrice() returns (uint256 redemptionPrice, bool oracleFailure) {
            if (_isInvalidPrice(redemptionPrice) || oracleFailure) return read;
            read.redemptionPrice = redemptionPrice;
        } catch {
            return read;
        }

        try IPriceFeed(_source).fetchUrgentRedemptionPrice() returns (uint256 urgentPrice, bool oracleFailure) {
            if (_isInvalidPrice(urgentPrice) || oracleFailure) return read;
            read.urgentRedemptionPrice = urgentPrice;
        } catch {
            return read;
        }

        uint8 jpyProvenance = _normalRedemptionJpyStatus(_source);
        read.redemptionPriceCacheable = jpyProvenance == JPY_PROVENANCE_FRESH;
        read.healthy = true;
    }

    /// @dev Validate the source-bound provider and classify the normal-redemption age gate.
    ///      Fixed-size return buffers keep malformed runtime provenance and oversized returndata
    ///      local to normal redemption without copying attacker-controlled return lengths.
    function _normalRedemptionJpyStatus(address _source) private view returns (uint8) {
        (bool sourceOk, uint256 encodedProvider) =
            _staticcallWord(_source, IJpyUsdRateProviderSource.jpyUsdRateProvider.selector);
        if (!sourceOk) return JPY_PROVENANCE_INVALID;
        if (encodedProvider > type(uint160).max) return JPY_PROVENANCE_INVALID;
        address provider = address(uint160(encodedProvider));
        if (provider.code.length == 0) return JPY_PROVENANCE_INVALID;

        (bool providerOk, uint256 updatedAt) =
            _staticcallWord(provider, IJpyUsdRateProvider.lastGoodJpyUpdatedAt.selector);
        if (!providerOk) return JPY_PROVENANCE_INVALID;
        if (updatedAt == 0 || updatedAt > block.timestamp) return JPY_PROVENANCE_INVALID;
        return block.timestamp - updatedAt >= MAX_NORMAL_REDEMPTION_JPY_AGE ? JPY_PROVENANCE_AGED : JPY_PROVENANCE_FRESH;
    }

    function _staticcallWord(address _target, bytes4 _selector) private view returns (bool success, uint256 result) {
        bytes memory callData = abi.encodeWithSelector(_selector);
        uint256 stipend = JPY_PROVENANCE_GAS_STIPEND;
        assembly {
            let output := mload(0x40)
            mstore(output, 0)
            success := staticcall(stipend, _target, add(callData, 0x20), mload(callData), output, 0x20)
            success := and(success, eq(returndatasize(), 0x20))
            if success { result := mload(output) }
        }
    }

    function _cacheConfirmedSourcePrices(address _source, uint256 _price, uint256 _redemptionPrice) private {
        uint8 jpyProvenance = _normalRedemptionJpyStatus(_source);
        if (jpyProvenance == JPY_PROVENANCE_INVALID) revert InvalidSource();

        _lastGoodPrice = _price;
        if (jpyProvenance == JPY_PROVENANCE_FRESH) _lastGoodRedemptionPrice = _redemptionPrice;
    }

    function _requireWithinSwitchDeviation(uint256 _oldPrice, uint256 _newPrice) internal pure {
        uint256 delta = _newPrice > _oldPrice ? _newPrice - _oldPrice : _oldPrice - _newPrice;
        uint256 maxDelta = _oldPrice * MAX_SOURCE_SWITCH_DEVIATION_BPS / BPS_DENOMINATOR;

        if (delta > maxDelta) {
            revert SourcePriceDeviationTooLarge(_oldPrice, _newPrice, MAX_SOURCE_SWITCH_DEVIATION_BPS);
        }
    }

    function _isPriceFeedProxy(address _candidate) private view returns (bool) {
        (bool success, bytes memory result) =
            _candidate.staticcall(abi.encodeWithSelector(IPriceFeedProxy.source.selector));
        return success && result.length == 32;
    }

    /// @inheritdoc IPriceFeedProxy
    function cancelSourceProposal() external onlyOwner {
        if (proposedSource == address(0)) revert NoProposalPending();

        address cancelled = proposedSource;
        proposedSource = address(0);
        sourceProposedAt = 0;

        emit SourceProposalCancelled(cancelled);
    }

    // =========================================================
    //  Ownership — overrides
    // =========================================================

    /// @notice Disable ownership renounce to preserve the source-swap recovery path.
    /// @dev Pending source proposals and pending ownership transfers remain unchanged;
    ///      cancel them explicitly with cancelSourceProposal() / transferOwnership(0).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }
}
