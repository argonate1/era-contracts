// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GhostERC20Harness} from "../helpers/GhostERC20Harness.sol";
import {CommitmentTree} from "../../../../contracts/ghost/CommitmentTree.sol";
import {NullifierRegistry} from "../../../../contracts/ghost/NullifierRegistry.sol";
import {GhostVerifier} from "../../../../contracts/ghost/GhostVerifier.sol";
import {GhostHash} from "../../../../contracts/ghost/libraries/GhostHash.sol";

/**
 * @title GhostE2EBase
 * @notice Base contract for Ghost Protocol E2E tests
 * @dev Provides shared infrastructure, helpers, and realistic test scenarios
 *
 * This test harness simulates production behavior:
 * - Full contract deployment matching production deployment script
 * - Realistic user interactions with multiple actors
 * - Merkle proof generation matching SDK behavior
 * - ZK proof simulation (test mode verifier)
 */
abstract contract GhostE2EBase is Test {
    // ============ Core Infrastructure ============
    CommitmentTree public commitmentTree;
    NullifierRegistry public nullifierRegistry;
    GhostVerifier public verifier;

    // ============ Test Tokens ============
    GhostERC20Harness public ghostUSDC;
    GhostERC20Harness public ghostWETH;

    // ============ Test Actors ============
    address public deployer;
    address public alice;
    address public bob;
    address public charlie;
    address public relayer; // For privacy - submits txs on behalf of others
    address public attacker;

    // ============ Constants ============
    uint256 public constant TREE_DEPTH = 20;
    bytes32 public constant USDC_ASSET_ID = keccak256("USDC_ASSET");
    bytes32 public constant WETH_ASSET_ID = keccak256("WETH_ASSET");
    address public constant MOCK_L1_USDC = address(0xA0B86a33e6441b8dE7FBC53b9a7d45B2E3d8b3A6);
    address public constant MOCK_L1_WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // ============ Voucher Structure (mirrors SDK) ============
    struct Voucher {
        bytes32 secret;
        bytes32 nullifier;
        bytes32 commitment;
        uint256 leafIndex;
        address token;
        uint256 amount;
        uint256 remainingAmount;
        uint256 chainId;
        uint256 createdAt;
        bool spent;
    }

    // ============ Events for verification ============
    event Ghosted(address indexed from, uint256 amount, bytes32 indexed commitment, uint256 leafIndex);
    event Redeemed(uint256 amount, address indexed recipient, bytes32 indexed nullifier);
    event PartialRedeemed(uint256 redeemAmount, address indexed recipient, bytes32 indexed oldNullifier, bytes32 indexed newCommitment, uint256 newLeafIndex);

    // ============ Setup ============

    function setUp() public virtual {
        // Initialize actors
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        relayer = makeAddr("relayer");
        attacker = makeAddr("attacker");

        // Fund actors
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(relayer, 10 ether);
        vm.deal(attacker, 10 ether);

        // Deploy infrastructure
        _deployInfrastructure();

        // Deploy test tokens
        _deployTestTokens();

        // Setup authorizations
        _setupAuthorizations();
    }

    function _deployInfrastructure() internal {
        // 1. Deploy CommitmentTree
        commitmentTree = new CommitmentTree();

        // 2. Deploy NullifierRegistry
        nullifierRegistry = new NullifierRegistry();

        // 3. Deploy GhostVerifier in TEST MODE
        verifier = new GhostVerifier(true);
    }

    function _deployTestTokens() internal {
        // Deploy ghostUSDC (using test harness without _disableInitializers)
        ghostUSDC = new GhostERC20Harness();
        ghostUSDC.initialize(
            USDC_ASSET_ID,
            MOCK_L1_USDC,
            "USD Coin",
            "USDC",
            6,
            address(commitmentTree),
            address(nullifierRegistry),
            address(verifier)
        );

        // Deploy ghostWETH (using test harness without _disableInitializers)
        ghostWETH = new GhostERC20Harness();
        ghostWETH.initialize(
            WETH_ASSET_ID,
            MOCK_L1_WETH,
            "Wrapped Ether",
            "WETH",
            18,
            address(commitmentTree),
            address(nullifierRegistry),
            address(verifier)
        );
    }

    function _setupAuthorizations() internal {
        // Authorize tokens to insert commitments
        commitmentTree.authorizeInserter(address(ghostUSDC));
        commitmentTree.authorizeInserter(address(ghostWETH));

        // Authorize tokens to mark nullifiers
        nullifierRegistry.authorizeMarker(address(ghostUSDC));
        nullifierRegistry.authorizeMarker(address(ghostWETH));
    }

    // ============ Helper Functions ============

    /**
     * @notice Mint tokens to a user (simulates bridge mint)
     */
    function _mintTokens(GhostERC20Harness token, address to, uint256 amount) internal {
        // GhostERC20Harness uses nativeTokenVault() for minting authority
        // In tests, we use the deployer as NTV
        vm.prank(address(token.nativeTokenVault()));
        token.bridgeMint(to, amount);
    }

    /**
     * @notice Generate a random voucher (mimics SDK behavior)
     */
    function _generateVoucher(
        address token,
        uint256 amount,
        uint256 leafIndex
    ) internal view returns (Voucher memory) {
        bytes32 secret = keccak256(abi.encodePacked(block.timestamp, msg.sender, leafIndex, "secret"));
        bytes32 nullifier = keccak256(abi.encodePacked(block.timestamp, msg.sender, leafIndex, "nullifier"));
        bytes32 commitment = GhostHash.computeCommitment(secret, nullifier, amount, token);

        return Voucher({
            secret: secret,
            nullifier: nullifier,
            commitment: commitment,
            leafIndex: leafIndex,
            token: token,
            amount: amount,
            remainingAmount: amount,
            chainId: block.chainid,
            createdAt: block.timestamp,
            spent: false
        });
    }

    /**
     * @notice Build Merkle proof for a leaf
     * @dev Simplified - uses zero values for siblings (valid for first insertions)
     */
    function _buildMerkleProof(uint256 leafIndex) internal view returns (
        bytes32[] memory pathElements,
        uint256[] memory pathIndices
    ) {
        pathElements = new bytes32[](TREE_DEPTH);
        pathIndices = new uint256[](TREE_DEPTH);

        uint256 currentIndex = leafIndex;
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            pathElements[i] = commitmentTree.getZeroValue(i);
            pathIndices[i] = currentIndex % 2;
            currentIndex = currentIndex / 2;
        }
    }

    /**
     * @notice Generate a dummy ZK proof (accepted in test mode)
     */
    function _generateDummyProof() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    /**
     * @notice Execute full ghost operation and return voucher
     */
    function _ghost(
        GhostERC20Harness token,
        address from,
        uint256 amount
    ) internal returns (Voucher memory voucher) {
        uint256 nextLeafIndex = commitmentTree.getNextLeafIndex();
        voucher = _generateVoucher(address(token), amount, nextLeafIndex);

        vm.prank(from);
        uint256 leafIndex = token.ghost(amount, voucher.commitment);

        voucher.leafIndex = leafIndex;
        return voucher;
    }

    /**
     * @notice Execute full redeem operation
     */
    function _redeem(
        GhostERC20Harness token,
        Voucher memory voucher,
        address recipient,
        address submitter
    ) internal {
        bytes32 merkleRoot = commitmentTree.getRoot();
        (bytes32[] memory pathElements, uint256[] memory pathIndices) = _buildMerkleProof(voucher.leafIndex);
        bytes memory zkProof = _generateDummyProof();

        vm.prank(submitter);
        token.redeem(
            voucher.amount,
            recipient,
            voucher.nullifier,
            merkleRoot,
            pathElements,
            pathIndices,
            zkProof
        );
    }

    /**
     * @notice Execute partial redeem operation
     */
    function _redeemPartial(
        GhostERC20Harness token,
        Voucher memory voucher,
        uint256 redeemAmount,
        address recipient,
        address submitter
    ) internal returns (Voucher memory newVoucher) {
        bytes32 merkleRoot = commitmentTree.getRoot();
        (bytes32[] memory pathElements, uint256[] memory pathIndices) = _buildMerkleProof(voucher.leafIndex);
        bytes memory zkProof = _generateDummyProof();

        // Generate new voucher for remaining amount
        uint256 remainingAmount = voucher.amount - redeemAmount;
        uint256 newLeafIndex = commitmentTree.getNextLeafIndex();
        newVoucher = _generateVoucher(address(token), remainingAmount, newLeafIndex);

        vm.prank(submitter);
        uint256 actualNewLeafIndex = token.redeemPartial(
            redeemAmount,
            voucher.amount,
            recipient,
            voucher.nullifier,
            newVoucher.commitment,
            merkleRoot,
            pathElements,
            pathIndices,
            zkProof
        );

        newVoucher.leafIndex = actualNewLeafIndex;
        return newVoucher;
    }

    /**
     * @notice Assert token balances
     */
    function _assertBalance(GhostERC20Harness token, address account, uint256 expected) internal view {
        assertEq(token.balanceOf(account), expected, "Balance mismatch");
    }

    /**
     * @notice Assert nullifier is spent
     */
    function _assertNullifierSpent(bytes32 nullifier) internal view {
        assertTrue(nullifierRegistry.isSpent(nullifier), "Nullifier should be spent");
    }

    /**
     * @notice Assert nullifier is NOT spent
     */
    function _assertNullifierNotSpent(bytes32 nullifier) internal view {
        assertFalse(nullifierRegistry.isSpent(nullifier), "Nullifier should not be spent");
    }
}
