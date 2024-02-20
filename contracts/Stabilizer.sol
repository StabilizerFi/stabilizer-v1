// SPDX-License-Identifier: MIT
//0x5744Cbf430D99456a0A8771208b674F27f8EF0Fb
//0x5c6c0d2386e3352356c3ab84434fafb5ea067ac2678a38a338c4a69ddc4bdb0c
pragma solidity ^0.8.20;

// ownership (will eventually be renounced)
import "@openzeppelin/contracts/access/Ownable.sol";
// pyth contracts
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
// testing contract (REMOVE IN PRODUCTION)
import "hardhat/console.sol";

import "./FlashLoan.sol";

contract StabilizerUSD is Ownable(msg.sender), stabilizerFlashLoan {
    // Pyth config
    IPyth public pyth; // Pyth contract address
    bytes32 public priceId; // Pyth price id of (collateral/stable)

    // Other config
    uint256 minimumLiquidationProfit = 1 ether; // Maximum profit for liquidators, minimum profit once loan can be liquidated, in terms of stable

    constructor(address _pyth, bytes32 _priceId)
    {
        pyth = IPyth(_pyth);
        priceId = _priceId;
    }

    struct Loan {
        uint256 USDS; // Amount of USDS loaned out
        uint256 ETH; // Amount of collateral in native token
        uint256 priceToLiquidate; // Price in which if the price of the native token falls under the loan can be liquidated
        address previousLoan; // Loan with a lower liquidation price ("better")
        address nextLoan; // Loan with a higher liquidation price ("worse")
    }

    struct Data {
        address first; // Lowest liquidation price ("best")
        address last; // Highest liquidation price ("worst")
        uint256 length; // Total number of active loans
        mapping(address => Loan) loans; // (user -> loan)
    }

    Data public data; // All data

    function openLoan(
        uint256 _USDS,
        address _previousLoan,
        address _nextLoan,
        bytes[] calldata priceUpdateData
    ) public payable {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        PythStructs.Price memory currentPrice = pyth.getPrice(priceId);

        uint256 price = convertToUint(currentPrice, 18);

        require(
            _USDS > 0 && msg.value > 0,
            "Stabilizer V1: Values must be non-zero."
        );
        require(
            getMinimumCollateral(_USDS) <= getUSDValue(msg.value - fee, price),
            "Stabilizer V1: Collateral is not sufficient."
        );
        addLoan(_USDS, msg.value - fee, _previousLoan, _nextLoan);
        _mint(msg.sender, _USDS);
    }

    function addLoan(
        uint256 _USDS,
        uint256 _ETH,
        address _previousLoan,
        address _nextLoan
    ) internal {
        uint256 newPriceToLiquidate = getPriceToLiquidate(_USDS, _ETH);
        if (_previousLoan == address(0) && _nextLoan == address(0)) {
            // (0x0, 0x0) - User is saying there is no loans
            require(
                data.length == 0,
                "Stabilizer V1: Sorted loan IDs are invalid."
            );
            data.first = msg.sender;
            data.last = msg.sender;
        } else if (_previousLoan == address(0)) {
            // (0x0, _nextLoan) - User is saying their loan is equal to or has the lowest liquidation price
            require(
                data.first == _nextLoan &&
                    data.loans[_nextLoan].priceToLiquidate >=
                    newPriceToLiquidate,
                "Stabilizer V1: Sorted loan IDs are invalid."
            );
            data.loans[_nextLoan].previousLoan = msg.sender;
            data.loans[msg.sender].nextLoan = _nextLoan;
            data.first = msg.sender;
        } else if (_nextLoan == address(0)) {
            // (_previousLoan, 0x0) - User is saying their loan is equal to or has the highest liquidation price
            require(
                data.last == _previousLoan &&
                    data.loans[_previousLoan].priceToLiquidate <=
                    newPriceToLiquidate,
                "Stabilizer V1: Sorted loan IDs are invalid."
            );
            data.loans[_previousLoan].nextLoan = msg.sender;
            data.loans[msg.sender].previousLoan = _previousLoan;
            data.last = msg.sender;
        } else {
            // (_previousLoan, _nextLoan) - User is saying their loan is in the middle or equal to two other loans
            require(
                data.loans[_previousLoan].nextLoan == _nextLoan &&
                    data.loans[_previousLoan].priceToLiquidate <=
                    newPriceToLiquidate &&
                    data.loans[_nextLoan].priceToLiquidate >=
                    newPriceToLiquidate,
                "Stabilizer V1: Sorted loan IDs are invalid."
            );
            data.loans[_previousLoan].nextLoan = msg.sender;
            data.loans[_nextLoan].previousLoan = msg.sender;
            data.loans[msg.sender].nextLoan = _nextLoan;
            data.loans[msg.sender].previousLoan = _previousLoan;
        }
        data.loans[msg.sender] = (
            Loan(_USDS, _ETH, newPriceToLiquidate, _previousLoan, _nextLoan)
        );
        data.length += 1;
    }

    function payLoan(uint256 _USDS) public {
        require(
            balanceOf(msg.sender) >= _USDS,
            "Stabilizer V1: Insufficient USDS."
        );
        require(_USDS != 0, "Stabilizer V1: USDS must be non-zero.");
        require(
            data.loans[msg.sender].USDS >= _USDS,
            "Stabilizer V1: Payment must be less than or equal to debt."
        );
        require(data.loans[msg.sender].ETH != 0, "Stabilizer V1: No CDP open.");
        data.loans[msg.sender].USDS -= _USDS;
        if (data.loans[msg.sender].USDS == 0) {
            uint256 etherToPay = data.loans[msg.sender].ETH;
            data.loans[msg.sender].ETH = 0;
            payable(msg.sender).transfer(etherToPay);
        }
    }

    function liquidateLoan() public {}

    function redeemEther(uint256 _USDS) public {}


    // View/pure functions
    function getLoanDetails(address user) public view returns (Loan memory) {
        return data.loans[user];
    }

    // Utility view/pure functions
    function findInsertPosition(
        uint256 _USDS,
        uint256 _ETH,
        address _nextLoan
    ) external view returns (address, address) {
        // Interface will call this externally (so gas is not used)
        address nextLoan = _nextLoan;
        address previousLoan = data.loans[nextLoan].previousLoan;

        // Descend the list until we reach the end or until we find a valid insert position
        while (
            previousLoan != address(0) &&
            !validInsertPosition(_USDS, _ETH, previousLoan, nextLoan)
        ) {
            previousLoan = data.loans[previousLoan].previousLoan;
            nextLoan = data.loans[previousLoan].nextLoan;
        }

        return (previousLoan, nextLoan);
    }

    function validInsertPosition(
        uint256 _USDS,
        uint256 _ETH,
        address _previousLoan,
        address _nextLoan
    ) public view returns (bool) {
        uint256 newPriceToLiquidate = getPriceToLiquidate(_USDS, _ETH);
        if (_previousLoan == address(0) && _nextLoan == address(0)) {
            // (0x0, 0x0) - User is saying there is no loans
            return (data.length == 0);
        } else if (_previousLoan == address(0)) {
            // (0x0, _nextLoan) - User is saying their loan is equal to or has the lowest liquidation price
            return (data.first == _nextLoan &&
                data.loans[_nextLoan].priceToLiquidate >= newPriceToLiquidate);
        } else if (_nextLoan == address(0)) {
            // (_previousLoan, 0x0) - User is saying their loan is equal to or has the highest liquidation price
            return (data.last == _previousLoan &&
                data.loans[_previousLoan].priceToLiquidate <=
                newPriceToLiquidate);
        } else {
            // (_previousLoan, _nextLoan) - User is saying their loan is in the middle or equal to two other loans
            return (data.loans[_previousLoan].nextLoan == _nextLoan &&
                data.loans[_previousLoan].priceToLiquidate <=
                newPriceToLiquidate &&
                data.loans[_nextLoan].priceToLiquidate >= newPriceToLiquidate);
        }
    }

    function getPriceToLiquidate(uint256 _USDS, uint256 _ETH)
        public
        view
        returns (uint256)
    {
        // returns the maximum price of ETH in relation to USDS for a loan to be liquidated
        return (((getMinimumCollateral(_USDS))) * 10**18) / _ETH;
    }

    function getMinimumCollateral(uint256 _USDS) public view returns (uint256) {
        // returns the minimum amount of collateral in terms of the stable
        uint256 minimumCollateral = (_USDS + minimumLiquidationProfit);
        if (minimumCollateral <= (_USDS * 11) / 10) {
            minimumCollateral = (_USDS * 11) / 10;
        }
        return (minimumCollateral);
    }

    function getUSDValue(uint256 _ETH, uint256 _price)
        internal
        pure
        returns (uint256)
    {
        // (10**18 * 10**18) / 10**18 = 10**18
        return ((_ETH * _price) / 10**18);
    }

    function convertToUint(PythStructs.Price memory price, uint8 targetDecimals)
        private
        pure
        returns (uint256)
    {
        // Converts Pyth price into a more readable format
        if (price.price < 0 || price.expo > 0 || price.expo < -255) {
            revert();
        }

        uint8 priceDecimals = uint8(uint32(-1 * price.expo));

        if (targetDecimals >= priceDecimals) {
            return
                uint256(uint64(price.price)) *
                10**uint32(targetDecimals - priceDecimals);
        } else {
            return
                uint256(uint64(price.price)) /
                10**uint32(priceDecimals - targetDecimals);
        }
    }
}
