// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title RedeemVerifierDebug
 * @notice Debug version of RedeemVerifier that exposes intermediate computations
 */
contract RedeemVerifierDebug {
    // Scalar field size
    uint256 constant r    = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // Base field size
    uint256 constant q   = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // Verification Key data (same as RedeemVerifier)
    uint256 constant alphax  = 20491192805390485299153009773594534940189261866228447918068658471970481763042;
    uint256 constant alphay  = 9383485363053290200918347156157836566562967994039712273449902621266178545958;
    uint256 constant betax1  = 4252822878758300859123897981450591353533073413197771768651442665752259397132;
    uint256 constant betax2  = 6375614351688725206403948262868962793625744043794305715222011528459656738731;
    uint256 constant betay1  = 21847035105528745403288232691147584728191162732299865338377159692350059136679;
    uint256 constant betay2  = 10505242626370262277552901082094356697409835680220590971873171140371331206856;
    uint256 constant gammax1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant gammax2 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant gammay1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant gammay2 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;
    uint256 constant deltax1 = 20350888953504529292581957091747121845563752736971104059618323202218945714590;
    uint256 constant deltax2 = 8583081352743229799300385965312194134924660539175052034339807229471068507088;
    uint256 constant deltay1 = 2592085192013015013867798842170414597918537878369062236649848723791766887621;
    uint256 constant deltay2 = 11465217057375663758956123966589569771281571929934660615304689272071623139794;

    uint256 constant IC0x = 4660105224062536442592866842932767992502719645364308146262623643842326122865;
    uint256 constant IC0y = 17276901730849178086213024785125128610553839494895313238582016803949795804802;
    uint256 constant IC1x = 10320827842497404403725324583763518947938473681109509213221447686170297527349;
    uint256 constant IC1y = 6187173621915260736338747049934887844961698620531672792634685378438750676349;
    uint256 constant IC2x = 17542082800098777139901493985535836451893342617951008250429429064246556539398;
    uint256 constant IC2y = 13627564828478472787962950403094034729954196587517178410134804019198739094179;
    uint256 constant IC3x = 9539374540367541168128243720672631410190128354841127145109735248299159914024;
    uint256 constant IC3y = 14404186048576416489427444347784772541493914545749661367331342876857874070171;
    uint256 constant IC4x = 1743148767838639168062519156339511069182684664034038434564582669398850074469;
    uint256 constant IC4y = 10782048529733657836688691187298319781562120235098775243385721026535854273587;
    uint256 constant IC5x = 6306198342163219331115614665632367283309042802375632509921127761862511259523;
    uint256 constant IC5y = 12748624647856286760174855962829479938531149270253081805613420859213557746483;
    uint256 constant IC6x = 20629243252197495532357678917970863049585519289991248466635865876780586859068;
    uint256 constant IC6y = 10914819839403061375513758084743037691038967452577598178075977991459989620682;

    /**
     * @notice Compute vk_x and return it for comparison
     */
    function computeVkX(uint256[6] calldata _pubSignals) public view returns (uint256 vkx, uint256 vky, bool success) {
        assembly {
            function g1_mulAcc(pRx, pRy, icx, icy, scalar) -> newRx, newRy, ok {
                let mIn := mload(0x40)

                // First: ecMul(IC, scalar)
                mstore(mIn, icx)
                mstore(add(mIn, 32), icy)
                mstore(add(mIn, 64), scalar)
                ok := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)
                if iszero(ok) { leave }

                // Then: ecAdd(pR, result)
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
     * @notice Build pairing input and return it for inspection
     */
    function buildPairingInput(
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[6] calldata _pubSignals
    ) public view returns (bytes memory pairingInput, uint256 vkx, uint256 vky) {
        (vkx, vky, ) = computeVkX(_pubSignals);

        // Build pairing input exactly as the verifier does
        pairingInput = new bytes(768);

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
     * @notice Call pairing precompile directly with constructed input
     */
    function callPairingDirect(bytes memory pairingInput) public view returns (bool success, uint256 result) {
        assembly {
            let ptr := add(pairingInput, 32)
            let len := mload(pairingInput)
            success := staticcall(sub(gas(), 2000), 8, ptr, len, ptr, 0x20)
            result := mload(ptr)
        }
    }

    /**
     * @notice Full verification with debug info
     */
    function verifyWithDebug(
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[6] calldata _pubSignals
    ) public view returns (
        bool isValid,
        uint256 vkx,
        uint256 vky,
        bool pairingSuccess,
        uint256 pairingResult
    ) {
        (bytes memory pairingInput, uint256 _vkx, uint256 _vky) = buildPairingInput(_pA, _pB, _pC, _pubSignals);
        vkx = _vkx;
        vky = _vky;
        (pairingSuccess, pairingResult) = callPairingDirect(pairingInput);
        isValid = pairingSuccess && (pairingResult == 1);
    }
}
