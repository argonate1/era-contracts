// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title RedeemVerifierWorking
 * @notice Working Groth16 verifier for Ghost Protocol redeem circuit on ZKsync Era
 * @dev Uses Solidity bytes memory allocation pattern which works correctly on zkEVM.
 *      The standard snarkjs verifier assembly pattern fails on ZKsync due to memory handling.
 */
contract RedeemVerifierWorking {
    // Scalar field size
    uint256 constant r = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // Base field size
    uint256 constant q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // Verification Key data (from snarkjs export)
    // Updated for circuit without leafIndex (Tornado Cash pattern - random nullifier)
    uint256 constant alphax = 20491192805390485299153009773594534940189261866228447918068658471970481763042;
    uint256 constant alphay = 9383485363053290200918347156157836566562967994039712273449902621266178545958;
    uint256 constant betax1 = 4252822878758300859123897981450591353533073413197771768651442665752259397132;
    uint256 constant betax2 = 6375614351688725206403948262868962793625744043794305715222011528459656738731;
    uint256 constant betay1 = 21847035105528745403288232691147584728191162732299865338377159692350059136679;
    uint256 constant betay2 = 10505242626370262277552901082094356697409835680220590971873171140371331206856;
    uint256 constant gammax1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant gammax2 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant gammay1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant gammay2 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;
    // Delta - circuit-specific, updated for new circuit
    uint256 constant deltax1 = 17725317263237682730876633676053741295332542753853336976621024154081347474120;
    uint256 constant deltax2 = 20476989051858754764169734739007235884844202115637709006341913734112558536743;
    uint256 constant deltay1 = 11686644311125638340443087197262515178529689318938950437939099744702314990990;
    uint256 constant deltay2 = 17259358240227247730273676365935364941009911557925325047375711243988302324194;

    // IC points - circuit-specific, updated for new circuit (no leafIndex)
    uint256 constant IC0x = 10668750289136200115180489273443636774570828440017159868341618735532939978359;
    uint256 constant IC0y = 10830118271066031996549167513373656243363856031218450448061403095905154815310;
    uint256 constant IC1x = 7430099923639729522794751063447806368178087989125272356296744089357832367081;
    uint256 constant IC1y = 3251159619956303851593373810251317376993729103192454524235780171408876866686;
    uint256 constant IC2x = 12202838257788166591591375110004096355478087288913763659858157609144412469960;
    uint256 constant IC2y = 12733682129953227783595613222380562234582278489568142797718800822753280296809;
    uint256 constant IC3x = 6975836269762032120962289523164233259461684997819751521202880784453256249599;
    uint256 constant IC3y = 21422298564464190598299811643428444501991498340849930316238618719790688121405;
    uint256 constant IC4x = 2261177712742615949135096550509200524168470610203863377749833941689726685873;
    uint256 constant IC4y = 7206204235270579274940154426044944267070596860467410714337729713270489413474;
    uint256 constant IC5x = 8052313997532116737540401111510692180773085457592442033719659279005640300424;
    uint256 constant IC5y = 7188181573536081994754661934183324732903530577924997421847947826589015627187;
    uint256 constant IC6x = 14843830704116160551299586790906616771605957745994130691403500360963251562906;
    uint256 constant IC6y = 19237110263760976348291059326191684944899625762039916812698174158824213077935;

    /**
     * @notice Verify a Groth16 proof
     * @param _pA Proof point A (G1)
     * @param _pB Proof point B (G2) - expects coordinates in (imaginary, real) order for ZKsync
     * @param _pC Proof point C (G1)
     * @param _pubSignals Public signals array [commitment, merkleRoot, nullifier, amount, token, recipient]
     * @return True if proof is valid
     */
    function verifyProof(
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[6] calldata _pubSignals
    ) public view returns (bool) {
        // Validate public signals are in field
        for (uint i = 0; i < 6; i++) {
            if (_pubSignals[i] >= r) {
                return false;
            }
        }

        // Compute vk_x using precompiles
        (uint256 vkx, uint256 vky, bool vkSuccess) = _computeVkX(_pubSignals);
        if (!vkSuccess) {
            return false;
        }

        // Build pairing input using bytes memory (works on zkEVM)
        bytes memory pairingInput = _buildPairingInput(_pA, _pB, _pC, vkx, vky);

        // Call ecPairing precompile
        return _callPairing(pairingInput);
    }

    /**
     * @dev Compute vk_x = IC[0] + sum(IC[i] * pubSignal[i-1])
     */
    function _computeVkX(uint256[6] calldata _pubSignals) internal view returns (uint256 vkx, uint256 vky, bool success) {
        assembly {
            function g1_mulAcc(pRx, pRy, icx, icy, scalar) -> newRx, newRy, ok {
                let mIn := mload(0x40)

                // ecMul(IC, scalar)
                mstore(mIn, icx)
                mstore(add(mIn, 32), icy)
                mstore(add(mIn, 64), scalar)
                ok := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)
                if iszero(ok) { leave }

                // ecAdd(pR, result)
                mstore(add(mIn, 64), pRx)
                mstore(add(mIn, 96), pRy)
                ok := staticcall(sub(gas(), 2000), 6, mIn, 128, mIn, 64)
                if iszero(ok) { leave }

                newRx := mload(mIn)
                newRy := mload(add(mIn, 32))
            }

            let vk_x := IC0x
            let vk_y := IC0y
            let ok := 1

            vk_x, vk_y, ok := g1_mulAcc(vk_x, vk_y, IC1x, IC1y, calldataload(add(_pubSignals, 0)))
            if iszero(ok) { mstore(0, 0) mstore(32, 0) mstore(64, 0) return(0, 96) }

            vk_x, vk_y, ok := g1_mulAcc(vk_x, vk_y, IC2x, IC2y, calldataload(add(_pubSignals, 32)))
            if iszero(ok) { mstore(0, 0) mstore(32, 0) mstore(64, 0) return(0, 96) }

            vk_x, vk_y, ok := g1_mulAcc(vk_x, vk_y, IC3x, IC3y, calldataload(add(_pubSignals, 64)))
            if iszero(ok) { mstore(0, 0) mstore(32, 0) mstore(64, 0) return(0, 96) }

            vk_x, vk_y, ok := g1_mulAcc(vk_x, vk_y, IC4x, IC4y, calldataload(add(_pubSignals, 96)))
            if iszero(ok) { mstore(0, 0) mstore(32, 0) mstore(64, 0) return(0, 96) }

            vk_x, vk_y, ok := g1_mulAcc(vk_x, vk_y, IC5x, IC5y, calldataload(add(_pubSignals, 128)))
            if iszero(ok) { mstore(0, 0) mstore(32, 0) mstore(64, 0) return(0, 96) }

            vk_x, vk_y, ok := g1_mulAcc(vk_x, vk_y, IC6x, IC6y, calldataload(add(_pubSignals, 160)))
            if iszero(ok) { mstore(0, 0) mstore(32, 0) mstore(64, 0) return(0, 96) }

            vkx := vk_x
            vky := vk_y
            success := ok
        }
    }

    /**
     * @dev Build pairing input using bytes memory allocation (zkEVM compatible)
     */
    function _buildPairingInput(
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256 vkx,
        uint256 vky
    ) internal pure returns (bytes memory pairingInput) {
        pairingInput = new bytes(768);

        // Compute -A.y
        uint256 negAy = (q - _pA[1]) % q;

        assembly {
            let ptr := add(pairingInput, 32)

            // Pair 1: -A, B
            mstore(ptr, calldataload(add(_pA, 0)))           // -A.x
            mstore(add(ptr, 32), negAy)                       // -A.y (negated)
            mstore(add(ptr, 64), calldataload(add(_pB, 0)))   // B[0][0]
            mstore(add(ptr, 96), calldataload(add(_pB, 32)))  // B[0][1]
            mstore(add(ptr, 128), calldataload(add(_pB, 64))) // B[1][0]
            mstore(add(ptr, 160), calldataload(add(_pB, 96))) // B[1][1]

            // Pair 2: alpha, beta
            mstore(add(ptr, 192), alphax)
            mstore(add(ptr, 224), alphay)
            mstore(add(ptr, 256), betax1)
            mstore(add(ptr, 288), betax2)
            mstore(add(ptr, 320), betay1)
            mstore(add(ptr, 352), betay2)

            // Pair 3: vk_x, gamma
            mstore(add(ptr, 384), vkx)
            mstore(add(ptr, 416), vky)
            mstore(add(ptr, 448), gammax1)
            mstore(add(ptr, 480), gammax2)
            mstore(add(ptr, 512), gammay1)
            mstore(add(ptr, 544), gammay2)

            // Pair 4: C, delta
            mstore(add(ptr, 576), calldataload(add(_pC, 0)))
            mstore(add(ptr, 608), calldataload(add(_pC, 32)))
            mstore(add(ptr, 640), deltax1)
            mstore(add(ptr, 672), deltax2)
            mstore(add(ptr, 704), deltay1)
            mstore(add(ptr, 736), deltay2)
        }
    }

    /**
     * @dev Call ecPairing precompile with bytes memory input
     */
    function _callPairing(bytes memory pairingInput) internal view returns (bool) {
        bool success;
        uint256 result;

        assembly {
            let ptr := add(pairingInput, 32)
            let len := mload(pairingInput)
            success := staticcall(sub(gas(), 2000), 8, ptr, len, ptr, 0x20)
            result := mload(ptr)
        }

        return success && (result == 1);
    }
}
