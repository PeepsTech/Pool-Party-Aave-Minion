// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.3;

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



contract PoolPartyAaveMinion is ReentrancyGuard {

    IMOLOCH public moloch;

    ILendingPoolAddressesProvider provider = ILendingPoolAddressesProvider(address(AaveAddressProvider));
    // IProtocolDataProvider data = IProtocolDataProvider(address(aaveData));
    // ILendingPool pool = ILendingPool(aavePool);
    
    address public dao; // dao that manages minion 
    address public aavePool; // Initial Aave Lending Pool address
    address public aaveData; // Initial Aave Data address
    address public feeAddress; //address for collecting fees
    
    uint256 public feeFactor; // Fee BPs
    uint256 public minionId; // ID to keep minions straight
    uint256 public minHealthFactor; // Minimum health factor for borrowing
    uint256[] public proposals; // Array of proposals
    
    string public desc; //description of minion
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern
    
    address public constant AaveAddressProvider = 0xd05e3E715d945B59290df0ae8eF85c1BdB684744; // matic
    uint256 public constant feeBase = 10000; // Fee Factor in BPs 1/10000
    uint256 public constant withdrawFactor = 10; // Fee 

    mapping(uint256 => Deposit) public deposits; // proposalId => Funding
    mapping(uint256 => Loan) public loans; // loans taken out
    mapping(uint256 => CollateralWithdraw) public collateralWithdraws; // proposalID => withdraws of collateral
    mapping(uint256 => LoanRepayment) public loanRepayments; // proposalID => loan repayments
    mapping(uint256 => Action) public actions; // proposalID => actions
    mapping(address => int) public earningsPeg; // peg for earnings and fees 
    mapping(address => bool) public rewardsOn; // tracks rewards taken out by users by token
    mapping(address => mapping(address => uint256)) public aTokenRedemptions; // tracks rewards taken out by users by token
    
    struct Deposit {
        address token;
        address proposer;
        uint256 paymentRequested;
        bool executed;
    }
    
    struct Loan {
        address token;
        address proposer;
        address onBehalfOf;
        uint256 amount;
        uint256 rateMode;
        bool executed;
    }
    
    struct CollateralWithdraw {
        address proposer;
        address token;
        address destination;
        uint256 amount;
        bool executed;
    }
    
    struct LoanRepayment {
        address proposer;
        address token;
        address onBehalfOf;
        uint256 amount;
        uint256 rateMode;
        bool executed;
    }
    
    struct Action {
        address proposer;
        address token;
        uint256 amount;
        uint16 actionType; // 1 - DAO withdraw, 2 - Earnings toggle
        bool executed;
    }

    event ProposeDeposit(uint256 proposalId, address proposer, address token, uint256 paymentRequested);
    event DepositExecuted(uint256 proposalId, address token, uint256 aTokens);
    event ProposeLoan(uint256 proposalId, address proposer, address beneficiary, address token, uint256 loanAmount, uint256 rateMode);
    event LoanExecuted(uint256 proposalId, address token, uint256 loanAmt);
    event ExecuteAction(uint256 proposalId, address executor);
    event DepositExecuted(uint256 proposalId, address executor, address token, uint256 paymentWithdrawn);
    event DoWithdraw(address targetDao, address token, uint256 amount);
    event Withdraw2DAO(address token, uint256 amount);
    event Canceled(uint256 proposalId, uint256 proposalKind);

    
    modifier memberOnly() {
        require(isMember(msg.sender), "Minion::not member");
        _;
    }
    
    /**
     * @param _dao The address of the child dao joining UberHaus
     * @param _feeAddress The address recieving fees
     * @param _minionId Easy id for minion
     * @param _feeFactor Fee in basis points
     * @param _desc Name or description of the minion
     */  
    
    function init(
        address _dao, 
        address _feeAddress,
        uint256 _minionId,
        uint256 _feeFactor,
        uint256 _minHealthFactor,
        string memory _desc
    )  public {
        require(_dao != address(0), "no 0x address");
        require(!initialized, "already initialized");

        moloch = IMOLOCH(_dao);
        dao = _dao;
        feeAddress = _feeAddress;
        minionId = _minionId;
        feeFactor = _feeFactor;
        minHealthFactor = _minHealthFactor;
        desc = _desc;
        
        aavePool = 0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf;
        aaveData = 0x7551b5D2763519d4e37e8B81929D336De671d46d;
        
        initialized = true; 
        
    }

    
    /**********************************************************************
                             PROPOSAL FUNCTIONS 
    ***********************************************************************/
    
    // -- Lending and Borrowing Functions -- //
    
    /**
     * Creates proposal to the owner DAO to execute an arbitrary function call from the minion
     * @param token The token being used for the DAO proposal (default is DAO deposit token)
     * @param details Human readable text for the proposal being submitted 
     */ 
    
    function proposeAction(
        address token,
        uint256 tributeOffered,
        uint256 paymentRequested,
        string memory details
    ) internal returns (uint256 _proposalId) {
        
        //submit proposal to its moloch 
        uint256 proposalId = moloch.submitProposal(
            address(this),
            0,
            0,
            tributeOffered,
            token,
            paymentRequested,
            token,
            details
        );

        return proposalId;
    }

    /**
     * Special proposal function to make funding the minion via a DAO proposal and moving those funds into Aave easy
     * @dev Did not use proposeAction() because of stack too deep error when adding paymentRequested
     * @param token The base token to be wrapped in Aave
     * @param paymentRequested Amount of tokens to be requested from 
     * @param details Details for the DAO proposal
     */  
    
    function depositCollateral(
        address token,
        uint256 paymentRequested,
        string calldata details
    ) external memberOnly returns (uint256 _proposalId) {
        
        uint256 proposalId = proposeAction(
            token,
            0,
            paymentRequested,
            details
            );

        // TODO Add check to make sure token has an aToken 

        Deposit memory deposit = Deposit({
            token: token,
            proposer: msg.sender,
            paymentRequested: paymentRequested,
            executed: false
        });

        deposits[proposalId] = deposit;

        emit ProposeDeposit(proposalId, msg.sender, token, paymentRequested);
        return proposalId;
    }
    
    /**
     * Executes the depositCollateral() proposal once it's passed 
     * @dev calls the doWithdraw() function to remove funds from the DAO 
     * @dev calls the aavePool deposit() function to immediately move those funds into aTokens
     * @param proposalId The id of the associated proposal
     **/ 

    function executeCollateralDeposit(uint256 proposalId) external memberOnly returns (uint256 _proposalId) {
        Deposit storage deposit = deposits[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        (address aToken,,) = getAaveTokenAddresses(deposit.token);

        require(!deposit.executed,  "already executed");
        require(flags[2], "proposal not passed");
        require(flags[1], "proposal not processed");
        
        doWithdraw(address(dao), deposit.token, deposit.paymentRequested);
        require(IERC20(deposit.token).balanceOf(address(this)) >= deposit.paymentRequested, "!enough funds");
        
        IERC20(deposit.token).approve(aavePool, type(uint256).max);
        IERC20(aToken).approve(aavePool, type(uint256).max);
        ILendingPool(aavePool).deposit(deposit.token, deposit.paymentRequested, address(this), 0);
        
        earningsPeg[aToken] += int(deposit.paymentRequested);
        
        // execute call
        deposit.executed = true;
        
        emit DepositExecuted(proposalId, msg.sender, deposit.token, deposit.paymentRequested);
        return deposit.paymentRequested;
    }
    
    /**
     * Allows minion to borrow funds from Aave 
     * Requires that the minion holds sufficient aTokens as collateral 
     * @dev uses the proposeAction() function in order to submit a proposal for the borrow action
     * @param token The underlying token to be borrowed
     * @param amount The amount to be borrowed
     * @param rateMode Determines whether using stable or variable debt 
     * @param onBehalfOf Used for credit delegation if borrowing using another's collateral 
     **/ 
    
    function borrowFunds(
        address token, 
        uint256 amount, 
        uint256 rateMode, 
        address onBehalfOf,
        string calldata details
    ) external memberOnly returns (uint256 _proposalId){
        
        uint256 proposalId = proposeAction(
            token,
            0,
            0,
            details
            );
        
        Loan memory loan = Loan({
            token: token,
            proposer: msg.sender,
            onBehalfOf: onBehalfOf,
            amount: amount,
            rateMode: rateMode,
            executed: false
        });

        loans[proposalId] = loan;

        emit ProposeLoan(proposalId, msg.sender, onBehalfOf, token, amount, rateMode);
        return proposalId;
    }
    
    /**
     * Executes the borrowFunds() proposal once it's passed a
     * @dev requires a special processing function in order to check health and track liabities 
     * @dev calls the aavePool borrow() function to borrow funds from Aave with dTokens being held in minion
     * @param proposalId The id of the associated proposal
     **/     
    
    function executeBorrow(uint256 proposalId) external memberOnly returns (uint256 amount){
        Loan storage loan = loans[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
        require(!loan.executed,  "already executed");
        require(flags[2], "proposal not passed");
        
        // Checks that health factor is accectable before executing loan
        require(isHealthy(), "!healthy enough");
        
        ILendingPool(aavePool).borrow(loan.token, loan.amount, loan.rateMode, 0, loan.onBehalfOf);
        loan.executed = true;
        
        earningsPeg[loan.token] += int(loan.amount);

        emit LoanExecuted(proposalId, loan.token, loan.amount);
        return loan.amount;
    }
    
    //  -- Repayment and Withdraw Functions -- //
    
    /**
     * Allows minion to withdraw funds from Aave 
     * @dev destination is limited to the DAO or the minion for security  
     * @dev uses the proposeWithdrawCollateral() function in order to submit a proposal for the withdraw action
     * @dev checks health factory at point of execution
     * @param token The underlying token to be withdrawn from Aave 
     * @param amount The amount to be taken out of Aave
     * @param destination Where withdrawn tokens get dumped
     * @param details Used for proposal details
     **/ 
    
    function withdrawCollateral(address token, uint256 amount, address destination, string calldata details) external memberOnly returns(uint256 _proposalId) {

        uint256 proposalId = proposeAction(
            token,
            0,
            0,
            details
            );
            
        CollateralWithdraw memory withdraw = CollateralWithdraw({
            proposer: msg.sender,
            token: token,
            destination: destination,
            amount: amount,
            executed: false
        });

        collateralWithdraws[proposalId] = withdraw;  
       
       return(proposalId);
    }
    
    /**
     * Allows minion to repay funds borrowed from Aave
     * @dev uses the proposeRepayLoan() function in order to submit a proposal for the withdraw action
     * @dev onBehalfOf will usually be the minion address 
     * @param token The underlying token to be withdrawn from Aave 
     * @param amount The amount to be taken out of Aave
     * @param rateMode whether loan uses a stable or variable rate
     * @param onBehalfOf should typically be minion address 
     * @param details Used for proposal details
     **/ 
    
    function repayLoan(address token, uint256 amount, uint256 rateMode, address onBehalfOf, string calldata details) external memberOnly returns(uint256 _proposalId) {
        
        uint256 proposalId = proposeAction(
            token,
            0,
            0,
            details
            );
            
        LoanRepayment memory repayment = LoanRepayment({
            proposer: msg.sender,
            token: token,
            onBehalfOf: onBehalfOf,
            amount: amount,
            rateMode: rateMode,
            executed: false
        });

        loanRepayments[proposalId] = repayment; 
       
       return(proposalId);
    }
    
    /**
     * Withdraws funds from the minion by tributing them into the DAO via proposal for 0 shares / loot
     * @dev can be undone by DAO if they vote down proposal or msg.sender cancels 
     * @dev takes a fee on aTokens withdrawn, since we don't otherwise get that fee
     * @param token The underlying token to be withdrawn from Aave 
     * @param amount The amount to be taken out of Aave
     * @param details Used for proposal details
     **/ 
    

    function daoWithdraw(address token, uint256 amount, string calldata details) external memberOnly returns(uint256 _proposalId) {
        
        bool whitelisted = moloch.tokenWhitelist(token);
        require(whitelisted, "not a whitelisted token");
        IERC20(token).approve(address(moloch), type(uint256).max);
        
        // Takes smaller fee if aTokens being withdrawn
        uint256 netDraw;
        if(checkaToken(token)){
            uint256 fee = pullWithdrawFees(token, amount);  
            netDraw = amount - fee;
        } else {
            netDraw = amount;
        }
        
        uint256 proposalId = proposeAction(
            token,
            netDraw,
            0,
            details
            );
            
        Action memory action = Action({
            proposer: msg.sender,
            token: token,
            amount: amount,
            actionType: 1,
            executed: true
        });
        
        earningsPeg[token] -= int(amount);
        actions[proposalId] = action; 
        return(proposalId);
    }
    
    /**
     * Executes the proposeWithdrawCollateral() proposal once it's passed
     * @dev requires a special processing function in order to check health and track remaning assets  
     * @dev calls the aavePool withdraw() function to swap aTokens for tokens back to the aavePartyMinions
     * @param proposalId The id of the associated proposal
     **/ 
    
    function executeCollateralWithdraw(uint256 proposalId) external memberOnly returns (uint256 amount) {
         
         CollateralWithdraw storage withdraw = collateralWithdraws[proposalId];
         bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
         require(flags[2], "proposal not passed");
         require(!withdraw.executed, "already executed");
         require(isHealthy(), "!healthy enough");
         
         (address aToken,,) = getAaveTokenAddresses(withdraw.token);
         uint256 fee = pullEarrningsFees(aToken, withdraw.amount);
         uint256 netWithdraw = withdraw.amount - fee;

         uint256 withdrawAmt = ILendingPool(aavePool).withdraw(
             withdraw.token, 
             netWithdraw, 
             withdraw.destination
             );
             
         collateralWithdraws[proposalId].executed = true;
         
        // Adjust earnings peg to reflect aTokens converted back into reserveTokens
         earningsPeg[aToken] -= int(withdraw.amount);

         return withdrawAmt;
    }
    
    /**
     * Executes the proposeRepayLoan() proposal once it's passed
     * @dev requires a special processing function in order to track remaning liabilities / assets  
     * @dev calls the aavePool withdraw() function to swap aTokens for tokens back to the aavePartyMinions
     * @param proposalId The id of the associated proposal
     **/ 
    
    function executeLoanRepay(uint256 proposalId) external memberOnly returns (uint256 repayAmt) {
        
        LoanRepayment storage repay = loanRepayments[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
        require(flags[2], "proposal not passed");
        require(!repay.executed, "already executed");

        uint256 repaidAmt = ILendingPool(aavePool).repay(
            repay.token, 
            repay.amount, 
            repay.rateMode, 
            repay.onBehalfOf
            );
        repay.executed = true;
        
        // Adjust earnings peg to reflect debt repaid 
        earningsPeg[repay.token] -= int(repaidAmt);

        return repaidAmt;
    }
    
    /**
     * Simple function to cancel Aave-related proposals  
     * @dev Can only be called by proposer
     * @dev Can only be called if the proposal has not been sponsored in DAO
     * @param proposalId The id of the proposal to be cancelled
     * @param propType The type of proposal to be cancelled
     **/ 
     
    function cancelAaveProposal(uint256 proposalId, uint16 propType) external {
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        require(!flags[0], "proposal already sponsored");
        
        if(propType == 1){
            Deposit storage prop = deposits[proposalId];
            require(msg.sender == prop.proposer, "not proposer");
        } else if (propType == 2) {
            Loan storage prop = loans[proposalId];
            require(msg.sender == prop.proposer, "not proposer");
        } else if (propType == 3) {
            CollateralWithdraw storage prop = collateralWithdraws[proposalId];
            require(msg.sender == prop.proposer, "not proposer");
        } else if (propType == 4) {
            LoanRepayment storage prop = loanRepayments[proposalId];
            require(msg.sender == prop.proposer, "not proposer");
        }
        
        emit Canceled(proposalId, propType);
        moloch.cancelProposal(proposalId);
    }
    
    /**
     * Simple function to cancel proposals that use actions
     * @dev Can only be called by proposer
     * @dev Can only be called if the proposal has not been sponsored in DAO
     * @param proposalId The id of the proposal to be cancelled
     **/ 
    
    function undoAction(uint256 proposalId) external memberOnly {
        
        Action storage action = actions[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        require(!flags[0], "proposal already sponsored");
        
        moloch.cancelProposal(proposalId);
        emit Canceled(proposalId, action.actionType);
    }
    
    
    /**********************************************************************
                             EARNGINS & FEE FUNCTIONS 
    ***********************************************************************/
    
    /**
     * Allows DAO member to withdraw their share of earnings of a particular token
     * @dev Earnings withdraws need to be turned on by the DAO first 
     * @dev Destination is restricted to the member or the DAO (if they're feeling generous)
     * @param token The token with earnings to withdraw
     * @param destination Where member sends their earnings 
     **/ 
     
    function withdrawMyEarnings(address token, address destination) external memberOnly returns (uint256 amount) {
    
        require(rewardsOn[token], "rewards !on");
        require(isHealthy(), "!healthy enough");
        require(destination == msg.sender || destination == address(moloch), "!acceptable destination");
        
        //Get earnings and fees
        uint256 myEarnings = calcMemberEarnings(token, msg.sender);
        uint256 fees = pullEarrningsFees(token, myEarnings);
        
        //Transfer member earnings - fees 
        uint256 transferAmt = myEarnings - fees;
        IERC20(token).transfer(destination, uint256(transferAmt));
        
        return myEarnings;
    }
    
    /**
     * Simple function to withdraw the fees on earnings
     * @dev Is often withdrawing the aToken
     * @param token The address of the token 
     * @param amount The amount being withdrawn
     **/ 
     
    function pullEarrningsFees(address token, uint256 amount) internal returns(uint256 fee) {
        uint256 feeToPull = calcFees(token, amount);
        IERC20(token).transfer(feeAddress, feeToPull);

        return feeToPull;
    }
    
    /**
     * Simple function to withdraw the fees withdraws of the aToken from the Minion 
     * Compensates for situations where aTokens are moved from DAO before earnings accumulate
     * @param token The address of the token 
     * @param amount The amount being withdrawn
     **/ 
     
    function pullWithdrawFees(address token, uint256 amount) internal returns(uint256 fee){
        uint256 feeToPull = calcFees(token, amount) / withdrawFactor; //lowers fee by factor of 10 
        IERC20(token).transfer(feeAddress, feeToPull);

        return feeToPull;
    }
    
    
    /**
     * Simple function to turn rewardsOn
     * @dev sumbmits proposal to DAO to toggle 
     **/ 
    
    function proposeToggleEarnings(address token, string memory details) external memberOnly returns(uint256) {
        
        uint256 proposalId = proposeAction(
            token,
            0,
            0,
            details
            );
        
        Action memory action = Action({
            proposer: msg.sender,
            token: token,
            amount: 0,
            actionType: 2,
            executed: false
        });
        
        actions[proposalId] = action;
        return proposalId;
    }
    
     function executeToggleEarnings(uint256 proposalId) external memberOnly returns(address token, bool status) {
        Action storage action = actions[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
        require(flags[2], "proposal not passed");
        require(!action.executed, "already executed");
        require(action.actionType == 2, "!right actionType");
        
        action.executed = true;
        if(!rewardsOn[action.token]){
            rewardsOn[action.token] = true;
            return (action.token, true);
        } else {
            rewardsOn[action.token] = false;
            return (action.token, false);
        }
    }
    
    /**********************************************************************
                             VIEW & HELPER FUNCTIONS 
    ***********************************************************************/
    
    //  -- Earnings & Fees View Functions -- //
    
    /**
     * Simple function to calculate fees   
     * @dev Total earnings = balance of aToken in minion - earnings peg
     * @dev Adjust fee by amt being withdrawn / total balance of aToken in minion
     * @param token The address of the aToken 
     * @param amount The amount being withdrawn
     **/ 
    
    function calcFees(address token, uint256 amount) public view returns (uint256 fee){
        
        uint256 peg = zero(earningsPeg[token]); // earnings peg for that aToken to get base 
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        uint256 _fee = (tokenBalance - peg) * feeFactor * amount / feeBase / tokenBalance; 
        
        return _fee;
    }
    
    /**
     * Calculates member earnings w/r to a single token  
     * @dev Member earnings = balance of member's share of aToken in minion - member's share of earnings peg
     * @dev Adjusted by previous withdraws of the token for earnings 
     * @param token The address of the aToken 
     * @param user The amount being withdrawn
     **/ 
    
    function calcMemberEarnings(address token, address user) public view returns (uint256 earnings){
        
        //Get all the shares and loot inputs
        uint256 memberSharesAndLoot = getMemberSharesAndLoot(user);
        uint256 molochSharesAndLoot = getMolochSharesAndLoot();
        
        //Get current balance and basis 
        uint256 currentBalance = fairShare(IERC20(token).balanceOf(address(this)), memberSharesAndLoot, molochSharesAndLoot);
        uint256 basis = (zero(earningsPeg[token]) / molochSharesAndLoot * memberSharesAndLoot) + aTokenRedemptions[user][token];
        uint256 _earnings = currentBalance - basis;

        return _earnings;
    }
    
    
    //  -- Aave-related View Functions -- //
    
    /**
     * Checks whether the current health is greater minHealthFactor
     * @dev Should check transaction's effects on health factor on front-end
     **/ 
    
    function isHealthy() public view returns (bool success){
        uint256 health = getHealthFactor(address(this));
        return health > minHealthFactor;
    }
    
    function getHealthFactor(address user) public view returns (uint256 healthFactor) {
        (,,,,,uint256 health) = ILendingPool(aavePool).getUserAccountData(user);
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
       bool _enableCollateral) = IProtocolDataProvider(aaveData).getUserReserveData(token, address(this));
       
       return (_aTokenBalance, _stableDebt, _variableDebt, _liquidityRate, _enableCollateral);
    }
    
    function getAaveTokenAddresses(address token) public view returns (
        address aTokenAddress, 
        address stableDebtTokenAddress, 
        address variableDebtTokenAddress) {
            
        (address _aToken, 
        address _stableDebtToken, 
        address _variableDebtToken) = IProtocolDataProvider(aaveData).getReserveTokensAddresses(token);
        
        return (_aToken, _stableDebtToken, _variableDebtToken);
    }
    
    function checkaToken(address token) internal view returns (bool) {
        
        (address aToken,,) = getAaveTokenAddresses(token);
        if(aToken == address(0)){
            return true;
        } else {
            return false;
        }
    }
    
    //  -- Moloch-related View Functions -- //
    
    function isMember(address user) public view returns (bool member) {
        (, uint256 shares,,,,) = moloch.members(user);
        return shares > 0;
    }
    
    function getMemberSharesAndLoot(address user) public view returns (uint256){
        (, uint256 shares, uint256 loot,,,) = moloch.members(user);
        return shares + loot;
    }
    
    
    function getMolochSharesAndLoot() public view returns (uint256){
        uint256 molochShares = moloch.totalShares();
        uint256 molochLoot = moloch.totalLoot();
        return molochShares + molochLoot;
    }
    
    function fairShare(uint256 balance, uint256 shares, uint256 totalShares) internal pure returns (uint256) {
        require(totalShares != 0);

        if (balance == 0) { return 0; }

        uint256 prod = balance * shares;

        if (prod / balance == shares) { // no overflow in multiplication above?
            return prod / totalShares;
        }

        return (balance / totalShares) * shares;
    }
    
    //  -- Helper Functions -- //
    
    /**
     * Withdraws funds from any Moloch into this Minion
     * Set as an public function to allow for member or this contract to call via proposal
     * @param targetDao the dao from which the minion is withdrawing funds
     * @param token the token being withdrawn 
     * @param amount the amount being withdrawn 
     */ 
    
    function doWithdraw(address targetDao, address token, uint256 amount) public {
        require(moloch.getUserTokenBalance(address(this), token) >= amount, "user balance < amount");
        moloch.withdrawBalance(token, amount); // withdraw funds from DAO
        earningsPeg[token] += int(amount);
        emit DoWithdraw(targetDao, token, amount);
    }
    

    
    /**
     * Simple function to update the lending pool address 
     * Can be called by any member of the DAO
     **/
     
    function resetAavePool() public returns (address newPool) {
        
        address updatedPool = provider.getLendingPool();
        require (aavePool != updatedPool, "already set");
        aavePool = updatedPool;
        
        return aavePool;
    }
    
    /**
     * Simple function to update the data provider address 
     * Can be called by any member of the DAO
     **/
    
    function resetDataProvider() public returns (address dataProvider){
        
        address _dataProvider = provider.getAddress("0x1");
        require(aaveData != _dataProvider, "already set");
        aaveData = _dataProvider;
        
        return aaveData;
    }
    
    function zero(int x) internal pure returns (uint256) {
        return uint(x) >= 0 ? uint(x) : 0;
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



contract AavePartyMinionFactory is CloneFactory {
    
    address public owner; 
    address immutable public template; // fixed template for minion using eip-1167 proxy pattern
    address[] public aavePartyMinions; // list of the minions 
    uint256 public counter; // counter to prevent overwriting minions
    mapping(address => mapping(uint256 => address)) public ourMinions; //mapping minions to DAOs;
    
    event SummonAavePartyMinion(address AavePartyMinion, address dao, address feeAddress, uint256 minionId, uint256 feeFactor, string desc, string name);
    
    constructor(address _template)  {
        template = _template;
        owner = msg.sender;
    }
    

    function summonAavePartyMinion(
            address _dao, 
            address _feeAddress,
            uint256 _feeFactor,
            uint256 _minHealthFactor,
            string memory _desc) 
    external returns (address) {
        require(isMember(_dao) || msg.sender == owner, "!member and !owner");
        
        string memory name = "Aave Party Minion";
        uint256 minionId = counter ++;
        PoolPartyAaveMinion aaveparty = PoolPartyAaveMinion(createClone(template));
        aaveparty.init(_dao, _feeAddress, minionId, _feeFactor, _minHealthFactor, _desc);
        
        emit SummonAavePartyMinion(address(aaveparty), _dao, _feeAddress, minionId, _feeFactor, _desc, name);
        
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
