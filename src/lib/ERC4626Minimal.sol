// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "./SafeTransferLib.sol";
import {FixedPointMathLib} from "./FixedPointMathLib.sol";

/**
 * @title ERC4626Minimal
 * @notice Minimal ERC-4626 implementation optimized for USDC (6 decimals)
 * @dev Based on Solmate's ERC4626 with adjustments for proper rounding
 * @author Modified from Solmate (https://github.com/transmissions11/solmate)
 */
abstract contract ERC4626Minimal is IERC20 {
    using SafeTransferLib for IERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable asset;
    uint8 private immutable _decimals;

    constructor(IERC20 _asset, string memory _name, string memory _symbol) {
        asset = _asset;
        _decimals = _asset.decimals();
        
        name = _name;
        symbol = _symbol;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 STORAGE/LOGIC
    //////////////////////////////////////////////////////////////*/

    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual returns (uint256);

    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }

    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }

    function previewWithdraw(uint256 assets) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : assets.mulDivUp(supply, totalAssets());
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT/WITHDRAWAL LIMITS
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf[owner];
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(uint256 assets, uint256 shares) internal virtual {}
    function afterDeposit(uint256 assets, uint256 shares) internal virtual {}

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) public virtual returns (uint256 shares) {
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        afterDeposit(assets, shares);
    }

    function mint(uint256 shares, address receiver) public virtual returns (uint256 assets) {
        assets = previewMint(shares);
        
        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        afterDeposit(assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256 shares) {
        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        beforeWithdraw(assets, shares);
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        asset.safeTransfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        asset.safeTransfer(receiver, assets);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL MINT/BURN
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        unchecked {
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }
}