// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AccessController  
 * @notice Role-based access control for the stable yield vault system
 * @dev Minimal role system: OWNER (full control), KEEPER (operations), PAUSER (emergency)
 */
contract AccessController {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address public owner;
    mapping(bytes32 => mapping(address => bool)) private _roles;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        require(msg.sender == owner, "AccessController: caller is not owner");
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(hasRole(role, msg.sender), "AccessController: insufficient role");
        _;
    }

    modifier onlyOwnerOrRole(bytes32 role) {
        require(msg.sender == owner || hasRole(role, msg.sender), "AccessController: insufficient permissions");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        require(_owner != address(0), "AccessController: zero owner");
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    /*//////////////////////////////////////////////////////////////
                            ROLE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyOwner {
        require(account != address(0), "AccessController: zero account");
        require(!_roles[role][account], "AccessController: role already granted");
        
        _roles[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) external onlyOwner {
        require(_roles[role][account], "AccessController: role not granted");
        
        _roles[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }

    function renounceRole(bytes32 role) external {
        require(_roles[role][msg.sender], "AccessController: role not granted");
        
        _roles[role][msg.sender] = false;
        emit RoleRevoked(role, msg.sender, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "AccessController: zero new owner");
        require(newOwner != owner, "AccessController: same owner");
        
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }
}