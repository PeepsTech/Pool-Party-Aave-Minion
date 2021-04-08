// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.3;

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