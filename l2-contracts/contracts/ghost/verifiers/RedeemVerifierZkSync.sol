// SPDX-License-Identifier: GPL-3.0
/*
    ZKsync Era compatible Groth16 verifier for Ghost Protocol redeem circuit.

    IMPORTANT: This verifier is modified from the standard snarkjs output to work
    with ZKsync Era's ecPairing precompile which expects G2 points in
    (x_imaginary, x_real, y_imaginary, y_real) order instead of EIP-197's
    (x_real, x_imaginary, y_real, y_imaginary) order.

    The verification key G2 coordinates (beta, gamma, delta) have been swapped
    accordingly: x1 and x2 are swapped, y1 and y2 are swapped.
*/

pragma solidity 0.8.28;

contract RedeemVerifierZkSync {
    // Scalar field size
    uint256 constant r    = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // Base field size
    uint256 constant q   = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // Verification Key data
    // G1 points (alpha, IC) remain unchanged
    uint256 constant alphax  = 20491192805390485299153009773594534940189261866228447918068658471970481763042;
    uint256 constant alphay  = 9383485363053290200918347156157836566562967994039712273449902621266178545958;

    // G2 points: SWAPPED for ZKsync Era (x1↔x2, y1↔y2)
    // Original snarkjs:     betax1=4252..., betax2=6375..., betay1=21847..., betay2=10505...
    // ZKsync Era (swapped): betax1=6375..., betax2=4252..., betay1=10505..., betay2=21847...
    uint256 constant betax1  = 6375614351688725206403948262868962793625744043794305715222011528459656738731;  // was x2
    uint256 constant betax2  = 4252822878758300859123897981450591353533073413197771768651442665752259397132;  // was x1
    uint256 constant betay1  = 10505242626370262277552901082094356697409835680220590971873171140371331206856; // was y2
    uint256 constant betay2  = 21847035105528745403288232691147584728191162732299865338377159692350059136679; // was y1

    // gamma: SWAPPED for ZKsync Era
    // Original: gammax1=11559..., gammax2=10857..., gammay1=4082..., gammay2=8495...
    uint256 constant gammax1 = 10857046999023057135944570762232829481370756359578518086990519993285655852781; // was x2
    uint256 constant gammax2 = 11559732032986387107991004021392285783925812861821192530917403151452391805634; // was x1
    uint256 constant gammay1 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;  // was y2
    uint256 constant gammay2 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;  // was y1

    // delta: SWAPPED for ZKsync Era
    // Original: deltax1=20350..., deltax2=8583..., deltay1=2592..., deltay2=11465...
    uint256 constant deltax1 = 8583081352743229799300385965312194134924660539175052034339807229471068507088;  // was x2
    uint256 constant deltax2 = 20350888953504529292581957091747121845563752736971104059618323202218945714590; // was x1
    uint256 constant deltay1 = 11465217057375663758956123966589569771281571929934660615304689272071623139794; // was y2
    uint256 constant deltay2 = 2592085192013015013867798842170414597918537878369062236649848723791766887621;  // was y1

    // IC points (G1) remain unchanged
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


    // Memory data
    uint16 constant pVk = 0;
    uint16 constant pPairing = 128;

    uint16 constant pLastMem = 896;

    function verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[6] calldata _pubSignals) public view returns (bool) {
        assembly {
            function checkField(v) {
                if iszero(lt(v, r)) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }

            // G1 function to multiply a G1 value(x,y) to value in an address
            function g1_mulAccC(pR, x, y, s) {
                let success
                let mIn := mload(0x40)
                mstore(mIn, x)
                mstore(add(mIn, 32), y)
                mstore(add(mIn, 64), s)

                success := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }

                mstore(add(mIn, 64), mload(pR))
                mstore(add(mIn, 96), mload(add(pR, 32)))

                success := staticcall(sub(gas(), 2000), 6, mIn, 128, pR, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }

            function checkPairing(pA, pB, pC, pubSignals, pMem) -> isOk {
                let _pPairing := add(pMem, pPairing)
                let _pVk := add(pMem, pVk)

                mstore(_pVk, IC0x)
                mstore(add(_pVk, 32), IC0y)

                // Compute the linear combination vk_x

                g1_mulAccC(_pVk, IC1x, IC1y, calldataload(add(pubSignals, 0)))

                g1_mulAccC(_pVk, IC2x, IC2y, calldataload(add(pubSignals, 32)))

                g1_mulAccC(_pVk, IC3x, IC3y, calldataload(add(pubSignals, 64)))

                g1_mulAccC(_pVk, IC4x, IC4y, calldataload(add(pubSignals, 96)))

                g1_mulAccC(_pVk, IC5x, IC5y, calldataload(add(pubSignals, 128)))

                g1_mulAccC(_pVk, IC6x, IC6y, calldataload(add(pubSignals, 160)))


                // -A
                mstore(_pPairing, calldataload(pA))
                mstore(add(_pPairing, 32), mod(sub(q, calldataload(add(pA, 32))), q))

                // B - expects calldata already in ZKsync Era format (imaginary, real) from SDK
                mstore(add(_pPairing, 64), calldataload(pB))
                mstore(add(_pPairing, 96), calldataload(add(pB, 32)))
                mstore(add(_pPairing, 128), calldataload(add(pB, 64)))
                mstore(add(_pPairing, 160), calldataload(add(pB, 96)))

                // alpha1
                mstore(add(_pPairing, 192), alphax)
                mstore(add(_pPairing, 224), alphay)

                // beta2 - VK constants already swapped for ZKsync Era
                mstore(add(_pPairing, 256), betax1)
                mstore(add(_pPairing, 288), betax2)
                mstore(add(_pPairing, 320), betay1)
                mstore(add(_pPairing, 352), betay2)

                // vk_x
                mstore(add(_pPairing, 384), mload(add(pMem, pVk)))
                mstore(add(_pPairing, 416), mload(add(pMem, add(pVk, 32))))


                // gamma2 - VK constants already swapped for ZKsync Era
                mstore(add(_pPairing, 448), gammax1)
                mstore(add(_pPairing, 480), gammax2)
                mstore(add(_pPairing, 512), gammay1)
                mstore(add(_pPairing, 544), gammay2)

                // C
                mstore(add(_pPairing, 576), calldataload(pC))
                mstore(add(_pPairing, 608), calldataload(add(pC, 32)))

                // delta2 - VK constants already swapped for ZKsync Era
                mstore(add(_pPairing, 640), deltax1)
                mstore(add(_pPairing, 672), deltax2)
                mstore(add(_pPairing, 704), deltay1)
                mstore(add(_pPairing, 736), deltay2)


                let success := staticcall(sub(gas(), 2000), 8, _pPairing, 768, _pPairing, 0x20)

                isOk := and(success, mload(_pPairing))
            }

            let pMem := mload(0x40)
            mstore(0x40, add(pMem, pLastMem))

            // Validate that all evaluations in F

            checkField(calldataload(add(_pubSignals, 0)))

            checkField(calldataload(add(_pubSignals, 32)))

            checkField(calldataload(add(_pubSignals, 64)))

            checkField(calldataload(add(_pubSignals, 96)))

            checkField(calldataload(add(_pubSignals, 128)))

            checkField(calldataload(add(_pubSignals, 160)))


            // Validate all evaluations
            let isValid := checkPairing(_pA, _pB, _pC, _pubSignals, pMem)

            mstore(0, isValid)
             return(0, 0x20)
         }
     }
 }
