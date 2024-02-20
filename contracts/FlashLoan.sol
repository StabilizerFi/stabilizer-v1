// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract stabilizerFlashLoan is IERC3156FlashLender, ERC20 {
    // Fee is FlashLoanFee / 10000
    uint256 public USDSFlashLoanFee = 0;
    uint256 public ETHFlashLoanFee = 1;
    mapping(address => uint256) internal flashLoanDebt;

    constructor() ERC20("Stabilizer USD", "USDS") {}

    error InvalidContract();
    error InvalidValue();
    error CallbackError();
    error SendFailure();
    error NotPayedBack(uint256 debt);

    function payFlashLoanDebt() external payable {
        if (msg.value != 0) revert InvalidValue();
        if (flashLoanDebt[msg.sender] < msg.value) revert InvalidValue();
        flashLoanDebt[msg.sender] -= msg.value;
    }

    /**
     * @dev The amount of currency available to be lent.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token) external view returns (uint256) {
        if (token == address(this)) {
            return type(uint256).max;
        } else if (token == address(0)) {
            return address(this).balance;
        } else {
            revert InvalidContract();
        }
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function _flashFee(address token, uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (token == address(this)) {
            return (amount * USDSFlashLoanFee) / 10000;
        } else if (token == address(0)) {
            return (amount * ETHFlashLoanFee) / 10000;
        } else {
            revert InvalidContract();
        }
    }

    /**
     * @dev Returns the amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 amount)
        external
        view
        returns (uint256)
    {
        return _flashFee(token, amount);
    }

    /**
     * @dev Initiate a flash loan.
     * @param receiver The receiver of the tokens in the loan, and the receiver of the callback.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        if (token == address(this)) {
            uint256 fee = _flashFee(token, amount);
            _mint(msg.sender, amount);
            if (
                receiver.onFlashLoan(msg.sender, token, amount, fee, data) !=
                keccak256("ERC3156FlashBorrower.onFlashLoan")
            ) revert CallbackError();
            _burn(msg.sender, amount + fee);
            return true;
        } else if (token == address(0)) {
            uint256 fee = _flashFee(token, amount);
            flashLoanDebt[msg.sender] += amount + fee;
            (bool sent, ) = payable(msg.sender).call{value: amount}("");
            if (!sent) revert SendFailure();
            if (
                receiver.onFlashLoan(msg.sender, token, amount, fee, data) !=
                keccak256("ERC3156FlashBorrower.onFlashLoan")
            ) revert CallbackError();
            if (flashLoanDebt[msg.sender] != 0) revert NotPayedBack(flashLoanDebt[msg.sender]);
            return true;
        } else {
            revert InvalidContract();
        }
    }
}
