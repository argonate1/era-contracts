// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TestPairing
 * @notice Minimal contract to test if Solidity assembly can correctly call the pairing precompile
 * @dev This contract reproduces exactly what RedeemVerifier does to isolate the issue
 */
contract TestPairing {
    uint256 constant q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // Gamma G2 point (same as in RedeemVerifier)
    uint256 constant gammax1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant gammax2 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant gammay1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant gammay2 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;

    /**
     * @notice Test simple pairing: e(G1, G2) * e(-G1, G2) = 1
     * @dev Uses the same G2 encoding as RedeemVerifier
     */
    function testSimplePairing() public view returns (bool success, uint256 result) {
        // G1 generator
        uint256 g1x = 1;
        uint256 g1y = 2;
        // -G1 (negated y)
        uint256 negG1y = q - g1y;

        uint256[12] memory input;
        // Pair 1: G1, G2
        input[0] = g1x;
        input[1] = g1y;
        input[2] = gammax1;  // x1 as stored in verifier
        input[3] = gammax2;  // x2 as stored in verifier
        input[4] = gammay1;  // y1 as stored in verifier
        input[5] = gammay2;  // y2 as stored in verifier
        // Pair 2: -G1, G2
        input[6] = g1x;
        input[7] = negG1y;
        input[8] = gammax1;
        input[9] = gammax2;
        input[10] = gammay1;
        input[11] = gammay2;

        uint256[1] memory out;
        assembly {
            success := staticcall(sub(gas(), 2000), 8, input, 384, out, 0x20)
        }
        result = out[0];
    }

    /**
     * @notice Test pairing using assembly memory like RedeemVerifier
     */
    function testPairingWithAssemblyMemory() public view returns (bool success, uint256 result) {
        assembly {
            let pMem := mload(0x40)
            mstore(0x40, add(pMem, 512))

            // G1 = (1, 2)
            let g1x := 1
            let g1y := 2
            // -G1 = (1, q - 2)
            let negG1y := sub(q, g1y)

            // Pair 1: G1, G2
            mstore(pMem, g1x)
            mstore(add(pMem, 32), g1y)
            mstore(add(pMem, 64), gammax1)
            mstore(add(pMem, 96), gammax2)
            mstore(add(pMem, 128), gammay1)
            mstore(add(pMem, 160), gammay2)

            // Pair 2: -G1, G2
            mstore(add(pMem, 192), g1x)
            mstore(add(pMem, 224), negG1y)
            mstore(add(pMem, 256), gammax1)
            mstore(add(pMem, 288), gammax2)
            mstore(add(pMem, 320), gammay1)
            mstore(add(pMem, 352), gammay2)

            success := staticcall(sub(gas(), 2000), 8, pMem, 384, pMem, 0x20)
            result := mload(pMem)
        }
    }

    /**
     * @notice Directly verify a proof - mimics RedeemVerifier exactly
     * @param _pA Proof point A
     * @param _pB Proof point B (G2)
     * @param _pC Proof point C
     * @param _pubSignals Public signals [6]
     */
    function verifyProofMinimal(
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[6] calldata _pubSignals
    ) public view returns (bool success, uint256 pairingResult, uint256 vk_x_x, uint256 vk_x_y) {
        // Just return the decoded values to verify they're correct
        vk_x_x = _pA[0];  // Dummy - return pA for now
        vk_x_y = _pA[1];

        // Test if we can even decode the B point correctly
        assembly {
            let pMem := mload(0x40)
            mstore(0x40, add(pMem, 512))

            // Just do a simple pairing test to verify the precompile works
            let g1x := 1
            let g1y := 2
            let negG1y := sub(q, g1y)

            mstore(pMem, g1x)
            mstore(add(pMem, 32), g1y)
            mstore(add(pMem, 64), gammax1)
            mstore(add(pMem, 96), gammax2)
            mstore(add(pMem, 128), gammay1)
            mstore(add(pMem, 160), gammay2)
            mstore(add(pMem, 192), g1x)
            mstore(add(pMem, 224), negG1y)
            mstore(add(pMem, 256), gammax1)
            mstore(add(pMem, 288), gammax2)
            mstore(add(pMem, 320), gammay1)
            mstore(add(pMem, 352), gammay2)

            success := staticcall(sub(gas(), 2000), 8, pMem, 384, pMem, 0x20)
            pairingResult := mload(pMem)
        }
    }

    /**
     * @notice Get the calldata offsets for debugging
     */
    function getCalldataInfo(
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[6] calldata _pubSignals
    ) public pure returns (
        uint256 pA0, uint256 pA1,
        uint256 pB00, uint256 pB01, uint256 pB10, uint256 pB11,
        uint256 pC0, uint256 pC1,
        uint256 ps0, uint256 ps1, uint256 ps2, uint256 ps3, uint256 ps4, uint256 ps5
    ) {
        pA0 = _pA[0];
        pA1 = _pA[1];
        pB00 = _pB[0][0];
        pB01 = _pB[0][1];
        pB10 = _pB[1][0];
        pB11 = _pB[1][1];
        pC0 = _pC[0];
        pC1 = _pC[1];
        ps0 = _pubSignals[0];
        ps1 = _pubSignals[1];
        ps2 = _pubSignals[2];
        ps3 = _pubSignals[3];
        ps4 = _pubSignals[4];
        ps5 = _pubSignals[5];
    }
}
