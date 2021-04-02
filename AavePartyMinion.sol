// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.3;
pragma experimental ABIEncoderV2;

import "./Interfaces/IMoloch.sol";
import "./Interfaces/IAave.sol";

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


contract PoolPartyAaveMinion is ReentrancyGuard {

    IMOLOCH public moloch;
    IERC20 public haus;
    
    ILendingPoolAddressesProvider provider = ILendingPoolAddressesProvider(address(AaveAddressProvider));
    IProtocolDataProvider data = IProtocolDataProvider(address(aaveData));
    ILendingPool pool = ILendingPool(aavePool);
    
    address public dao; // dao that manages minion 
    address public aavePool; // Initial Aave Lending Pool address
    address public aaveData; // Initial Aave Data address
    address public feeAddress; //address for collecting fees
    uint256 public minionId; // ID to keep minions straight
    uint256 public feeFactor; // Fee Factor in BPs
    uint256 public minHealthFactor; // Minimum health factor for borrowing
    string public desc; //description of minion
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern
    
    address public constant AaveAddressProvider = 0x88757f2f99175387aB4C6a4b3067c77A695b0349; //Kovan address 

    mapping(uint256 => Action) public actions; // proposalId => Action
    mapping(uint256 => Deposit) public deposits; // proposalId => Funding
    mapping(uint256 => Loan) public loans; // loans taken out
    mapping(address => uint256) public assets; // deposits to aave by token
    mapping(address => uint256) public liabilities; // funds borrowed 
    mapping(address => mapping(address => uint256)) public userDelegationAllowances;

    
    struct Action {
        uint256 kind;  // 0 arb, 1 add withdraw collateral, 2 repay loan
        uint256 value;
        address token;
        address to;
        address proposer;
        bool executed;
        bytes data;
    }
    
    struct Deposit {
        address token;
        address proposer;
        address beneficiary;
        uint256 paymentRequested;
        bool executed;
    }
    
    struct Loan {
        address token;
        address proposer;
        address beneficiary;
        uint256 loanAmount;
        uint256 rateMode;
        bool executed;
    }
    

    event ProposeAction(uint256 proposalId, address proposer);
    event ProposeDeposit(uint256 proposalId, address proposer, address token, uint256 paymentRequested);
    event ProposeLoan(uint256 proposalId, address proposer, address beneficiary, address token, uint256 loanAmount, uint256 rateMode);
    event ExecuteAction(uint256 proposalId, address executor);
    event DepositExecuted(uint256 proposalId, address executor, address token, uint256 paymentWithdrawn);
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
    
    
    /**
     * @param _dao The address of the child dao joining UberHaus
     * @param _aavePool The address of lending pool - 0xe0fba4fc209b4948668006b2be61711b7f465bae (kovan)
     * @param _aaveData The address of data provider - 0x3c73A5E5785cAC854D468F727c606C07488a29D6 (kovan)
     * @param _feeAddress The address recieving fees
     * @param _minionId Easy id for minion
     * @param _feeFactor Fee in basis points
     * @param _desc Name or description of the minion
     */  
    
    function init(
        address _dao, 
        address _aavePool,
        address _aaveData,
        address _feeAddress,
        uint256 _minionId,
        uint256 _feeFactor,
        string memory _desc
    )  public {
        require(_dao != address(0), "no 0x address");
        require(!initialized, "already initialized");

        moloch = IMOLOCH(_dao);
        dao = _dao;
        aavePool = _aavePool;
        aaveData = _aaveData;
        feeAddress = _feeAddress;
        minionId = _minionId;
        feeFactor = _feeFactor;
        desc = _desc;
        initialized = true; 
        
    }
    
    //  -- Minion Withdraw Functions --
     
    /**
     * Withdraws funds from any Moloch (incl. UberHaus or the minion owner DAO) into this Minion
     * Set as an internal function to require a passing proposal to execute withdraw
     * @param targetDao the dao from which the minion is withdrawing funds
     * @param token the token being withdrawn 
     * @param amount the amount being withdrawn 
     */ 

    function doWithdraw(address targetDao, address token, uint256 amount) internal {
        require(moloch.getUserTokenBalance(address(this), token) >= amount, "user balance < amount");
        moloch.withdrawBalance(token, amount); // withdraw funds from DAO
        emit DoWithdraw(targetDao, token, amount);
    }
    
    /**
     * Pulls funds from this minion back into the DAO that controls the minion
     * Set as an internal function to require a passing proposal to execute the withdraw
     * @param token the token being withdrawn 
     * @param amount the amount being withdrawn 
     */ 
    
    function pullGuildFunds(address token, uint256 amount) internal {
        // Pulls tokens from the Minion into its master moloch 
        require(moloch.tokenWhitelist(token), "token !whitelisted by master dao");
        require(IERC20(token).balanceOf(address(this)) >= amount, "amount > balance");
        IERC20(token).transfer(address(moloch), amount);
        emit PulledFunds(token, amount);
    }
    
    
    //  -- Proposal Functions --
    
    /**
     * Creates proposal to the owner DAO to execute an arbitrary function call from the minion
     * @param kind The type of call 0 - arbitrary, 1 - withdraw collateral request, 2 - repay loan request
     * @param actionTo The contract being called by the action 
     * @param token The token being used for the DAO proposal (default is DAO deposit token)
     * @param actionValue The value of any ETH being sent by action 
     * @param actionData The abi encoded call data for the desired action 
     * @param details Human readable text for the proposal being submitted 
     */ 
    
    function proposeAction(
        uint256 kind,
        address actionTo,
        address token,
        uint256 actionValue,
        bytes memory actionData,
        string calldata details
    ) public returns (uint256) {
        // No calls to zero address allows us to check that proxy submitted
        // the proposal without getting the proposal struct from parent moloch
        require(actionTo != address(0), "invalid actionTo");
        
        // restricts access to members and internal calls
        require(msg.sender == address(this) || isMember(msg.sender), "not authorized");
        
        //makes sure that someone can't add wrong action kind
        if(msg.sender != address(this)){require(kind == 0, "!permitted action kind");}

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
            kind: kind,
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
    
    /**
     * Executes the arbitrary function call upon successful proposal 
     * @dev limited to kind 0 (arbitrary calls), since Aave related actions require special checks 
     * @param proposalId The id of the associated proposal
     **/ 

    function executeAction(uint256 proposalId) external returns (bytes memory) {
        Action storage action = actions[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);

        require(action.kind == 0, "!generic action");
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
    
    function makeEasyDeposit(
        address token,
        address beneficiary,
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

        Deposit memory deposit = Deposit({
        token: token,
        beneficiary: beneficiary,
        proposer: msg.sender,
        paymentRequested: paymentRequested,
        executed: false
        });

        deposits[proposalId] = deposit;

        emit ProposeDeposit(proposalId, msg.sender, token, paymentRequested);
        return proposalId;
    }

    function executeEasyDeposit(uint256 proposalId) external memberOnly returns (uint256) {
        Deposit storage deposit = deposits[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);

        require(!deposit.executed,  "already executed");
        require(flags[2], "proposal not passed");
        require(flags[1], "proposal not processed");

        // execute call
        deposit.executed = true;
        doWithdraw(address(moloch), deposit.token, deposit.paymentRequested);
        pool.deposit(deposit.token, deposit.paymentRequested, address(this), 0);
        
        emit DepositExecuted(proposalId, msg.sender, deposit.token, deposit.paymentRequested);
        return deposit.paymentRequested;
    }
    
    function borrowFunds(
        address token, 
        uint256 amount, 
        uint256 rateMode, 
        address onBehalfOf,
        string calldata details
    ) external memberOnly returns (uint256){
        
        bytes memory actionData = abi.encode(
            "function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)",
            token,
            amount,
            rateMode,
            0,
            onBehalfOf
            );
        
        uint256 proposalId = proposeAction(
            1,
            aavePool,
            token,
            0,
            actionData,
            details
            );
        
        Loan memory loan = Loan({
        token: token,
        beneficiary: onBehalfOf,
        proposer: msg.sender,
        loanAmount: amount,
        rateMode: rateMode,
        executed: false
        });

        loans[proposalId] = loan;

        emit ProposeLoan(proposalId, msg.sender, onBehalfOf, token, amount, rateMode);
        return proposalId;
    }
    
    function executeBorrow(uint256 proposalId) external memberOnly returns (bytes memory){
        Loan storage loan = loans[proposalId];
        Action storage action = actions[proposalId];
        
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        require(!action.executed,  "already executed");
        require(flags[2], "proposal not passed");
        
        // Checks that health factor is accectable before executing loan
        require(isHealthy(), "!healthy enough");
        
        (bool success, bytes memory retData) = action.to.call{value: action.value}(action.data);
         require(success, "call failure");
         
         action.executed = true;
         loan.executed = true;
        
        return retData;
    }
    
    function cancelAction(uint256 _proposalId, uint8 _type) external {
        if(_type == 1){
            Action storage action = actions[_proposalId];
            require(msg.sender == action.proposer, "not proposer");
            delete actions[_proposalId];
        } else if (_type == 2){
            Deposit storage deposit = deposits[_proposalId];
            require(msg.sender == deposit.proposer, "not proposer");
            delete deposits[_proposalId];
        } 
        
        emit Canceled(_proposalId, _type);
        moloch.cancelProposal(_proposalId);
    }
    
    //  -- Repayment Functions --
    
    function proposeWithdrawCollateral(address token, uint256 amount, address destination, string calldata details) external memberOnly returns(uint256) {
        require(destination == address(moloch) || destination == address(this), "bad destination");
        
        bytes memory actionData = abi.encode(
            "function withdraw(address token, uint256 amount, address destination)",
            token,
            amount,
            destination
            );
        
        uint256 proposalId = proposeAction(
            1,
            aavePool,
            token,
            0,
            actionData,
            details
            );
       
       return(proposalId);
    }
    
    function repayLoan(address token, uint256 amount, uint256 rateMode, address onBehalfOf, string calldata details) external memberOnly returns(uint256) {
        
        bytes memory actionData = abi.encode(
            "function repay(address token, uint256 amount,uint256 rateMode, address onBehalfOf, string details)",
            token,
            amount,
            rateMode,
            onBehalfOf,
            details
            );
        
        uint256 proposalId = proposeAction(
            2,
            aavePool,
            token,
            0,
            actionData,
            details
            );
       
       return(proposalId);
        
    }
    
    function executeCollateralWithdraw(uint256 proposalId) external memberOnly returns (bytes memory) {
         Action storage action = actions[proposalId];

         require(!action.executed, "already executed");
         require(action.kind == 1, "wrong action kind");
         require(isHealthy(), "!healthy enough");
         
         (bool success, bytes memory retData) = action.to.call{value: action.value}(action.data);
         require(success, "call failure");
         actions[proposalId].executed = true;
         
         (,uint256 withdrawAmt,) = abi.decode(action.data, (address, uint256, address));
         assets[action.token] -= withdrawAmt;
         
         return retData;
    }
    
    function executeLoanRepay(uint256 proposalId) external memberOnly returns (bytes memory) {
        
        Action storage action = actions[proposalId];

         require(!action.executed, "already executed");
         require(action.kind == 2, "wrong action kind");

         (bool success, bytes memory retData) = action.to.call{value: action.value}(action.data);
         require(success, "call failure");
         actions[proposalId].executed = true;
         
         (,uint256 repayAmt,,) = abi.decode(action.data, (address, uint256, uint256, address));
         liabilities[action.token] += repayAmt;
         
         return retData;
        
    }
    
    
    //  -- View Functions --
    
    function isHealthy() public view returns (bool){
        uint256 health = getHealthFactor(address(this));
        return health > minHealthFactor;
    }
    
    function getHealthFactor(address user) public view returns (uint256) {
        (,,,,,uint256 health) = pool.getUserAccountData(user);
        return health;
    }
    
    function getOurCompactReserveData(address token) public view returns (
        uint256 aTokenBalance, 
        uint256 stableDebt, 
        uint256 variableDebt, 
        uint256 liquidityRate, 
        bool usageAsCollateralEnabled){
       
       (uint _aTokenBalance, 
       uint _stableDebt, 
       uint _variableDebt,,,,
       uint _liquidityRate,, 
       bool _enableCollateral) = data.getUserReserveData(token, address(this));
       
       return (_aTokenBalance, _stableDebt, _variableDebt, _liquidityRate, _enableCollateral);
    }
    
    function getAaveTokenAddresses(address token) public view returns (
        address aTokenAddress, 
        address stableDebtTokenAddress, 
        address variableDebtTokenAddress) {
            
        (address _aToken, 
        address _stableDebtToken, 
        address _variableDebtToken) = data.getReserveTokensAddresses(token);
        
        return (_aToken, _stableDebtToken, _variableDebtToken);
    }
    
    function isMember(address user) public view returns (bool) {
        (, uint shares,,,,) = moloch.members(user);
        return shares > 0;
    }
    
    //  -- Helper Functions --
    
    function updateAavePool() public memberOnly returns (address newPool) {
        
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
    
    event SummonAavePartyMinion(address AavePartyMinion, address dao, address aavePool, address aaveData, address feeAddress, uint256 minionId, uint256 feeFactor, string desc, string name);
    
    constructor(address _template)  {
        template = _template;
        owner = msg.sender;
    }
    

    function summonAavePartyMinion(
            address _dao, 
            address _aavePool,
            address _aaveData,
            address _feeAddress,
            uint256 _feeFactor,
            string memory _desc) 
    external returns (address) {
        require(isMember(_dao) || msg.sender == owner, "!member and !owner");
        
        string memory name = "Aave Party Minion";
        uint256 minionId = counter ++;
        PoolPartyAaveMinion aaveparty = PoolPartyAaveMinion(createClone(template));
        aaveparty.init(_dao, _aavePool, _aaveData, _feeAddress, minionId, _feeFactor, _desc);
        
        emit SummonAavePartyMinion(address(aaveparty), _dao, _aavePool, _aaveData, _feeAddress, minionId, _feeFactor, _desc, name);
        
        // add new minion to array and mapping
        aavePartyMinions.push(address(aaveparty));
        // @Dev summoning a new minion for a DAO updates the mapping 
        ourMinions[_dao][minionId] = address(aaveparty); 
        
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
