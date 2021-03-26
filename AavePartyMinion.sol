// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.3;

interface IERC20 { // interface for erc20 approve/transfer
    function balanceOf(address who) external view returns (uint256);
    
    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);
    
    function approve(address spender, uint256 amount) external returns (bool);
}


contract ReentrancyGuard { // call wrapper for reentrancy check
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}


interface IMOLOCH { // brief interface for moloch dao v2

    function cancelProposal(uint256 proposalId) external;
    
    function depositToken() external view returns (address);
    
    function getProposalFlags(uint256 proposalId) external view returns (bool[6] memory);
    
    function getTotalLoot() external view returns (uint256); 
    
    function getTotalShares() external view returns (uint256); 
    
    function getUserTokenBalance(address user, address token) external view returns (uint256);
    
    function members(address user) external view returns (address, uint256, uint256, bool, uint256, uint256);
    
    function ragequit(uint256 sharesToBurn, uint256 lootToBurn) external; 

    function submitProposal(
        address applicant,
        uint256 sharesRequested,
        uint256 lootRequested,
        uint256 tributeOffered,
        address tributeToken,
        uint256 paymentRequested,
        address paymentToken,
        string calldata details
    ) external returns (uint256);
    
    function tokenWhitelist(address token) external view returns (bool);

    function updateDelegateKey(address newDelegateKey) external; 
    
    function userTokenBalances(address user, address token) external view returns (uint256);

    function withdrawBalance(address token, uint256 amount) external;
}

interface ILendingPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    
    function withdraw(address token, uint256 amount, address destination) external;
    
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
    
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralETH, 
        uint256 totalDebtETH, 
        uint256 availableBorrowsETH, 
        uint256 currentLiquidationThreshold, 
        uint256 ltv,
        uint256 healthFactor
    );
    
    function getReservesList() external view returns (address[] memory);
    
    function getAssetsPrices(address[] calldata _assets) external view returns(uint256[] memory);
}

interface IDebtToken {
    
    function approveDelegation(address delegatee, uint256 amount) external;
    
    function borrowAllowance(address fromUser, address toUser) external view returns (uint256);
    
    function mint(
        address user,
        address onBehalfOf,
        uint256 amount,
        uint256 rate
    ) external returns (bool);
    
    function principalBalanceOf(address user) external view returns (uint256);
    
    function getUserStableRate(address user) external view returns (uint256);

    function getAverageStableRate() external view returns (uint256);

    function getSupplyData() external view returns (uint256, uint256, uint256, uint40);
    
    function scaledBalanceOf(address user) external view returns (uint256);
    
    function getScaledUserBalanceAndSupply(address user) external view returns (uint256, uint256);
    
    function scaledTotalSupply() external view returns (uint256);
    
}


contract PoolPartyAaveMinion is Ownable, ReentrancyGuard {

    IMOLOCH public moloch;
    IERC20 public haus;
    
    address public dao; // dao that manages minion 
    address public aave; // Aave address
    address public feeAddress; //address for collecting fees
    uint256 public minionId; // ID to keep minions straight
    uint256 public feeFactor; // Fee Factor in BPs
    string public desc; //description of minion
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern

    mapping(uint256 => Action) public actions; // proposalId => Action
    mapping(uint256 => Funding) public fundings; // proposalId => Funding
    mapping(address => uint256) public deposits; // deposits to aave by token
    mapping(address => uint256) public loans; // loans taken out
    mapping(address => mapping(address => uint256)) public userDelegationAllowances;

    
    struct Action {
        uint256 value;
        address token;
        address to;
        address proposer;
        bool executed;
        bytes data;
    }
    
    struct Funding {
        address token;
        uint256 paymentRequested;
        address proposer;
        bool executed;
    }
    

    event ProposeAction(uint256 proposalId, address proposer);
    event ProposeFunding(uint256 proposalId, address proposer, address token, uint256 paymentRequested);
    event ExecuteAction(uint256 proposalId, address executor);
    event FundingExecuted(uint256 proposalId, address executor, address token, uint256 paymentWithdrawn);
    event DoWithdraw(address targetDao, address token, uint256 amount);
    event HausWithdraw(address token, uint256 amount);
    event PulledFunds(address token, uint256 amount);
    event RewardsClaimed(address currentDelegate, uint256 amount);
    event Canceled(uint256 proposalId, uint8 proposalType);
    event SetUberHaus(address uberHaus);

    
    modifier memberOnly() {
        require(isMember(msg.sender), "Minion::not member");
        _;
    }
    
    
    
    /*
     * @param _dao The address of the child dao joining UberHaus
     * @param _uberHaus The address of UberHaus dao
     * @param _Haus The address of the HAUS token
     * @param _delegateRewardFactor The percentage out of 10,000 that the delegate will recieve as a reward
     * @param _DESC Name or description of the minion
     */  
    
    function init(
        address _dao, 
        address _aave,
        address _feeAddress,
        uint256 _minionId,
        uint256 _feeFactor,
        string memory _desc
    )  public {
        require(_dao != address(0), "no 0x address");
        require(!initialized, "already initialized");

        moloch = IMOLOCH(_dao);
        dao = _dao;
        aave = _aave;
        feeAddress = _feeAddress;
        minionId = _minionId;
        feeFactor = _feeFactor;
        desc = _desc;
        initialized = true; 
    }
    
    //  -- Withdraw Functions --

    function doWithdraw(address targetDao, address token, uint256 amount) public memberOnly {
        // Withdraws funds from any Moloch (incl. UberHaus or the minion owner DAO) into this Minion
        require(IMOLOCH(targetDao).getUserTokenBalance(address(this), token) >= amount, "user balance < amount");
        IMOLOCH(targetDao).withdrawBalance(token, amount); // withdraw funds from DAO
        emit DoWithdraw(targetDao, token, amount);
    }
    
    
    function pullGuildFunds(address token, uint256 amount) external memberOnly {
        // Pulls tokens from the Minion into its master moloch 
        require(moloch.tokenWhitelist(token), "token !whitelisted by master dao");
        require(IERC20(token).balanceOf(address(this)) >= amount, "amount > balance");
        IERC20(token).transfer(address(moloch), amount);
        emit PulledFunds(token, amount);
    }
    
    
    //  -- Proposal Functions --
    
    function proposeAction(
        address actionTo,
        address token,
        uint256 actionValue,
        bytes calldata actionData,
        string calldata details
    ) external memberOnly returns (uint256) {
        // No calls to zero address allows us to check that proxy submitted
        // the proposal without getting the proposal struct from parent moloch
        require(actionTo != address(0), "invalid actionTo");

        uint256 proposalId = moloch.submitProposal(
            address(this),
            0,
            0,
            0,
            token,
            0,
            token,
            details
        );

        Action memory action = Action({
            value: actionValue,
            token: token,
            to: actionTo,
            proposer: msg.sender,
            executed: false,
            data: actionData
        });

        actions[proposalId] = action;
        
        // add more info to the event. 

        emit ProposeAction(proposalId, msg.sender);
        return proposalId;
    }

    function executeAction(uint256 proposalId) external returns (bytes memory) {
        Action storage action = actions[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);

        require(action.to != address(0), "invalid proposalId");
        require(!action.executed, "action executed");
        require(flags[2], "proposal not passed");

        // execute call
        actions[proposalId].executed = true;
        (bool success, bytes memory retData) = action.to.call{value: action.value}(action.data);
        require(success, "call failure");
        emit ExecuteAction(proposalId, msg.sender);
        return retData;
    }
    
    function fundMinion(
        address token,
        uint256 paymentRequested,
        string calldata details
    ) external memberOnly returns (uint256) {
        // No calls to zero address allows us to check that proxy submitted
        // the proposal without getting the proposal struct from parent moloch
        uint256 proposalId = moloch.submitProposal(
            address(this),
            0,
            0,
            0,
            token, // includes whitelisted token to avoid errors on DAO end
            paymentRequested,
            token,
            details
        );

        Funding memory funding = Funding({
        token: token,
        paymentRequested: paymentRequested,
        proposer: msg.sender,
        executed: false
        });

        fundings[proposalId] = funding;

        emit ProposeFunding(proposalId, msg.sender, token, paymentRequested);
        return proposalId;
    }

    function executeFunding(uint256 proposalId) external returns (uint256) {
        Funding storage funding = fundings[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);

        require(!funding.executed, "appointment already executed");
        require(flags[2], "proposal not passed");

        // execute call
        funding.executed = true;
        doWithdraw(address(moloch), funding.token, funding.paymentRequested);

        
        emit FundingExecuted(proposalId, msg.sender, funding.token, funding.paymentRequested);
        return funding.paymentRequested;
    }
    
    function cancelAction(uint256 _proposalId, uint8 _type) external {
        if(_type == 1){
            Action storage action = actions[_proposalId];
            require(msg.sender == action.proposer, "not proposer");
            delete actions[_proposalId];
        } else if (_type == 2){
            Funding storage funding = fundings[_proposalId];
            require(msg.sender == funding.proposer, "not proposer");
            delete fundings[_proposalId];
        } 
        
        emit Canceled(_proposalId, _type);
        moloch.cancelProposal(_proposalId);
    }


    
    function isMember(address user) public view returns (bool) {
        (, uint shares,,,,) = moloch.members(user);
        return shares > 0;
    }
    
}

/*
The MIT License (MIT)
Copyright (c) 2018 Murray Software, LLC.
Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:
The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
contract CloneFactory {
    function createClone(address target) internal returns (address result) { // eip-1167 proxy pattern adapted for payable minion
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            result := create(0, clone, 0x37)
        }
    }
}



contract UberHausMinionFactory is CloneFactory {
    
    address public owner; 
    address immutable public template; // fixed template for minion using eip-1167 proxy pattern
    address[] public aavePartyMinions; // list of the minions 
    uint256 public counter; // counter to prevent overwriting minions
    mapping(address => mapping(uint256 => address)) public ourMinions; //mapping minions to DAOs;
    
    event SummonAavePartyMinion(address AavePartyMinion, address dao, address aave, address feeAddress, uint256 minionId, uint256 feeFactor, string desc, string name);
    
    constructor(address _template)  {
        template = _template;
        owner = msg.sender;
    }
    

    function summonUberHausMinion(
            address _dao, 
            address _aave,
            address _feeAddress,
            uint256 _minionId,
            uint256 _feeFactor,
            string memory _desc) 
    external returns (address) {
        require(isMember(_dao) || msg.sender == owner, "!member and !owner");
        
        string memory name = "Aave Party Minion";
        uint256 _minionId = counter ++;
        PoolPartyAaveMinion aaveparty = PoolPartyAaveMinion(createClone(template));
        aaveparty.init(_dao, _aave, _feeAddress, _minionId, _feeFactor, _desc);
        
        emit SummonAavePartyMinion(address(aaveparty), _dao, _aave, _feeAddress, _minionId, _feeFactor, _desc, name);
        
        // add new minion to array and mapping
        aavePartyMinions.push(address(aaveparty));
        // @Dev summoning a new minion for a DAO updates the mapping 
        ourMinions[_dao][_minionId] = address(aaveparty); 
        
        return(address(aaveparty));
    }
    
    function isMember(address _dao) internal view returns (bool) {
        (, uint shares,,,,) = IMOLOCH(_dao).members(msg.sender);
        return shares > 0;
    }
    
    function updateOwner(address _newOwner) external returns (address) {
        require(msg.sender == owner, "only owner");
        owner = _newOwner;
        return owner;
    }
    
}
