/**
 * Test script for Ghost redeem circuit
 * Generates a valid witness and verifies the circuit works correctly
 */

const snarkjs = require('snarkjs');
const fs = require('fs');
const path = require('path');
const { buildPoseidon } = require('circomlibjs');

async function main() {
    console.log('Loading Poseidon hash function...');
    const poseidon = await buildPoseidon();
    const F = poseidon.F;

    // Test parameters
    const secret = BigInt('0x' + 'a'.repeat(64));  // Random 256-bit secret
    const nullifier = BigInt('0x' + 'b'.repeat(64));  // Random 256-bit nullifier
    const amount = BigInt('1000000000000000000');  // 1 token (18 decimals)
    const tokenAddress = BigInt('0x1234567890123456789012345678901234567890');
    const recipient = BigInt('0xabcdefabcdefabcdefabcdefabcdefabcdefabcd');

    console.log('Computing commitment...');
    // commitment = Poseidon(secret, nullifier, amount, tokenAddress)
    const commitmentHash = poseidon([secret, nullifier, amount, tokenAddress]);
    const commitment = F.toObject(commitmentHash);
    console.log('Commitment:', commitment.toString(16));

    // Build a simple Merkle tree with just this commitment
    const TREE_DEPTH = 20;
    const zeroValues = [];
    let currentZero = BigInt(0);

    // Compute zero values for each level
    for (let i = 0; i < TREE_DEPTH; i++) {
        zeroValues.push(currentZero);
        // Hash with domain separator for leaves (0) or nodes (1)
        if (i === 0) {
            // leafHash = Poseidon(0, leaf)
            currentZero = F.toObject(poseidon([0, currentZero]));
        } else {
            // nodeHash = Poseidon(1, left, right)
            currentZero = F.toObject(poseidon([1, currentZero, currentZero]));
        }
    }

    // Compute Merkle root with our commitment at index 0
    // leafHash = Poseidon(0, commitment)
    let currentHash = F.toObject(poseidon([0, commitment]));
    const pathElements = [];
    const pathIndices = [];

    for (let i = 0; i < TREE_DEPTH; i++) {
        pathElements.push(zeroValues[i]);
        pathIndices.push(0);  // Our leaf is always on the left
        // nodeHash = Poseidon(1, left, right)
        currentHash = F.toObject(poseidon([1, currentHash, zeroValues[i]]));
    }

    const merkleRoot = currentHash;
    console.log('Merkle root:', merkleRoot.toString(16));

    // Create witness input
    const input = {
        // Public inputs
        merkleRoot: merkleRoot.toString(),
        nullifier: nullifier.toString(),
        amount: amount.toString(),
        tokenAddress: tokenAddress.toString(),
        recipient: recipient.toString(),

        // Private inputs
        secret: secret.toString(),
        pathElements: pathElements.map(e => e.toString()),
        pathIndices: pathIndices.map(e => e.toString()),
    };

    console.log('\nInput:', JSON.stringify(input, null, 2));

    // Check if compiled circuit exists
    const wasmPath = path.join(__dirname, '../build/redeem/redeem_js/redeem.wasm');
    const zkeyPath = path.join(__dirname, '../build/redeem/redeem_final.zkey');

    if (!fs.existsSync(wasmPath)) {
        console.log('\nCircuit not compiled yet. Run: npm run compile:redeem');
        console.log('Saving test input to: build/redeem/input.json');

        const buildDir = path.join(__dirname, '../build/redeem');
        if (!fs.existsSync(buildDir)) {
            fs.mkdirSync(buildDir, { recursive: true });
        }
        fs.writeFileSync(path.join(buildDir, 'input.json'), JSON.stringify(input, null, 2));
        return;
    }

    console.log('\nGenerating proof...');
    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        wasmPath,
        zkeyPath
    );

    console.log('\nProof generated successfully!');
    console.log('Public signals:', publicSignals);

    // Verify the proof
    const vkeyPath = path.join(__dirname, '../build/redeem/verification_key.json');
    const vkey = JSON.parse(fs.readFileSync(vkeyPath, 'utf8'));

    const verified = await snarkjs.groth16.verify(vkey, publicSignals, proof);
    console.log('\nProof verification:', verified ? 'PASSED' : 'FAILED');

    if (!verified) {
        process.exit(1);
    }

    // Export proof for Solidity
    const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
    console.log('\nSolidity calldata:');
    console.log(calldata);
}

main()
    .then(() => process.exit(0))
    .catch(err => {
        console.error(err);
        process.exit(1);
    });
