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

    error InvalidInsertPosition();
    error NoOpenLoan();
    error InsufficientBalance();
    error InsufficientCollateral();

    modifier exists() {
        if (data.loans[msg.sender].ETH == 0) revert NoOpenLoan();
        _;
    }

    constructor(address _pyth, bytes32 _priceId) {
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

    struct Price {
        uint256 fee;
        uint256 price;
    }

    Data public data; // All data

    function openLoan(
        uint256 _USDS,
        address _previousLoan,
        address _nextLoan,
        bytes[] calldata priceUpdateData
    ) public payable {
        Price memory _price = getPrice(priceUpdateData);
        uint256 fee = _price.fee;
        uint256 price = _price.price;

        if (_USDS > 0 || msg.value > fee) revert InvalidValue();
        if(getMinimumCollateral(_USDS) > getUSDValue(msg.value - fee, price)) revert InsufficientCollateral();
        insert(_USDS, msg.value - fee, _previousLoan, _nextLoan);
        _mint(msg.sender, _USDS);
    }

    function add(
        uint256 _USDS,
        address _previousLoan,
        address _nextLoan,
        bytes[] calldata priceUpdateData
    ) public payable exists {
        if (_USDS == 0 && msg.value == 0) revert InvalidValue();

        Price memory _price = getPrice(priceUpdateData);
        uint256 fee = _price.fee;
        uint256 price = _price.price;

        uint256 newUSDSValue = data.loans[msg.sender].USDS + _USDS;
        uint256 newETHValue = data.loans[msg.sender].ETH + (msg.value - fee);

        if(getMinimumCollateral(newUSDSValue) > getUSDValue(newETHValue, price)) revert InsufficientCollateral();

        remove(msg.sender);
        insert(_USDS, newETHValue, _previousLoan, _nextLoan);
        _mint(msg.sender, _USDS);
    }

    function subtract(
        uint256 _USDS,
        uint256 _ETH,
        address _previousLoan,
        address _nextLoan,
        bytes[] calldata priceUpdateData
    ) public exists {
        if (_USDS == 0 && _ETH == 0) revert InvalidValue();
        if (_USDS > data.loans[msg.sender].USDS) revert InvalidValue();
        if (_USDS > balanceOf(msg.sender)) revert InsufficientBalance();
        if (_ETH > data.loans[msg.sender].ETH) revert InsufficientBalance();

        if (_USDS == data.loans[msg.sender].USDS) {
            _burn(msg.sender, _USDS);
            uint256 amount = data.loans[msg.sender].ETH;
            remove(msg.sender);
            (bool sent, ) = payable(msg.sender).call{value: amount}("");
            if (!sent) revert SendFailure();
        } else {
            Price memory _price = getPrice(priceUpdateData);
            uint256 fee = _price.fee;
            uint256 price = _price.price;

            uint256 newUSDSValue = data.loans[msg.sender].USDS - _USDS;
            uint256 newETHValue = data.loans[msg.sender].ETH - (_ETH + fee);

            if(getMinimumCollateral(newUSDSValue) > getUSDValue(newETHValue, price)) revert InsufficientCollateral();

            _burn(msg.sender, _USDS);
            remove(msg.sender);
            insert(_USDS, newETHValue, _previousLoan, _nextLoan);
            (bool sent, ) = payable(msg.sender).call{value: _ETH}("");
            if (!sent) revert SendFailure();
        }
    }

    function liquidateLoan() public {}

    function redeem(uint256 _USDS) public {}

     function insert(
        uint256 _USDS,
        uint256 _ETH,
        address _previousLoan,
        address _nextLoan
    ) internal {
        uint256 newPriceToLiquidate = getPriceToLiquidate(_USDS, _ETH);
        if (_previousLoan == address(0) && _nextLoan == address(0)) {
            // (0x0, 0x0) - User is saying there is no loans
            if (data.length != 0) revert InvalidInsertPosition();

            data.first = msg.sender;
            data.last = msg.sender;
        } else if (_previousLoan == address(0)) {
            // (0x0, _nextLoan) - User is saying their loan is equal to or has the lowest liquidation price
            if (
                data.first != _nextLoan ||
                data.loans[_nextLoan].priceToLiquidate < newPriceToLiquidate
            ) revert InvalidInsertPosition();

            data.loans[_nextLoan].previousLoan = msg.sender;
            data.loans[msg.sender].nextLoan = _nextLoan;
            data.first = msg.sender;
        } else if (_nextLoan == address(0)) {
            // (_previousLoan, 0x0) - User is saying their loan is equal to or has the highest liquidation price
            if (
                data.last != _previousLoan ||
                data.loans[_previousLoan].priceToLiquidate > newPriceToLiquidate
            ) revert InvalidInsertPosition();

            data.loans[_previousLoan].nextLoan = msg.sender;
            data.loans[msg.sender].previousLoan = _previousLoan;
            data.last = msg.sender;
        } else {
            // (_previousLoan, _nextLoan) - User is saying their loan is in the middle or equal to two other loans
            if (
                data.loans[_previousLoan].nextLoan != _nextLoan ||
                data.loans[_previousLoan].priceToLiquidate >
                newPriceToLiquidate ||
                data.loans[_nextLoan].priceToLiquidate < newPriceToLiquidate
            ) revert InvalidInsertPosition();

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

    function remove(address _user) internal {
        if (data.length != 1) {
            if (_user == data.first) {
                data.first = data.loans[_user].nextLoan;
                data.loans[data.first].previousLoan = address(0);
            } else if (_user == data.last) {
                data.last = data.loans[_user].previousLoan;
                data.loans[data.last].nextLoan = address(0);
            } else {
                data.loans[data.loans[_user].previousLoan].nextLoan = data
                    .loans[_user]
                    .nextLoan;
                data.loans[data.loans[_user].nextLoan].previousLoan = data
                    .loans[_user]
                    .previousLoan;
            }
        } else {
            data.first = address(0);
            data.last = address(0);
        }
        delete data.loans[_user];
        data.length -= 1;
    }

    function getPrice(bytes[] calldata priceUpdateData)
        internal
        returns (Price memory)
    {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        PythStructs.Price memory currentPrice = pyth.getPrice(priceId);

        return (Price(fee, convertToUint(currentPrice, 18)));
    }

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

    /*
     * @dev Returns the price of the collateral in which the loan could be liquidated
     */
    function getPriceToLiquidate(uint256 _USDS, uint256 _ETH)
        public
        view
        returns (uint256)
    {
        return (((getMinimumCollateral(_USDS))) * 10**18) / _ETH;
    }

    /*
     * @dev Returns the minimum amount of collateral in terms of the stable
     */
    function getMinimumCollateral(uint256 _USDS) public view returns (uint256) {
        uint256 minimumCollateral = (_USDS + minimumLiquidationProfit);
        if (minimumCollateral <= (_USDS * 11) / 10) {
            minimumCollateral = (_USDS * 11) / 10;
        }
        return (minimumCollateral);
    }

    /*
     * @dev Returns the value of the collateral in terms of the stable
     */
    function getUSDValue(uint256 _ETH, uint256 _price)
        internal
        pure
        returns (uint256)
    {
        return ((_ETH * _price) / 10**18);
    }

    /*
     * @dev Returns the first loan in the list with the lowest liquidation price ("best")
     */
    function getFirst() external view returns (address) {
        return data.first;
    }

    /*
     * @dev Returns the last loan in the list with the highest liquidation price ("worst")
     */
    function getLast() external view returns (address) {
        return data.last;
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
