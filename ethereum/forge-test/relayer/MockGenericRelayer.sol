// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import {IWormholeRelayer} from "../../contracts/interfaces/relayer/IWormholeRelayer.sol";
import {IDelivery} from "../../contracts/interfaces/relayer/IDelivery.sol";
import {IWormholeRelayerInstructionParser} from "../../contracts/interfaces/relayer/IWormholeRelayerInstructionParser.sol";
import {IWormhole} from "../../contracts/interfaces/IWormhole.sol";
import {WormholeSimulator} from "./WormholeSimulator.sol";

import "../../contracts/libraries/external/BytesLib.sol";
import "forge-std/Vm.sol";

contract MockGenericRelayer {
    using BytesLib for bytes;

    IWormhole relayerWormhole;
    WormholeSimulator relayerWormholeSimulator;
    IWormholeRelayerInstructionParser parser;
    uint256 transactionIndex;

    address private constant VM_ADDRESS = address(bytes20(uint160(uint256(keccak256("hevm cheat code")))));

    Vm public constant vm = Vm(VM_ADDRESS);

    mapping(uint16 => address) wormholeRelayerContracts;

    mapping(uint16 => address) relayers;

    mapping(bytes32 => bytes[]) pastEncodedVMs;

    mapping(bytes32 => bytes) pastEncodedDeliveryVAA;

    constructor(address _wormhole, address _wormholeSimulator, address wormholeRelayer) {
        // deploy Wormhole

        relayerWormhole = IWormhole(_wormhole);
        relayerWormholeSimulator = WormholeSimulator(_wormholeSimulator);
        parser = IWormholeRelayerInstructionParser(wormholeRelayer);
        transactionIndex = 0;
    }

    function getPastEncodedVMs(uint16 chainId, uint64 deliveryVAASequence) public view returns (bytes[] memory) {
        return pastEncodedVMs[keccak256(abi.encodePacked(chainId, deliveryVAASequence))];
    }

    function getPastDeliveryVAA(uint16 chainId, uint64 deliveryVAASequence) public view returns (bytes memory) {
        return pastEncodedDeliveryVAA[keccak256(abi.encodePacked(chainId, deliveryVAASequence))];
    }

    function setInfo(uint16 chainId, uint64 deliveryVAASequence, bytes[] memory encodedVMs, bytes memory encodedDeliveryVAA) internal {
        pastEncodedVMs[keccak256(abi.encodePacked(chainId, deliveryVAASequence))] = encodedVMs;
        pastEncodedDeliveryVAA[keccak256(abi.encodePacked(chainId, deliveryVAASequence))] = encodedDeliveryVAA;
    }

    function setWormholeRelayerContract(uint16 chainId, address contractAddress) public {
        wormholeRelayerContracts[chainId] = contractAddress;
    }

    function setProviderDeliveryAddress(uint16 chainId, address deliveryAddress) public {
        relayers[chainId] = deliveryAddress;
    }

    function relay(uint16 chainId) public {
        relay(vm.getRecordedLogs(), chainId, bytes(""));
    }

    function vaaKeyMatchesVAA(IWormholeRelayer.VaaKey memory vaaKey, bytes memory signedVaa)
        internal
        view
        returns (bool)
    {
        IWormhole.VM memory parsedVaa = relayerWormhole.parseVM(signedVaa);
        if (vaaKey.infoType == IWormholeRelayer.VaaKeyType.EMITTER_SEQUENCE) {
            return
                (vaaKey.chainId == parsedVaa.emitterChainId) && (vaaKey.emitterAddress == parsedVaa.emitterAddress) && (vaaKey.sequence == parsedVaa.sequence);
        } else if (vaaKey.infoType == IWormholeRelayer.VaaKeyType.VAAHASH) {
            return (vaaKey.vaaHash == parsedVaa.hash);
        } else {
            return false;
        }
    }

    function relay(Vm.Log[] memory logs, uint16 chainId, bytes memory deliveryOverrides) public {
        Vm.Log[] memory entries = relayerWormholeSimulator.fetchWormholeMessageFromLog(logs);
        bytes[] memory encodedVMs = new bytes[](entries.length);
        for (uint256 i = 0; i < encodedVMs.length; i++) {
            encodedVMs[i] = relayerWormholeSimulator.fetchSignedMessageFromLogs(
                entries[i], chainId, address(uint160(uint256(bytes32(entries[i].topics[1]))))
            );
        }
        IWormhole.VM[] memory parsed = new IWormhole.VM[](encodedVMs.length);
        for (uint16 i = 0; i < encodedVMs.length; i++) {
            parsed[i] = relayerWormhole.parseVM(encodedVMs[i]);
        }
        for (uint16 i = 0; i < encodedVMs.length; i++) {
            if (
                parsed[i].emitterAddress == parser.toWormholeFormat(wormholeRelayerContracts[chainId])
                    && (parsed[i].emitterChainId == chainId)
            ) {
                genericRelay(encodedVMs[i], encodedVMs, parsed[i], deliveryOverrides);
            }
        }
    }

    function relay(uint16 chainId, bytes memory deliveryOverrides) public {
        relay(vm.getRecordedLogs(), chainId, deliveryOverrides);
    }

    function genericRelay(
        bytes memory encodedDeliveryVAA,
        bytes[] memory encodedVMs,
        IWormhole.VM memory parsedDeliveryVAA,
        bytes memory deliveryOverrides
    ) internal {
        uint8 payloadId = parsedDeliveryVAA.payload.toUint8(0);
        if (payloadId == 1) {
            IWormholeRelayerInstructionParser.DeliveryInstruction memory instruction =
                parser.decodeDeliveryInstruction(parsedDeliveryVAA.payload);

            bytes[] memory encodedVMsToBeDelivered = new bytes[](instruction.vaaKeys.length);

            for (uint8 i = 0; i < instruction.vaaKeys.length; i++) {
                for (uint8 j = 0; j < encodedVMs.length; j++) {
                    if (vaaKeyMatchesVAA(instruction.vaaKeys[i], encodedVMs[j])) {
                        encodedVMsToBeDelivered[i] = encodedVMs[j];
                        break;
                    }
                }
            }

            
                uint256 budget =
                    instruction.maximumRefundTarget + instruction.receiverValueTarget;

                uint16 targetChain = instruction.targetChain;
                IDelivery.TargetDeliveryParameters memory package = IDelivery.TargetDeliveryParameters({
                    encodedVMs: encodedVMsToBeDelivered,
                    encodedDeliveryVAA: encodedDeliveryVAA,
                    relayerRefundAddress: payable(relayers[targetChain]),
                    overrides:deliveryOverrides
                });

                vm.prank(relayers[targetChain]);
                IDelivery(wormholeRelayerContracts[targetChain]).deliver{value: budget}(package);
            
            setInfo(parsedDeliveryVAA.emitterChainId, parsedDeliveryVAA.sequence, encodedVMsToBeDelivered, encodedDeliveryVAA);
         } else if(payloadId == 2) {
            IWormholeRelayerInstructionParser.RedeliveryInstruction memory instruction =
                parser.decodeRedeliveryInstruction(parsedDeliveryVAA.payload);

            IWormholeRelayerInstructionParser.DeliveryOverride memory deliveryOverride = IWormholeRelayerInstructionParser.DeliveryOverride({
                gasLimit: instruction.executionParameters.gasLimit,
                maximumRefund: instruction.newMaximumRefundTarget,
                receiverValue: instruction.newReceiverValueTarget,
                redeliveryHash: parsedDeliveryVAA.hash
            });

            uint256 budget =
                    instruction.newMaximumRefundTarget + instruction.newReceiverValueTarget;

                bytes memory oldEncodedDeliveryVAA = getPastDeliveryVAA(instruction.key.chainId, instruction.key.sequence);
                bytes[] memory oldEncodedVMs = getPastEncodedVMs(instruction.key.chainId, instruction.key.sequence);

                uint16 targetChain = parser.decodeDeliveryInstruction(relayerWormhole.parseVM(oldEncodedDeliveryVAA).payload).targetChain;
                IDelivery.TargetDeliveryParameters memory package = IDelivery.TargetDeliveryParameters({
                    encodedVMs: oldEncodedVMs,
                    encodedDeliveryVAA: oldEncodedDeliveryVAA,
                    relayerRefundAddress: payable(relayers[targetChain]),
                    overrides: parser.encodeDeliveryOverride(deliveryOverride)
                });

                vm.prank(relayers[targetChain]);
                IDelivery(wormholeRelayerContracts[targetChain]).deliver{value: budget}(package);

        }
    
    }

}