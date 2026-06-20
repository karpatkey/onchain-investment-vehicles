// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IRouterClient} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {
    IAny2EVMMessageReceiver
} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";
import {KpkOivFactory} from "./KpkOivFactory.sol";

/// @title  CcipOivDeployer
/// @author KPK
/// @notice Cross-chain orchestrator for `KpkOivFactory`. A single mainnet transaction deploys the
///         full OIV (`deployOiv`) on mainnet and, via Chainlink CCIP, fans out the operational
///         stack (`deployStack`) to a set of sidechains — yielding the SAME Avatar Safe / Manager
///         Safe / Roles Modifier addresses on every chain.
///
///         ── Why this contract exists ──────────────────────────────────────────────────────────
///         `KpkOivFactory` mixes `msg.sender` into every CREATE2 salt (see `_deriveSalts`). Its
///         cross-chain address invariant therefore holds only when the SAME caller invokes the
///         factory on every chain. A raw CCIP integration breaks this: on the destination chain
///         the factory's caller would be the CCIP Router, not the original mainnet account.
///
///         This contract solves it by being the single, uniform caller of the factory on every
///         chain. Because it is deployed at the SAME address on all chains (deterministic CREATE2
///         with identical creation code — see below), the factory observes one identical
///         `msg.sender` everywhere, and the address invariant is preserved with the factory
///         left completely untouched.
///
///         ── Deterministic-address constraint ──────────────────────────────────────────────────
///         The orchestrator's CREATE2 creation code must be byte-identical across chains, so NO
///         constructor argument may differ per chain. The CCIP Router and LINK token addresses DO
///         differ per chain, so — unlike Chainlink's stock `CCIPReceiver`, which stores the router
///         as a constructor immutable — they are held in mutable storage and wired post-deploy via
///         `configure()`. Only `_owner` and `_factory` (identical on every chain) are constructor
///         arguments. The `onlyRouter` / source-chain / source-sender checks are re-implemented
///         here against that storage router.
///
///         ── Trust & security ──────────────────────────────────────────────────────────────────
///         - `deployEverywhere` is `onlyOwner`: it spends the orchestrator's pre-funded LINK to pay
///           CCIP fees, so it must not be permissionless.
///         - `ccipReceive` accepts a message only when (a) `msg.sender` is the configured router,
///           (b) the source chain selector is the configured mainnet selector, and (c) the source
///           sender equals `address(this)` — which, by the same-address-everywhere property, is the
///           sibling orchestrator on mainnet. (c) blocks a forged message from pre-occupying the
///           deterministic CREATE2 addresses for a salt and griefing the legitimate deployment.
///         - The factory's exec Roles Modifier (owned by `config.admin`) remains the authoritative
///           gatekeeper of Avatar Safe execution. This contract never gains a privileged role on
///           any deployed fund — it is purely a deployment conduit.
contract CcipOivDeployer is Ownable, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    // ── Immutable config (identical on every chain) ────────────────────────────

    /// @notice The `KpkOivFactory` this orchestrator drives. Deployed at the same address on every
    ///         chain, so it is safe to bake into the constructor (init-code stays chain-identical).
    KpkOivFactory public immutable factory;

    // ── Per-chain config (wired post-deploy via `configure`) ────────────────────

    /// @notice CCIP Router for the current chain. Differs per chain, so set after construction.
    address public router;

    /// @notice LINK token used to pay CCIP fees on the current chain. Differs per chain.
    address public linkToken;

    /// @notice CCIP chain selector of Ethereum mainnet — the only source `ccipReceive` accepts.
    uint64 public mainnetChainSelector;

    // ── Events ───────────────────────────────────────────────────────────────────

    /// @notice Emitted when `configure` wires the per-chain CCIP parameters.
    event Configured(address indexed router, address indexed linkToken, uint64 mainnetChainSelector);

    /// @notice Emitted on mainnet for the locally deployed full OIV.
    event LocalOivDeployed(KpkOivFactory.OivInstance instance);

    /// @notice Emitted for each sidechain CCIP message dispatched by `deployEverywhere`.
    /// @param destChainSelector Destination chain selector.
    /// @param messageId         CCIP message id returned by the router.
    /// @param fee               LINK fee paid for this message.
    event StackDispatched(uint64 indexed destChainSelector, bytes32 indexed messageId, uint256 fee);

    /// @notice Emitted on a sidechain when an inbound CCIP message deploys the stack.
    /// @param sourceChainSelector Source chain selector (always the mainnet selector).
    /// @param messageId           CCIP message id of the inbound message.
    /// @param instance            Addresses of the five stack contracts deployed.
    event StackReceived(
        uint64 indexed sourceChainSelector, bytes32 indexed messageId, KpkOivFactory.StackInstance instance
    );

    // ── Errors ─────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotConfigured();
    error InvalidRouter(address caller);
    error InvalidSourceChain(uint64 sourceChainSelector);
    error InvalidSourceSender(address sender);
    error NoDestinations();
    error InsufficientLinkBalance(uint256 required, uint256 available);

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @param _owner   Owner of the orchestrator. MUST be identical on every chain (it is baked
    ///                 into the creation code), so the same value must be used for every deploy to
    ///                 keep the CREATE2 address identical. Hand off to a governance multisig after
    ///                 deployment via `transferOwnership`.
    /// @param _factory `KpkOivFactory` address — identical on every chain by construction.
    constructor(address _owner, address _factory) Ownable(_owner) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = KpkOivFactory(_factory);
    }

    // ── Configuration ────────────────────────────────────────────────────────────

    /// @notice Wires the per-chain CCIP parameters. Owner-only; idempotent (re-callable to update
    ///         the router if Chainlink migrates it). Kept out of the constructor so the
    ///         orchestrator's creation code — and therefore its CREATE2 address — is identical on
    ///         every chain.
    /// @param _router               CCIP Router on the current chain.
    /// @param _linkToken            LINK token used for CCIP fees on the current chain.
    /// @param _mainnetChainSelector CCIP selector of Ethereum mainnet (the trusted source).
    function configure(address _router, address _linkToken, uint64 _mainnetChainSelector) external onlyOwner {
        if (_router == address(0) || _linkToken == address(0)) revert ZeroAddress();
        if (_mainnetChainSelector == 0) revert ZeroAddress();
        router = _router;
        linkToken = _linkToken;
        mainnetChainSelector = _mainnetChainSelector;
        emit Configured(_router, _linkToken, _mainnetChainSelector);
    }

    // ── Source side: deploy everywhere ───────────────────────────────────────────

    /// @notice Deploys the full OIV locally (intended to be called on mainnet) and dispatches a
    ///         CCIP message to each destination chain to deploy the matching operational stack.
    ///         CCIP fees are paid in LINK from this contract's balance, so the orchestrator must be
    ///         pre-funded with LINK before calling.
    /// @dev    Owner-only. Asynchronous: this transaction confirms once the messages are dispatched;
    ///         each sidechain stack materialises later (after source finality) when CCIP delivers
    ///         to `ccipReceive`. A destination message can fail (e.g. gas underestimate, missing
    ///         `EMPTY_CONTRACT`) and then be manually re-executed via CCIP within its retry window.
    /// @param config         Full OIV config — passed verbatim to `factory.deployOiv`. The derived
    ///                       `StackConfig` (sent to each sidechain) mirrors `deployOiv`'s internal
    ///                       mapping exactly, so the five operational-stack addresses match.
    /// @param destSelectors  CCIP chain selectors of the sidechains to fan out to.
    /// @param gasLimit       Destination `ccipReceive` gas limit (must cover `deployStack`, ~1.45M
    ///                       measured; a 1.8M–2.0M value is recommended). Capped at 3M by CCIP.
    /// @return instance      Addresses of the seven contracts deployed locally.
    /// @return messageIds    CCIP message id per destination, in `destSelectors` order.
    function deployEverywhere(
        KpkOivFactory.OivConfig calldata config,
        uint64[] calldata destSelectors,
        uint256 gasLimit
    ) external onlyOwner returns (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds) {
        if (router == address(0)) revert NotConfigured();
        if (destSelectors.length == 0) revert NoDestinations();

        // 1. Local full OIV. `msg.sender` to the factory is this orchestrator — the same identity
        //    that will call `deployStack` on every sidechain, so all addresses align.
        instance = factory.deployOiv(config);
        emit LocalOivDeployed(instance);

        // 2. Fan out the operational stack to each destination chain.
        bytes memory payload = abi.encode(_toStackConfig(config));
        messageIds = new bytes32[](destSelectors.length);

        IERC20 link = IERC20(linkToken);
        IRouterClient ccipRouter = IRouterClient(router);

        for (uint256 i = 0; i < destSelectors.length; i++) {
            Client.EVM2AnyMessage memory message = _buildMessage(payload, gasLimit);
            uint256 fee = ccipRouter.getFee(destSelectors[i], message);

            uint256 balance = link.balanceOf(address(this));
            if (balance < fee) revert InsufficientLinkBalance(fee, balance);

            link.forceApprove(router, fee);
            bytes32 messageId = ccipRouter.ccipSend(destSelectors[i], message);
            messageIds[i] = messageId;
            emit StackDispatched(destSelectors[i], messageId, fee);
        }
    }

    /// @notice Returns the total LINK fee `deployEverywhere(config, destSelectors, gasLimit)` would
    ///         charge. Useful for pre-funding the orchestrator and surfacing cost before
    ///         broadcasting. Uses the exact derived `StackConfig` payload so the fee — which scales
    ///         with calldata length and gas limit — is accurate.
    function quoteDeployEverywhere(
        KpkOivFactory.OivConfig calldata config,
        uint64[] calldata destSelectors,
        uint256 gasLimit
    ) external view returns (uint256 totalFee, uint256[] memory feePerDestination) {
        if (router == address(0)) revert NotConfigured();
        bytes memory payload = abi.encode(_toStackConfig(config));
        Client.EVM2AnyMessage memory message = _buildMessage(payload, gasLimit);
        IRouterClient ccipRouter = IRouterClient(router);
        feePerDestination = new uint256[](destSelectors.length);
        for (uint256 i = 0; i < destSelectors.length; i++) {
            uint256 fee = ccipRouter.getFee(destSelectors[i], message);
            feePerDestination[i] = fee;
            totalFee += fee;
        }
    }

    // ── Destination side: receive and deploy stack ───────────────────────────────

    /// @inheritdoc IAny2EVMMessageReceiver
    /// @dev Called by the CCIP Router on the destination chain. Validates the router, source chain,
    ///      and source sender, then deploys the operational stack. Reverts propagate so a failed
    ///      delivery enters CCIP's FAILED state and can be manually re-executed.
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        if (msg.sender != router) revert InvalidRouter(msg.sender);
        if (message.sourceChainSelector != mainnetChainSelector) {
            revert InvalidSourceChain(message.sourceChainSelector);
        }
        // By the same-address-on-every-chain property, the trusted source sender is this very
        // address — the sibling orchestrator on mainnet.
        address sourceSender = abi.decode(message.sender, (address));
        if (sourceSender != address(this)) revert InvalidSourceSender(sourceSender);

        KpkOivFactory.StackConfig memory stackConfig = abi.decode(message.data, (KpkOivFactory.StackConfig));
        KpkOivFactory.StackInstance memory inst = factory.deployStack(stackConfig);
        emit StackReceived(message.sourceChainSelector, message.messageId, inst);
    }

    // ── LINK treasury management ─────────────────────────────────────────────────

    /// @notice Withdraws LINK from the orchestrator to `to`. Owner-only.
    function withdrawLink(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (linkToken == address(0)) revert NotConfigured();
        IERC20(linkToken).safeTransfer(to, amount);
    }

    // ── ERC165 ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC165
    /// @dev Lets the CCIP Router confirm this contract implements `ccipReceive` before delivery.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ── Internal helpers ─────────────────────────────────────────────────────────

    /// @dev Mirrors `KpkOivFactory.deployOiv`'s internal `OivConfig` → `StackConfig` mapping exactly.
    ///      Any divergence here would make sidechain stack addresses differ from the mainnet OIV.
    function _toStackConfig(KpkOivFactory.OivConfig calldata config)
        internal
        pure
        returns (KpkOivFactory.StackConfig memory)
    {
        return KpkOivFactory.StackConfig({
            managerSafe: config.managerSafe,
            execRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: config.admin}),
            subRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: address(0)}),
            managerRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: address(0)}),
            salt: config.salt
        });
    }

    /// @dev Builds the CCIP message: receiver is this contract's sibling on the destination chain
    ///      (same address), no token transfer, LINK fee token, EVMExtraArgsV2 with the given gas
    ///      limit and out-of-order execution allowed (stack deployments are mutually independent).
    function _buildMessage(bytes memory payload, uint256 gasLimit)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(address(this)),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: linkToken,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true}))
        });
    }
}
