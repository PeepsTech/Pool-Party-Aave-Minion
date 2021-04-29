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

    ILendingPoolAddressesProvider public provider = ILendingPoolAddressesProvider(address(AAVE_ADDRESS_PROVIDER));
    IProtocolDataProvider public data = IProtocolDataProvider(address(aaveData));
    ILendingPool public pool = ILendingPool(aavePool);
    
    address public dao; // dao that manages minion 
    address public aavePool; // Initial Aave Lending Pool address
    address public aaveData; // Initial Aave Data address
    address private feeAddress; //address for collecting fees
    
    uint256 public minionId; //Id to help identify minion
    uint256 public feeFactor; // Fee BPs
    uint256 public minHealthFactor; // Minimum health factor for borrowing
    uint256[] public proposals; // Array of proposals
    
    string public desc; //description of minion
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern
    
    address public constant AAVE_ADDRESS_PROVIDER = 0xd05e3E715d945B59290df0ae8eF85c1BdB684744; // matic
    uint256 public constant FEE_BASE = 10000; // Fee Factor in BPs 1/10000
    uint256 public constant WITHDRAW_FACTOR = 10; // Fee 

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
        uint256 rateMode; // 1 for stableDebt, 2 for variableDebt
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

    event ProposeDeposit(uint256 proposalId, address proposer, address token, uint256 amount);
    event DepositExecuted(uint256 proposalId);
    event ProposeLoan(uint256 proposalId, address proposer, address beneficiary, address token, uint256 amount, uint256 rateMode);
    event LoanExecuted(uint256 proposalId);
    event ProposeCollateralWithdraw(uint256 proposalId, address proposer, address token, uint256 amount, address destination);
    event CollateralWithdrawExecuted(uint256 proposalId, uint256 amount);
    event ProposeRepayLoan(uint256 proposalId, address proposer, address token, uint256 amount, address onBehalfOf);
    event RepayLoanExecuted(uint256 proposalId);
    event WithdrawToDAO(uint256 proposalId, address proposer, address token, uint256 amount);
    event EarningsWithdraw(address member, address token, uint256 earnings, address destination);
    event ProposeToggleEarnings(address token);
    event EarningsToggled(uint256 proposalId, bool status);
    event WithdrawToMinion(address targetDao, address token, uint256 amount);
    event Canceled(uint256 proposalId, uint256 proposalType, string functionCaller);

    
    modifier memberOnly() {
        require(isMember(msg.sender), "AP::not member");
        _;
    }
    
    /**
     * @dev Takes place of constructor function with EIP-1167
     * @param _dao The address of the child dao joining UberHaus
     * @param _aavePool The initial AavePool interface address
     * @param _aaveData The initial AaveDataProvider interface address
     * @param _minionId Helps to track minion
     * @param _feeAddress The address recieving fees
     * @param _feeFactor Fee in basis points
     * @param _minHealthFactor Minimum Aave Health Factor in Wei 
     * @param _desc Name or description of the minion
     */  
    
    function init(
        address _dao, 
        address _feeAddress,
        address _aavePool,
        address _aaveData,
        uint256 _minionId,
        uint256 _feeFactor,
        uint256 _minHealthFactor,
        string memory _desc
    )  public {
        require(_dao != address(0), "AP::no 0x address");
        require(!initialized, "AP::already initialized");

        //Set up interfaces
        moloch = IMOLOCH(_dao);
        pool = ILendingPool(_aavePool);
        data = IProtocolDataProvider(_aaveData);
        
        dao = _dao;
        minionId = _minionId;
        feeAddress = _feeAddress;
        feeFactor = _feeFactor;
        minHealthFactor = _minHealthFactor;
        desc = _desc;
        
        aavePool = _aavePool; 
        aaveData = _aaveData;
        
        initialized = true; 
        
    }

    
    /**********************************************************************
                             PROPOSAL FUNCTIONS 
    ***********************************************************************/
    
    // -- LENDING AND BORROWING FUNCTIONS -- //
    
    /**
     * Creates a generic proposal to the DAO to do actions at the minion level
     * @dev Returns a proposalId which is used by the rest of the functions for tracking proposal status
     * @param token The token being used for the DAO proposal (default is DAO deposit token)
     * @param tributeOffered Used if the Minion is moving funds into the DAO
     * @param paymentRequested Used to move funds from DAO to minion
     * @param details Human readable text for the proposal being submitted 
     */ 
    
    function proposeAction(
        address token,
        uint256 tributeOffered,
        uint256 paymentRequested,
        string memory details
    ) internal returns (uint256) {
        
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
     * @param token The base token to be wrapped in Aave
     * @param paymentRequested Amount of tokens to be requested from 
     * @param details Details for the DAO proposal
     */  
    
    function depositCollateral(
        address token,
        uint256 paymentRequested,
        string calldata details
    ) external memberOnly returns (uint256) {
        
        // Checks there's an existing aToken for this token
        (address aToken,,) = getAaveTokenAddresses(token);
        require(aToken != address(0), "AP::No aToken");
        
        uint256 proposalId = proposeAction(
            token,
            0,
            paymentRequested,
            details
            );


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

    function executeCollateralDeposit(uint256 proposalId) external nonReentrant memberOnly returns (uint256) {
        Deposit storage deposit = deposits[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        (address aToken,,) = getAaveTokenAddresses(deposit.token);

        require(!deposit.executed,  "AP::already executed");
        require(flags[2], "AP::proposal not passed");
        require(flags[1], "AP::proposal not processed");
        
        //Withdraws the funds for deposit from the Moloch
        doWithdraw(address(dao), deposit.token, deposit.paymentRequested);
        //Approves that token to be spent by Aave
        IERC20(deposit.token).approve(aavePool, type(uint256).max);
        //Also approves the aToken to be used by Aave in anticipation of eventual withdraw
        IERC20(aToken).approve(aavePool, type(uint256).max);
        //Deposits token into the AaveLending Pool with the minion as the destination for aTokens
        pool.deposit(deposit.token, deposit.paymentRequested, address(this), 0);
        
        //Updates internal accounting for earnings pegs
        earningsPeg[aToken] += int(deposit.paymentRequested);
        
        // execute call
        deposit.executed = true;
        
        emit DepositExecuted(proposalId);
        return proposalId;
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
    ) external memberOnly returns (uint256){
        
        (,address sToken, address vToken) = getAaveTokenAddresses(token);
        // Check health before allowing member to propose borrowing more
        require(isHealthy(), "AP::Not healthy enough");
        //Check that debtToken exists for that rateMode 
        if (rateMode == 1){
            require(sToken != address(0), "AP::no sToken");
        } else if (rateMode == 2){
            require(vToken != address(0), "AP::no sToken");
        } else {
            revert("AP::no rateMode");
        }
        
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
    
    function executeBorrow(uint256 proposalId) external nonReentrant memberOnly returns (uint256){
        Loan storage loan = loans[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
        require(!loan.executed,  "AP::already executed");
        require(flags[2], "AP::proposal not passed");
        // Recheck health factor, which could have changed since proposal
        require(isHealthy(), "AP::not healthy enough");
        
        pool.borrow(loan.token, loan.amount, loan.rateMode, 0, loan.onBehalfOf);
        loan.executed = true;
        
        //Update accounting so loan isn't mistaken for earnings
        earningsPeg[loan.token] += int(loan.amount);

        emit LoanExecuted(proposalId);
        return proposalId;
    }
    
    //  -- REPAYMENT AND WITHDRAW FUNCTIONS -- //
    
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
    
    function withdrawCollateral(
        address token, 
        uint256 amount, 
        address destination, 
        string calldata details
    ) external memberOnly returns (uint256) {
        (uint256 aTokenBal,,,,) = getOurCompactReserveData(token);
        //Check health before collateral withdraw proposal
        require(isHealthy(), "AP::not healthy enough");
        //Check aTokens available is <= amount being withdrawn
        require(aTokenBal <= amount, "AP::not enough tokens");
        
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
        
        emit ProposeCollateralWithdraw(proposalId, msg.sender, token, amount, destination);
        return proposalId;
    }
    
    /**
     * Allows minion to repay funds borrowed from Aave
     * @dev uses the proposeRepayLoan() function in order to submit a proposal for the withdraw action
     * @dev onBehalfOf will usually be the minion address 
     * @param token The underlying token to be withdrawn from Aave 
     * @param amount The amount to be taken out of Aave
     * @param rateMode whether loan uses a stable or variable rate
     * @param onBehalfOf should be minion address, except in special circumstances
     * @param details Used for proposal details
     **/ 
    
    function repayLoan(
        address token, 
        uint256 amount, 
        uint256 rateMode, 
        address onBehalfOf, 
        string calldata details
    ) external memberOnly returns (uint256) {
        
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
        emit ProposeRepayLoan(proposalId, msg.sender, token, amount, onBehalfOf);
        return proposalId;
    }
    
    /**
     * Withdraws funds from the minion by tributing them into the DAO via proposal for 0 shares / 0 loot
     * @dev can be undone by DAO if they vote down proposal or msg.sender cancels 
     * @dev takes a fee on aTokens withdrawn, since we don't otherwise get that fee
     * @param token The underlying token to be withdrawn from Aave 
     * @param amount The amount to be taken out of Aave
     * @param details Used for proposal details
     **/ 
    

    function daoWithdraw(
        address token, 
        uint256 amount, 
        string calldata details
    ) external nonReentrant memberOnly returns (uint256) {
        //Checks that token is already whitelisted 
        require(moloch.tokenWhitelist(token), "AP::not a whitelisted token");
        //Approves moloch to withdraw the tributed tokens
        IERC20(token).approve(address(moloch), type(uint256).max);
        
        uint256 netDraw;
        if (checkaToken(token)){
            //Checks health before withdraw
            require(isHealthy(), "AP::not healthy enough");
            //Pulls smaller withdraw fee
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
        
        //Updates accounting for earnings, which have moved to the DAO 
        earningsPeg[token] -= int(amount);
        actions[proposalId] = action; 
        emit WithdrawToDAO(proposalId, msg.sender, token, amount);
        return proposalId;
    }
    
    /**
     * Executes the proposeWithdrawCollateral() proposal once it's passed
     * @dev requires a special processing function in order to check health and track remaning assets  
     * @dev calls the aavePool withdraw() function to swap aTokens for tokens back to the aavePartyMinions
     * @param proposalId The id of the associated proposal
     **/ 
    
    function executeCollateralWithdraw(uint256 proposalId) external nonReentrant memberOnly returns (uint256) {
         
         CollateralWithdraw storage withdraw = collateralWithdraws[proposalId];
         bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
         require(flags[2], "AP::proposal not passed");
         require(!withdraw.executed, "AP::already executed");
         // Recheck health factor, which could have changed since proposal
         require(isHealthy(), "AP::not healthy enough");
         
         //Fetchs aToken address
         (address aToken,,) = getAaveTokenAddresses(withdraw.token);
         //Subtracts fees in aTokens
         uint256 fee = pullEarningsFees(aToken, withdraw.amount);
         uint256 netWithdraw = withdraw.amount - fee;
         //Withdraws net amount from Aave into the minion or DAO
         uint256 withdrawAmt = pool.withdraw(
             withdraw.token, 
             netWithdraw, 
             withdraw.destination
             );
             
         collateralWithdraws[proposalId].executed = true;
         
        // Adjust earnings peg for aTokens converted back into reserveTokens
         earningsPeg[aToken] -= int(withdraw.amount);
         emit CollateralWithdrawExecuted(proposalId, withdrawAmt);
         return proposalId;
    }
    
    /**
     * Executes the proposeRepayLoan() proposal once it's passed
     * @dev repays loan by sending tokens and having Aave burn dTokens
     * @param proposalId The id of the associated proposal
     **/ 
    
    function executeLoanRepay(uint256 proposalId) external nonReentrant memberOnly returns (uint256) {
        
        LoanRepayment storage repay = loanRepayments[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
        require(flags[2], "AP::proposal not passed");
        require(!repay.executed, "AP::already executed");

        uint256 repaidAmt = pool.repay(
            repay.token, 
            repay.amount, 
            repay.rateMode, 
            repay.onBehalfOf
            );
        repay.executed = true;
        
        // Adjust earnings peg to reflect debt repaid 
        earningsPeg[repay.token] -= int(repaidAmt);
        emit RepayLoanExecuted(proposalId);
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
        require(!flags[0], "AP::proposal already sponsored");
        
        if (propType == 1){
            Deposit storage prop = deposits[proposalId];
            require(msg.sender == prop.proposer, "AP::not proposer");
        } else if (propType == 2) {
            Loan storage prop = loans[proposalId];
            require(msg.sender == prop.proposer, "AP::not proposer");
        } else if (propType == 3) {
            CollateralWithdraw storage prop = collateralWithdraws[proposalId];
            require(msg.sender == prop.proposer, "AP::not proposer");
        } else if (propType == 4) {
            LoanRepayment storage prop = loanRepayments[proposalId];
            require(msg.sender == prop.proposer, "AP::not proposer");
        }
        
        emit Canceled(proposalId, propType, "undoAaveProp");
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
        require(!flags[0], "AP::proposal already sponsored");
        
        moloch.cancelProposal(proposalId);
        emit Canceled(proposalId, action.actionType, "undoAction");
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
     
    function withdrawMyEarnings(address token, address destination) external nonReentrant memberOnly returns (uint256) {
    
        require(rewardsOn[token], "AP::rewards not on");
        // Check health before withdrawing earnings, which are likely aTokens
        require(isHealthy(), "AP::not healthy enough");
        // Restrict destination to DAO or member for v1
        require(destination == msg.sender || destination == address(moloch), "not acceptable destination");
        
        // Get earnings and fees
        uint256 myEarnings = calcMemberEarnings(token, msg.sender);
        uint256 fees = pullEarningsFees(token, myEarnings);
        
        // Transfer member earnings - fees 
        uint256 transferAmt = myEarnings - fees;
        IERC20(token).transfer(destination, uint256(transferAmt));
        
        emit EarningsWithdraw(msg.sender, token, transferAmt, destination);
        return myEarnings;
    }
    
    /**
     * Simple function to withdraw the fees on earnings
     * @dev Is often withdrawing the aToken
     * @param token The address of the token 
     * @param amount The amount being withdrawn
     **/ 
     
    function pullEarningsFees(address token, uint256 amount) internal returns (uint256) {
        
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
     
    function pullWithdrawFees(address token, uint256 amount) internal returns (uint256){
        uint256 feeToPull = calcFees(token, amount) / WITHDRAW_FACTOR; //lowers fee by factor of 10 
        IERC20(token).transfer(feeAddress, feeToPull);

        return feeToPull;
    }
    
    
    /**
     * @dev Simple function to turn rewardsOn for a token
     * @param token The address of the token having its earnings EarningsToggled
     * @param details Human readable details for the proposal
     **/ 
    
    function proposeToggleEarnings(address token, string memory details) external memberOnly returns (uint256) {
        
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
        emit ProposeToggleEarnings(token);
        return proposalId;
    }
    
     /**
     * @notice Executes function above when proposal has passed
     * @param proposalId of that EarningsToggled proposal
     **/
     
     function executeToggleEarnings(uint256 proposalId) external nonReentrant memberOnly returns (address, bool) {
        Action storage action = actions[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
        require(flags[2], "AP::proposal not passed");
        require(!action.executed, "AP::already executed");
        require(action.actionType == 2, "AP::right actionType");
        action.executed = true; //Marks as executed
        
        if (!rewardsOn[action.token]){
            //Turns on rewards
            rewardsOn[action.token] = true;
            emit EarningsToggled(proposalId, true);
            return (action.token, true);
        } else {
            //Turns off rewards, if already on
            rewardsOn[action.token] = false;
            emit EarningsToggled(proposalId, false);
            return (action.token, false);
        }
        
        
    }
    
    /**********************************************************************
                             VIEW & HELPER FUNCTIONS 
    ***********************************************************************/
    
    //  --EARNINGS AND FEE FUNCTIONS-- //
    
    /**
     * Calculates base fees   
     * @dev Total earnings = balance of aToken in minion - earnings peg
     * @dev Adjust fee by amt being withdrawn / total balance of aToken in minion
     * @param token The address of the aToken 
     * @param amount The amount being withdrawn
     **/ 
    
    function calcFees(address token, uint256 amount) public view returns (uint256) {
        
        uint256 peg = zero(earningsPeg[token]); // earnings peg for that aToken to get base 
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        uint256 fee = (tokenBalance - peg) * feeFactor * amount / FEE_BASE / tokenBalance; 
        
        return fee;
    }
    
    /**
     * Calculates member earnings w/r to a single token  
     * @dev Member earnings = balance of member's share of aToken in minion - member's share of earnings peg
     * @dev Adjusted by previous withdraws of the token for earnings 
     * @param token The address of the aToken 
     * @param user The amount being withdrawn
     **/ 
    
    function calcMemberEarnings(address token, address user) public view returns (uint256) {
        
        //Get all the shares and loot inputs
        uint256 memberSharesAndLoot = getMemberSharesAndLoot(user);
        uint256 molochSharesAndLoot = getMolochSharesAndLoot();
        
        //Get current balance and basis 
        uint256 currentBalance = fairShare(IERC20(token).balanceOf(address(this)), memberSharesAndLoot, molochSharesAndLoot);
        uint256 basis = (zero(earningsPeg[token]) / molochSharesAndLoot * memberSharesAndLoot) + aTokenRedemptions[user][token];
        uint256 earnings = currentBalance - basis;

        return earnings;
    }
    
    
    //  -- AAVE VIEW FUNCTIONS -- //
    
    /**
     * Checks whether the current health is greater minHealthFactor
     * @dev Should check transaction's effects on health factor on front-end
     **/ 
    
    function isHealthy() public view returns (bool){
        uint256 health = getHealthFactor(address(this));
        return health > minHealthFactor;
    }
    
    function getHealthFactor(address user) public view returns (uint256) {
        (,,,,, uint256 health) = pool.getUserAccountData(user);
        return health;
    }
    
    function getOurCompactReserveData(address token) public view returns (
        uint256 aTokenBalance, 
        uint256 stableDebt, // interest rate on stable debt
        uint256 variableDebt, // interest rate on variable debt
        uint256 liquidityRate, //interest rate being earned
        bool usageAsCollateralEnabled
    ){
    
       (aTokenBalance, 
       stableDebt, 
       variableDebt,,,,
       liquidityRate,, 
       usageAsCollateralEnabled
       ) = data.getUserReserveData(token, address(this));
       
    }
    
    function getAaveTokenAddresses(address token) public view returns (
        address aTokenAddress, 
        address stableDebtTokenAddress, 
        address variableDebtTokenAddress) {
            
        (aTokenAddress, 
         stableDebtTokenAddress, 
         variableDebtTokenAddress
        ) = data.getReserveTokensAddresses(token);

    }
    
    function checkaToken(address token) internal view returns (bool) {
        
        (address aToken,,) = getAaveTokenAddresses(token);
        if (aToken == address(0)){
            return true;
        } else {
            return false;
        }
    }
    
    //  -- Moloch-related View Functions -- //
    
    function isMember(address user) internal view returns (bool) {
        (, uint256 shares,,,,) = moloch.members(user);
        return shares > 0;
    }
    
    function getMemberSharesAndLoot(address user) internal view returns (uint256){
        (, uint256 shares, uint256 loot,,,) = moloch.members(user);
        return shares + loot;
    }
    
    
    function getMolochSharesAndLoot() internal view returns (uint256){
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

        return shares * balance / totalShares;
    }
    
    //  -- HELPER FUNCTIONS -- //
    
    /**
     * Withdraws funds from any Moloch into this Minion
     * Set as an public function to allow for member or this contract to call via proposal
     * @param targetDao the dao from which the minion is withdrawing funds
     * @param token the token being withdrawn 
     * @param amount the amount being withdrawn 
     */ 
    
    function doWithdraw(
        address targetDao, 
        address token, 
        uint256 amount
    ) public returns (address, uint256){
        
        require(moloch.getUserTokenBalance(address(this), token) >= amount, "AP::user balance < amount");
        moloch.withdrawBalance(token, amount); // withdraw funds from DAO
        earningsPeg[token] += int(amount);
        
        emit WithdrawToMinion(targetDao, token, amount);
        return (token, amount);
    }
    

    
    /**
     * Simple function to update the lending pool address 
     * Can be called by any member of the DAO
     **/
     
    function resetAavePool() public returns (address) {
        
        address updatedPool = provider.getLendingPool();
        require (aavePool != updatedPool, "AP::already set");
        aavePool = updatedPool;
        
        return aavePool;
    }
    
    /**
     * Simple function to update the data provider address 
     * Can be called by any member of the DAO
     **/
    
    function resetDataProvider() public returns (address){
        
        address _dataProvider = provider.getAddress("0x1");
        require(aaveData != _dataProvider, "AP::already set");
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
    address public aavePool;
    address public aaveData;
    
    // Tracking minions
    address immutable public template; // fixed template for minion using eip-1167 proxy pattern
    address[] public aavePartyMinions; // list of the minions 
    uint256 public counter; // counter to prevent overwriting minions
    mapping(address => mapping(uint256 => address)) public ourMinions; //mapping minions to DAOs;
    
    modifier ownerOnly() {
        require(msg.sender == owner, "APFactory::only owner");
        _;
    }
    
    event SummonAavePartyMinion(address partyAddress, address dao, address protocol, address feeAddress, uint256 minionId, uint256 feeFactor, string desc, string name);
    
    constructor(address _template)  {
        template = _template;
        owner = msg.sender;
        aavePool = 0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf; // matic address
        aaveData = 0x7551b5D2763519d4e37e8B81929D336De671d46d; // matic address
    }
    

    function summonAavePartyMinion(
            address _dao, 
            address _feeAddress,
            uint256 _feeFactor,
            uint256 _minHealthFactor,
            string memory _desc) 
    external returns (address) {
        require(isMember(_dao) || msg.sender == owner, "APFactory:: not member and not owner");
        
        string memory name = "Aave Party Minion";
        uint256 minionId = counter ++;
        PoolPartyAaveMinion aaveparty = PoolPartyAaveMinion(createClone(template));
        aaveparty.init(_dao, _feeAddress, aavePool, aaveData, minionId, _feeFactor, _minHealthFactor, _desc);
        
        emit SummonAavePartyMinion(address(aaveparty), _dao, aavePool, _feeAddress, minionId, _feeFactor, _desc, name);
        
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
    
    function updateOwner(address _newOwner) external ownerOnly returns (address) {
        owner = _newOwner;
        return owner;
    }
    
    function updatePool(address _newPool) external ownerOnly {
        aavePool = _newPool;
    }
    
    function updateData(address _newData) external ownerOnly {
        require(msg.sender == owner, "APFactory::only owner");
        aaveData = _newData;
    }
    
}
