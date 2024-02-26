// SPDX-License-Identifier: MIT
//0x5744Cbf430D99456a0A8771208b674F27f8EF0Fb
//0x5c6c0d2386e3352356c3ab84434fafb5ea067ac2678a38a338c4a69ddc4bdb0c
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./FlashLoan.sol";

/**
 * @title Stabilizer USD
 * @author Stabilizer
 * @notice A fully decentralized stablecoin without bridges
 * @dev CR is used to abbreviate "Collateral Ratio"
 */
contract StabilizerUSD is Ownable(msg.sender), stabilizerFlashLoan {
    // <-- CONFIG -->
    IPyth public pyth;
    bytes32 public priceId;
    uint256 currentMinCR = 1200;
    uint256 minLoanAmount = 250 ether;

    // <-- ERRORS -->
    error InvalidInsertPosition();
    error NoOpenLoan();
    error InsufficientBalance();
    error InsufficientCollateral();
    error NotBelowCR();
    error UnderMinLoanAmount();

    // <-- MODIFIERS -->
    modifier exists(address _user) {
        if (data.loans[_user].ETH == 0) revert NoOpenLoan();
        _;
    }

    constructor(address _pyth, bytes32 _priceId) {
        pyth = IPyth(_pyth);
        priceId = _priceId;
    }

    struct Loan {
        uint256 USDS; // Amount of USDS loaned out
        uint256 ETH; // Amount of collateral in native token
        address previousLoan; // Loan with a lower liquidation price ("worse")
        address nextLoan; // Loan with a higher liquidation price ("better")
        uint256 maxMinCR;
    }

    struct Data {
        address first; // Lowest liquidation price ("worst")
        address last; // Highest liquidation price ("best")
        uint256 length; // Total number of active loans
        mapping(address => Loan) loans; // (user -> loan)
    }

    struct Price {
        uint256 fee;
        uint256 price;
    }

    Data public data;

    /**
     * @dev Initiate a loan under the account of msg.sender.
     * @param _USDS Amount of USDS that the users would like to loan
     * @param _previousLoan Address of loan with a directly smaller collateral ratio
     * @param _nextLoan Address of loan with a directly larger collateral ratio
     * @param priceUpdateData PYTH priceUpdateData
     */
    function openLoan(
        uint256 _USDS,
        address _previousLoan,
        address _nextLoan,
        bytes[] calldata priceUpdateData
    ) public payable {
        Price memory _price = getPrice(priceUpdateData);
        uint256 fee = _price.fee;
        uint256 price = _price.price;

        uint256 value = ((msg.value - fee) * price) / 10**18;

        if (_USDS < minLoanAmount) revert UnderMinLoanAmount();
        if (_USDS * currentMinCR > value * 10**3)
            revert InsufficientCollateral();

        insert(_USDS, msg.value - fee, _previousLoan, _nextLoan, currentMinCR);
        _mint(msg.sender, _USDS);
    }

    /**
     * @dev Add USDS debt or collateral to the loan.
     * @param _USDS Amount of USDS that the users would like to loan
     * @param _previousLoan Address of loan with a directly smaller collateral ratio
     * @param _nextLoan Address of loan with a directly larger collateral ratio
     * @param priceUpdateData PYTH priceUpdateData
     */
    function add(
        uint256 _USDS,
        address _previousLoan,
        address _nextLoan,
        bytes[] calldata priceUpdateData
    ) public payable exists(msg.sender) {
        Price memory _price = getPrice(priceUpdateData);
        uint256 fee = _price.fee;
        uint256 price = _price.price;

        if (_USDS == 0 && msg.value < fee) revert InvalidValue();

        uint256 newUSDSValue = data.loans[msg.sender].USDS + _USDS;
        uint256 newETHValue = data.loans[msg.sender].ETH + (msg.value - fee);
        uint256 maxMinCR = data.loans[msg.sender].maxMinCR;

        uint256 minCR = getMinCR(msg.sender);

        if (newUSDSValue < minLoanAmount) revert UnderMinLoanAmount();
        uint256 value = (newETHValue * price) / 10**18;

        if (newUSDSValue * minCR > value * 10**3)
            revert InsufficientCollateral();

        remove(msg.sender);
        insert(newUSDSValue, newETHValue, _previousLoan, _nextLoan, maxMinCR);
        _mint(msg.sender, _USDS);
    }

    function subtract(
        uint256 _USDS,
        uint256 _ETH,
        address _previousLoan,
        address _nextLoan,
        bytes[] calldata priceUpdateData
    ) public exists(msg.sender) {
        if (_USDS == 0 && _ETH == 0) revert InvalidValue();
        if (_USDS > data.loans[msg.sender].USDS) revert InvalidValue();
        if (_USDS > balanceOf(msg.sender)) revert InsufficientBalance();
        if (_ETH > data.loans[msg.sender].ETH) revert InvalidValue();

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
            uint256 maxMinCR = data.loans[msg.sender].maxMinCR;

            if (newUSDSValue < minLoanAmount) revert UnderMinLoanAmount();
            uint256 value = (newETHValue * price) / 10**18;
            uint256 minCR = getMinCR(msg.sender);

            if (_USDS * minCR > value * 10**3) revert InsufficientCollateral();

            _burn(msg.sender, _USDS);
            remove(msg.sender);
            insert(
                newUSDSValue,
                newETHValue,
                _previousLoan,
                _nextLoan,
                maxMinCR
            );
            (bool sent, ) = payable(msg.sender).call{value: _ETH}("");
            if (!sent) revert SendFailure();
        }
    }

    function liquidate(
        address _user,
        uint256 _USDS,
        bytes[] calldata priceUpdateData
    ) public exists(_user) {
        Price memory _price = getPrice(priceUpdateData);
        uint256 fee = _price.fee;
        uint256 price = _price.price;

        uint256 value = (data.loans[_user].ETH * price) / 10**18;

        uint256 minCR = getMinCR(_user);

        uint256 CR = (value * 10**3) / data.loans[_user].USDS;

        if (CR >= minCR) revert NotBelowCR();
        if (_USDS > balanceOf(msg.sender)) revert InsufficientBalance();

        uint256 loanUSDS = data.loans[_user].USDS;
        uint256 loanETH = data.loans[_user].ETH;

        if (_USDS == loanUSDS) {
            _burn(msg.sender, _USDS);
            uint256 payment = loanETH - fee;
            remove(_user);
            (bool sent, ) = payable(msg.sender).call{value: payment}("");
            if (!sent) revert SendFailure();
        } else {
            if (loanUSDS - _USDS < minLoanAmount) revert UnderMinLoanAmount();
            _burn(msg.sender, _USDS);
            uint256 percentageOfDebt = (_USDS * 10**6) / loanUSDS;
            uint256 payment = (percentageOfDebt * loanETH) /
                10**6;
            data.loans[_user].ETH -= payment;
            data.loans[_user].USDS -= _USDS;
            (bool sent, ) = payable(msg.sender).call{value: payment}("");
            if (!sent) revert SendFailure();
        }
    }

    function redeem(uint256 _USDS) public {}

    function insert(
        uint256 _USDS,
        uint256 _ETH,
        address _previousLoan,
        address _nextLoan,
        uint256 maxMinCR
    ) internal {
        uint256 newUnpricedCR = (_USDS * 10**18) / _ETH;
        if (_previousLoan == address(0) && _nextLoan == address(0)) {
            // (0x0, 0x0) - User is saying there is no loans
            if (data.length != 0) revert InvalidInsertPosition();

            data.first = msg.sender;
            data.last = msg.sender;
        } else if (_previousLoan == address(0)) {
            // (0x0, _nextLoan) - User is saying their loan is equal to or has the lowest liquidation price
            if (
                data.first != _nextLoan ||
                getUnpricedCR(_nextLoan) < newUnpricedCR
            ) revert InvalidInsertPosition();

            data.loans[_nextLoan].previousLoan = msg.sender;
            data.loans[msg.sender].nextLoan = _nextLoan;
            data.first = msg.sender;
        } else if (_nextLoan == address(0)) {
            // (_previousLoan, 0x0) - User is saying their loan is equal to or has the highest liquidation price
            if (
                data.last != _previousLoan ||
                getUnpricedCR(_previousLoan) > newUnpricedCR
            ) revert InvalidInsertPosition();

            data.loans[_previousLoan].nextLoan = msg.sender;
            data.loans[msg.sender].previousLoan = _previousLoan;
            data.last = msg.sender;
        } else {
            // (_previousLoan, _nextLoan) - User is saying their loan is in the middle or equal to two other loans
            if (
                data.loans[_previousLoan].nextLoan != _nextLoan ||
                getUnpricedCR(_previousLoan) > newUnpricedCR ||
                getUnpricedCR(_nextLoan) < newUnpricedCR
            ) revert InvalidInsertPosition();

            data.loans[_previousLoan].nextLoan = msg.sender;
            data.loans[_nextLoan].previousLoan = msg.sender;
            data.loans[msg.sender].nextLoan = _nextLoan;
            data.loans[msg.sender].previousLoan = _previousLoan;
        }
        data.loans[msg.sender] = (
            Loan(_USDS, _ETH, _previousLoan, _nextLoan, maxMinCR)
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
        uint256 newUnpricedCR = (_USDS * 10**18) / _ETH;
        if (_previousLoan == address(0) && _nextLoan == address(0)) {
            // (0x0, 0x0) - User is saying there is no loans
            return (data.length == 0);
        } else if (_previousLoan == address(0)) {
            // (0x0, _nextLoan) - User is saying their loan is equal to or has the lowest liquidation price
            return (data.first == _nextLoan &&
                getUnpricedCR(_nextLoan) >= newUnpricedCR);
        } else if (_nextLoan == address(0)) {
            // (_previousLoan, 0x0) - User is saying their loan is equal to or has the highest liquidation price
            return (data.last == _previousLoan &&
                getUnpricedCR(_previousLoan) <= newUnpricedCR);
        } else {
            // (_previousLoan, _nextLoan) - User is saying their loan is in the middle or equal to two other loans
            return (data.loans[_previousLoan].nextLoan == _nextLoan &&
                getUnpricedCR(_previousLoan) <= newUnpricedCR &&
                getUnpricedCR(_nextLoan) >= newUnpricedCR);
        }
    }

    function getMinCR(address _user) public view returns (uint256) {
        uint256 maxMinCR = data.loans[_user].maxMinCR;
        if (maxMinCR > currentMinCR) {
            return currentMinCR;
        } else {
            return maxMinCR;
        }
    }

    function getUnpricedCR(address _user) public view returns (uint256) {
        return (data.loans[_user].USDS * 10**18) / data.loans[_user].ETH;
    }

    /*
     * @dev Returns the first loan in the list with the lowest liquidation price ("worst")
     */
    function getFirst() external view returns (address) {
        return data.first;
    }

    /*
     * @dev Returns the last loan in the list with the highest liquidation price ("best")
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
