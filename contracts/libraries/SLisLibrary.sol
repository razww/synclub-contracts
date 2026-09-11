//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

import {IStakeManager} from "../interfaces/IStakeManager.sol";

library SLisLibrary {
    function calculateFeeFromDailyProfit(
        uint256 _profit,
        uint256 _synFee,
        uint256 _decimals // 1e10
    ) public returns (uint256 _fee) {
        _fee = (_profit * _synFee) / _decimals;
    }

    function calculateFeeFromAPY(
        uint256 _principal,
        uint256 _annualRate,
        uint256 _decimals // 1e10
    ) public returns (uint256 _fee) {
        _fee = (_principal * _annualRate) / 365 / _decimals;
    }

    function calculateFee(uint256 _principal, uint256 _profit, uint256 _annualRate, uint256 _synFee, uint256 _decimals)
        public
        returns (uint256 _fee)
    {
        uint256 _feeFromAPY = calculateFeeFromAPY(_principal, _annualRate, _decimals);
        uint256 _feeFromProfit = calculateFeeFromDailyProfit(_profit, _synFee, _decimals);

        _fee = _feeFromAPY > _feeFromProfit ? _feeFromAPY : _feeFromProfit;
    }

    /**
     * @dev Largest index in the withdrawal queue that `_bnbAmount` can cover
     * @notice Lives here rather than in ListaStakeManager purely for bytecode budget: the manager
     *         keeps the selector and forwards, while this body is delegatecalled from the linked
     *         library and so does not count against its EIP-170 limit.
     */
    function binarySearchCoveredMaxIndex(
        IStakeManager.UserRequest[] storage withdrawalQueue,
        mapping(uint256 => uint256) storage requestIndexMap,
        uint256 nextConfirmedRequestUUID,
        uint256 _bnbAmount
    ) public view returns (uint256) {
        require(
            withdrawalQueue.length != 0 && withdrawalQueue[0].uuid <= nextConfirmedRequestUUID,
            "No new requests or old requests have not been fully covered"
        );
        if (nextConfirmedRequestUUID > withdrawalQueue[withdrawalQueue.length - 1].uuid) {
            // all requests have been covered
            return 0;
        }
        uint256 startIndex = requestIndexMap[nextConfirmedRequestUUID];
        uint256 endIndex = withdrawalQueue.length - 1;
        uint256 startAmount = withdrawalQueue[startIndex].amount;
        uint256 startTotalAmount = withdrawalQueue[startIndex].totalAmount;

        // covered all requests, which is the common scenario
        if (withdrawalQueue[endIndex].totalAmount - startTotalAmount + startAmount <= _bnbAmount) {
            return endIndex;
        }

        uint256 start = startIndex;
        uint256 end = endIndex;
        while (start <= end) {
            uint256 mid = (start + end) / 2; // startIndex <= mid <= endIndex

            uint256 nextAmount;
            if (mid < endIndex) {
                nextAmount = withdrawalQueue[mid + 1].totalAmount - startTotalAmount + startAmount;
            } else {
                // mid == endIndex
                nextAmount = withdrawalQueue[endIndex].totalAmount - startTotalAmount + startAmount;
            }
            uint256 currentAmount = withdrawalQueue[mid].totalAmount - startTotalAmount + startAmount;

            if (nextAmount > _bnbAmount && currentAmount <= _bnbAmount) {
                return mid;
            } else if (nextAmount <= _bnbAmount) {
                if (mid >= endIndex) {
                    return endIndex;
                }
                start = mid + 1;
            } else {
                if (mid <= startIndex) {
                    return startIndex;
                }
                end = mid - 1;
            }
        }

        return startIndex;
    }
}
