pragma solidity 0.6.6;

import {SafeMath} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/SafeMath.sol";
import {IERC20} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";

import "./IAAVELendingPoolV2.sol";

contract PoolPartyMatic {
    using SafeMath for uint256;

    IAAVELendingPoolV2 public aavePool;
    mapping(address => bool) public isRegisteredDAO;

    event SubmitProposal(
        address indexed targetDAO,
        address indexed asset,
        uint256 amount,
        uint256 sharesRequested,
        uint256 lootRequested,
        bytes32 details
    );
    event MakeDeposit(
        address indexed targetDAO,
        address indexed asset,
        uint256 amount
    );

    /// @param _aavePool aave lending pool v2 address.
    constructor(IAAVELendingPoolV2 _aavePool, address[] memory _registeredDAOs)
        public
    {
        aavePool = _aavePool;

        for (uint256 i = 0; i < _registeredDAOs.length; i++) {
            isRegisteredDAO[_registeredDAOs[i]] = true;
        }
    }

    function _deposit(address asset, uint256 amount) internal {
        require(amount != 0, "PoolPartyMatic: non-zero amount required");
        require(
            IERC20(asset).transferFrom(msg.sender, address(this), amount),
            "PoolPartyMatic: token transfer failed"
        );

        aavePool.deposit(asset, amount, address(this), 0);
    }

    function submitProposal(
        address targetDAO,
        address asset,
        uint256 amount,
        uint256 sharesRequested,
        uint256 lootRequested,
        bytes32 details
    ) public returns (uint256 proposalId) {
        require(
            isRegisteredDAO[targetDAO] == true,
            "PoolPartyMatic: not registered DAO"
        );

        _deposit(asset, amount);

        (bool success, bytes memory data) =
            address(targetDAO).call(
                abi.encodeWithSignature(
                    "submitProposal(address,uint256,uint256,uint256,uint256,uint256,address,address,bytes32)",
                    msg.sender,
                    amount,
                    sharesRequested,
                    lootRequested,
                    0,
                    6,
                    asset,
                    asset,
                    details
                )
            );

        require(success, "PoolPartyMatic: failed to submit a proposal");

        emit SubmitProposal(
            targetDAO,
            asset,
            amount,
            sharesRequested,
            lootRequested,
            details
        );

        return abi.decode(data, (uint256));
    }

    function deposit(
        address targetDAO,
        address asset,
        uint256 amount
    ) public {
        require(
            isRegisteredDAO[targetDAO] == true,
            "PoolPartyMatic: not registered DAO"
        );

        _deposit(asset, amount);

        (bool success, ) =
            address(targetDAO).call(
                abi.encodeWithSignature(
                    "makeDeposit(address,address,uint256)",
                    msg.sender,
                    asset,
                    amount
                )
            );

        require(success, "PoolPartyMatic: failed to make deposit");

        emit MakeDeposit(targetDAO, asset, amount);
    }
}
