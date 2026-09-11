//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/IAccessControlUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {ISubStaker} from "./interfaces/ISubStaker.sol";
import {IStakeHub} from "./interfaces/IStakeHub.sol";
import {IStakeCredit} from "./interfaces/IStakeCredit.sol";

/**
 * @title SubStaker
 * @author Lista DAO
 * @notice A second BNB delegator identity owned by ListaStakeManager.
 *
 * @dev The staking entry points deliberately mirror `IStakeHub`'s signatures, so the manager can
 *      treat "stake via StakeHub directly" and "stake via the SubStaker" as a single call site that
 *      differs only by target address. The vote power flag is accepted and ignored - voting power
 *      moves only through `setVoteDelegatee`.
 *
 * @dev govBNB is an ERC20Votes token: a delegator's whole balance follows a single delegatee,
 *      and neither govBNB nor StakeCredit shares can be transferred. Splitting Lista's voting
 *      power therefore requires a second account that stakes in its own name. That is all this
 *      contract is - it holds StakeCredit shares and the govBNB minted against them, so that
 *      tranche can point at a different delegatee than the manager's own.
 *
 *      Two invariants make it safe to hand pool funds to:
 *      - `stakeManager` is the only caller of every state-changing function;
 *      - `stakeManager` is the only address BNB can ever be sent to (see `_send`).
 *
 *      This contract shares the manager's validator set: any whitelisted validator may be passed
 *      in, and both accounts may hold a position on the same validator at the same time.
 */
contract SubStaker is ISubStaker, Initializable, UUPSUpgradeable {
    address private constant STAKE_HUB = 0x0000000000000000000000000000000000002002;
    address private constant GOV_BNB = 0x0000000000000000000000000000000000002005;

    // Address of the ListaStakeManager that owns this contract
    address public override stakeManager;

    error NotStakeManager();
    error NotAdmin();
    error ZeroAddress();
    error TransferFailed();
    error NothingToClaim();

    modifier onlyStakeManager() {
        if (msg.sender != stakeManager) revert NotStakeManager();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _stakeManager - Address of the ListaStakeManager proxy
     */
    function initialize(address _stakeManager) external override initializer {
        if (_stakeManager == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();

        stakeManager = _stakeManager;
    }

    /**
     * @dev Delegates the BNB sent along with the call to `_validator`
     * @param _validator - Operator address of the BSC validator node
     * @notice The vote power flag is hardcoded to false; voting power is only ever moved by
     *         `setVoteDelegatee`, never as a side effect of a staking operation
     */
    function delegate(address _validator, bool) external payable onlyStakeManager {
        IStakeHub(STAKE_HUB).delegate{value: msg.value}(_validator, false);
    }

    /**
     * @param _validator - Operator address of the BSC validator node
     * @param _shares - Amount of StakeCredit shares to undelegate
     */
    function undelegate(address _validator, uint256 _shares) external onlyStakeManager {
        IStakeHub(STAKE_HUB).undelegate(_validator, _shares);
    }

    /**
     * @dev Claims matured unbond requests and forwards the exact proceeds to the manager
     * @param _validator - Operator address of the BSC validator node
     * @param _requestNumber - Number of unbond requests to claim; 0 means all
     * @notice Only the claimed amount is forwarded, so a donation to this contract can never
     *         be mistaken for claim proceeds by the manager's balance-delta accounting
     */
    function claim(address _validator, uint256 _requestNumber) external onlyStakeManager {
        uint256 balanceBefore = address(this).balance;
        IStakeHub(STAKE_HUB).claim(_validator, _requestNumber);
        uint256 amount = address(this).balance - balanceBefore;
        if (amount == 0) revert NothingToClaim();

        _send(amount);
    }

    /**
     * @dev Moves a position between validators within this account; no unbonding period
     * @param _srcValidator - Operator address to move away from
     * @param _dstValidator - Operator address to move to
     * @param _shares - Amount of StakeCredit shares to move
     */
    function redelegate(address _srcValidator, address _dstValidator, uint256 _shares, bool) external onlyStakeManager {
        IStakeHub(STAKE_HUB).redelegate(_srcValidator, _dstValidator, _shares, false);
    }

    /**
     * @dev Points this account's entire govBNB balance at `_delegatee`
     * @param _delegatee - Address to receive the voting power
     * @notice Callable by the manager's DEFAULT_ADMIN_ROLE rather than the manager itself, so the
     *         manager needs no forwarder. This moves voting power only; not a wei of BNB moves
     */
    function setVoteDelegatee(address _delegatee) external override {
        // Governance lives on the manager: its DEFAULT_ADMIN_ROLE moves this account's voting power
        if (!IAccessControlUpgradeable(stakeManager).hasRole(0x00, msg.sender)) revert NotAdmin();

        IVotesUpgradeable(GOV_BNB).delegate(_delegatee);

        emit VoteDelegateeSet(_delegatee);
    }

    /**
     * @dev Sends any stranded BNB back to the manager; callable by anyone because the
     *      destination is fixed and there is nothing here to abuse
     */
    function sweep() external override {
        uint256 amount = address(this).balance;
        _send(amount);

        emit Swept(amount);
    }

    /**
     * @param _validator - Operator address of the BSC validator node
     * @return pooled - Delegated BNB including rewards
     * @return locked - BNB currently unbonding
     * @return shares - StakeCredit shares held
     * @return claimable - BNB of matured unbond requests
     */
    function position(address _validator)
        external
        view
        override
        returns (uint256 pooled, uint256 locked, uint256 shares, uint256 claimable)
    {
        IStakeCredit credit = IStakeCredit(IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator));

        pooled = credit.getPooledBNB(address(this));
        locked = credit.lockedBNBs(address(this), 0);
        shares = credit.balanceOf(address(this));

        uint256 count = credit.claimableUnbondRequest(address(this));
        for (uint256 i = 0; i < count; ++i) {
            claimable += credit.unbondRequest(address(this), i).bnbAmount;
        }
    }

    /// @return The address this account's voting power currently points at
    function voteDelegatee() external view override returns (address) {
        return IVotesUpgradeable(GOV_BNB).delegates(address(this));
    }

    /// @return The govBNB balance of this account
    function govVotes() external view override returns (uint256) {
        return IERC20Upgradeable(GOV_BNB).balanceOf(address(this));
    }

    /// @dev The only place BNB leaves this contract, and the destination is not a parameter
    function _send(uint256 _amount) private {
        if (_amount == 0) return;

        (bool success,) = stakeManager.call{value: _amount}("");
        if (!success) revert TransferFailed();
    }

    /// @dev Upgrades are gated on the manager's DEFAULT_ADMIN_ROLE so governance lives in one place
    function _authorizeUpgrade(address) internal view override {
        if (!IAccessControlUpgradeable(stakeManager).hasRole(0x00, msg.sender)) revert NotAdmin();
    }

    /**
     * @dev StakeCredit pays out with `call{gas: transferGasLimit}`, which is 5000 on BSC today.
     *      This must stay empty - a single SSTORE here would make every `claim` revert.
     */
    receive() external payable {}

    uint256[49] private __gap;
}
