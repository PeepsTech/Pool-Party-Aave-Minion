// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.3;
pragma experimental ABIEncoderV2;

interface ILendingPoolAddressesProvider {
    
    event LendingPoolUpdated(address indexed newAddress);
    
    function getLendingPool() external view returns (address);
    
    function getPriceOracle() external view returns (address);
    
    function getLendingRateOracle() external view returns (address);
    
    function getAddress(bytes32 id) external view returns (address);
    
}   

interface IProtocolDataProvider {
  struct TokenData {
    string symbol;
    address tokenAddress;
  }

  function ADDRESSES_PROVIDER() external view returns (ILendingPoolAddressesProvider);
  function getAllReservesTokens() external view returns (TokenData[] memory);
  function getAllATokens() external view returns (TokenData[] memory);
  function getReserveConfigurationData(address asset) external view returns (uint256 decimals, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus, uint256 reserveFactor, bool usageAsCollateralEnabled, bool borrowingEnabled, bool stableBorrowRateEnabled, bool isActive, bool isFrozen);
  function getReserveData(address asset) external view returns (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt, uint256 liquidityRate, uint256 variableBorrowRate, uint256 stableBorrowRate, uint256 averageStableBorrowRate, uint256 liquidityIndex, uint256 variableBorrowIndex, uint40 lastUpdateTimestamp);
  function getUserReserveData(address asset, address user) external view returns (uint256 currentATokenBalance, uint256 currentStableDebt, uint256 currentVariableDebt, uint256 principalStableDebt, uint256 scaledVariableDebt, uint256 stableBorrowRate, uint256 liquidityRate, uint40 stableRateLastUpdated, bool usageAsCollateralEnabled);
  function getReserveTokensAddresses(address asset) external view returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
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