//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {ISLisBNB} from "./interfaces/ISLisBNB.sol";
import {IStakeHub} from "./interfaces/IStakeHub.sol";
import {IStakeCredit} from "./interfaces/IStakeCredit.sol";

/**
 * @title Stake Manager Contract
 * @dev Handles Staking of BNB on BSC
 */
contract ListaStakeManager is
    IStakeManager,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public totalSnBnbToBurn; // received User withdraw requests; no use in new logic

    uint256 public totalDelegated; // delegated + unbonding
    uint256 public amountToDelegate; // total BNB to delegate for next batch

    uint256 public requestUUID; // global UUID for each user withdrawal request
    uint256 public nextConfirmedRequestUUID; // req whose uuid < nextConfirmedRequestUUID is claimable

    uint256 public reserveAmount; // buffer amount for undelegation
    uint256 public totalReserveAmount;

    address private slisBnb;
    address private bscValidator; // the initial BSC validator funds will be migrated to

    mapping(uint256 => BotUndelegateRequest)
        private uuidToBotUndelegateRequestMap; // no use in new logic
    mapping(address => WithdrawalRequest[]) private userWithdrawalRequests;

    uint256 public constant TEN_DECIMALS = 1e10;
    bytes32 public constant BOT = keccak256("BOT");

    address private manager;
    address private proposedManager;
    uint256 public synFee; // range {0-10_000_000_000}

    address public revenuePool;
    address public redirectAddress;

    address private constant STAKE_HUB = 0x0000000000000000000000000000000000002002;

    mapping(address => bool) public validators;
    bool public delegateVotePower; // delegate voting power to validator or not

    uint256 public undelegatedQuota; // the amount Bnb received but not claimable yet
    UserRequest[] internal withdrawalQueue; // queue for requested withdrawals

    mapping(uint256 => uint256) public requestIndexMap; // uuid => index in withdrawalQueue
    address[] public creditContracts;
    mapping(address => bool) public creditStates; // states of credit contracts; use mapping to reduce gas of `reveive()`
    uint256 public unbondingBnb; // the amount of BNB unbonding in fly; precise bnb amount

    uint256 public totalFee;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _slisBnb - Address of SlisBnb Token on BNB Smart Chain
     * @param _admin - Address of the admin
     * @param _manager - Address of the manager
     * @param _bot - Address of the Bot
     * @param _synFee - Rewards fee to revenue pool
     * @param _revenuePool - Revenue pool to receive rewards
     * @param _validator - Validator to delegate BNB
     */
    function initialize(
        address _slisBnb,
        address _admin,
        address _manager,
        address _bot,
        uint256 _synFee,
        address _revenuePool,
        address _validator
    ) external override initializer {
        __AccessControl_init();
        __Pausable_init();

        require(
            ((_slisBnb != address(0)) &&
                (_admin != address(0)) &&
                (_manager != address(0)) &&
                (_validator != address(0)) &&
                (_revenuePool != address(0)) &&
                (_bot != address(0))),
            "zero address provided"
        );
        require(_synFee <= TEN_DECIMALS, "_synFee must not exceed (100%)");

        _setRoleAdmin(BOT, DEFAULT_ADMIN_ROLE);
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        _setupRole(BOT, _bot);

        manager = _manager;
        slisBnb = _slisBnb;
        bscValidator = _validator;
        synFee = _synFee;
        revenuePool = _revenuePool;

        emit SetManager(_manager);
        emit SetBSCValidator(bscValidator);
        emit SetRevenuePool(revenuePool);
        emit SetSynFee(_synFee);
    }

    /**
     * @dev Allows user to deposit Bnb and mint SlisBnb
     */
    function deposit() external payable override whenNotPaused {
        uint256 amount = msg.value;
        require(amount > 0, "Invalid Amount");

        uint256 slisBnbToMint = convertBnbToSnBnb(amount);
        require(slisBnbToMint > 0, "Invalid SlisBnb Amount");
        amountToDelegate += amount;

        ISLisBNB(slisBnb).mint(msg.sender, slisBnbToMint);

        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @dev Allows bot to delegate users' funds to given BSC validator
     * @param _validator - Operator address of the BSC validator to delegate to
     * @param _amount - Amount of BNB to delegate
     * @notice The amount should be greater than minimum delegation
     */
    function delegateTo(address _validator, uint256 _amount)
        external
        override
        whenNotPaused
        onlyRole(BOT)
    {
        require(amountToDelegate >= _amount, "Not enough BNB to delegate");

        require(validators[_validator] == true, "Inactive validator");
        require(_amount >= IStakeHub(STAKE_HUB).minDelegationBNBChange(), "Insufficient Delegation Amount");

        amountToDelegate -= _amount;
        totalDelegated += _amount;

        IStakeHub(STAKE_HUB).delegate{value: _amount}(_validator, delegateVotePower);

        emit DelegateTo(_validator, _amount, delegateVotePower);
    }

    /**
     * @param srcValidator the operator address of the validator to be redelegated from
     * @param dstValidator the operator address of the validator to be redelegated to
     * @param _amount the bnb amount to be redelegated
     */
    function redelegate(address srcValidator, address dstValidator, uint256 _amount)
        external
        override
        whenNotPaused
        onlyManager
    {
        require(srcValidator != dstValidator, "Invalid Redelegation");
        require(validators[dstValidator], "Inactive dst validator");

        uint256 shares = convertBnbToShares(srcValidator, _amount);

        // redelegate through native staking contract
        IStakeHub(STAKE_HUB).redelegate(srcValidator, dstValidator, shares, delegateVotePower);

        emit ReDelegate(srcValidator, dstValidator, shares);
    }

    /**
     * @dev Allow users to request for unstake/withdraw funds
     * @param _amountInSlisBnb - Amount of SlisBnb to swap for withdraw
     * @notice User must have approved this contract to spend SlisBnb
     */
    function requestWithdraw(uint256 _amountInSlisBnb)
        external
        override
        whenNotPaused
    {
        require(_amountInSlisBnb > 0, "Invalid Amount");

        uint256 bnbToWithdraw = convertSnBnbToBnb(_amountInSlisBnb);
        require(bnbToWithdraw > 0, "Bnb amount is too small");

        requestUUID++;
        userWithdrawalRequests[msg.sender].push(
            WithdrawalRequest({
                uuid: requestUUID,
                amountInSnBnb: _amountInSlisBnb,
                startTime: block.timestamp
            })
        );

        withdrawalQueue.push(
            UserRequest({
                uuid: requestUUID,
                amount: bnbToWithdraw,
                amountInSlisBnb: _amountInSlisBnb
            })
        );
        requestIndexMap[requestUUID] = withdrawalQueue.length - 1;

        IERC20Upgradeable(slisBnb).safeTransferFrom(
            msg.sender,
            address(this),
            _amountInSlisBnb
        );
        emit RequestWithdraw(msg.sender, _amountInSlisBnb);
    }

    /**
     * @dev Users uses this function to claim the requested withdrawals
     * @param _idx - index of the request of getUserWithdrawalRequests()
     */
    function claimWithdraw(uint256 _idx) external override whenNotPaused {
        address user = msg.sender;
        WithdrawalRequest[] storage userRequests = userWithdrawalRequests[user];

        require(_idx < userRequests.length, "Invalid index");

        WithdrawalRequest storage withdrawRequest = userRequests[_idx];
        uint256 uuid = withdrawRequest.uuid;
        uint256 amount;

        // 1. queue.length == 0 => old logic
        // 2. queue.length > 0 && uuid < queue[0].uuid => old logic
        // 3. queue.length > 0 && uuid >= queue[0].uuid => new logic

        if (withdrawalQueue.length != 0 && uuid >= withdrawalQueue[0].uuid) {
            // new logic
            UserRequest storage request = withdrawalQueue[requestIndexMap[uuid]];
            require(uuid < nextConfirmedRequestUUID, "Not able to claim yet");
            amount = request.amount;
        } else {
            // old logic
            uint256 amountInSlisBnb = withdrawRequest.amountInSnBnb;
            BotUndelegateRequest
                storage botUndelegateRequest = uuidToBotUndelegateRequestMap[uuid];
            require(botUndelegateRequest.endTime != 0, "Not able to claim yet");
            uint256 totalBnbToWithdraw_ = botUndelegateRequest.amount;
            uint256 totalSlisBnbToBurn_ = botUndelegateRequest.amountInSnBnb;
            amount = (totalBnbToWithdraw_ * amountInSlisBnb) /
            totalSlisBnbToBurn_;
        }

        userRequests[_idx] = userRequests[userRequests.length - 1];
        userRequests.pop();

        AddressUpgradeable.sendValue(payable(user), amount);

        emit ClaimWithdrawal(user, _idx, amount);
    }


    /**
     * @dev Undelegate the BNB amount equivalent to totalSnBnbToBurn from the bscValidator.
     *      This method is used to process the withdrawal requests happened before 2nd upgrade(multi-validator upgrade);
     *      This method should be called only once before calling undelegateFrom after 2nd upgrade.
     * @return _uuid - unique id against which this Undelegation event was logged
     * @return _amount - the actual amount of BNB to be undelegated
     */
    function undelegate()
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _amount)
    {
        require(totalSnBnbToBurn > 0, "Nothing to undelegate");
        _uuid = withdrawalQueue.length != 0 ? withdrawalQueue[0].uuid - 1: requestUUID;
        // Pin _uuid to the last `nextUndelegateUUID` in old version

        uint256 totalSlisBnbToBurn_ = totalSnBnbToBurn; // To avoid Reentrancy attack
        uint256 bnbAmount_ = convertSnBnbToBnb(totalSlisBnbToBurn_);
        uint256 shares_ = convertBnbToShares(bscValidator, bnbAmount_ + reserveAmount);

        uuidToBotUndelegateRequestMap[_uuid] = BotUndelegateRequest({
            startTime: block.timestamp,
            endTime: 0,
            amount: bnbAmount_,
            amountInSnBnb: totalSlisBnbToBurn_
        });

        totalSnBnbToBurn = 0;
        _amount = convertSharesToBnb(bscValidator, shares_);
        unbondingBnb += _amount;

        IStakeHub(STAKE_HUB).undelegate(bscValidator, shares_);

        emit Undelegate(_uuid, bnbAmount_, shares_);
    }

    /**
     * @dev Bot uses this function to undelegate BNB from a validator
     * @param _operator - Operator address of validator to undelegate from
     * @param _amount - Amount of bnb to undelegate
     * @return bnbToUndelegate - bnb amount to be undelegated by bot
     * @notice Bot should invoke `undelegate()` first to process old requests before calling this function
     */
    function undelegateFrom(address _operator, uint256 _amount)
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256)
    {
        require(totalSnBnbToBurn == 0, "Old requests should be processed first");
        require(_amount <= (getAmountToUndelegate() + reserveAmount), "Given bnb amount is too large");
        uint256 _shares = convertBnbToShares(_operator, _amount);
        uint256 _actualBnbAmount = convertSharesToBnb(_operator, _shares);

        unbondingBnb += _actualBnbAmount;
        IStakeHub(STAKE_HUB).undelegate(_operator, _shares);

        emit UndelegateFrom(_operator, _actualBnbAmount, _shares);
        return getAmountToUndelegate();
    }

    /**
     * @dev Claim unbonded BNB and rewards from the validator
     * @param _validator - The operator address of the validator
     * @return _uuid - the next confirmed request uuid
     * @return _amount - the amount of BNB claimed, staking rewards included
     * @notice Old requests should be undelegated first via calling `undelegate()`
     */
    function claimUndelegated(address _validator)
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _amount)
    {
        require(totalSnBnbToBurn == 0, "Old request not undelegated yet");

        uint256 balanceBefore = address(this).balance;
        IStakeHub(STAKE_HUB).claim(_validator, 0);
        require(address(this).balance > balanceBefore, "Nothing to claim");
        uint256 undelegatedAmount = address(this).balance - balanceBefore;

        undelegatedQuota += undelegatedAmount;
        unbondingBnb -= undelegatedAmount;

        uint256 coveredAmount = 0;
        uint256 coveredSlisBnbAmount = 0;
        uint256 oldLastUUID = requestUUID;

        if (withdrawalQueue.length != 0) {
            oldLastUUID = withdrawalQueue[0].uuid - 1;
        }

        for (uint256 i = nextConfirmedRequestUUID; i <= oldLastUUID; ++i) {
            BotUndelegateRequest storage botRequest = uuidToBotUndelegateRequestMap[i];
            if (undelegatedQuota < botRequest.amount) {
                emit ClaimUndelegatedFrom(_validator, nextConfirmedRequestUUID, undelegatedAmount);
                return (nextConfirmedRequestUUID, undelegatedAmount);
            }
            botRequest.endTime = block.timestamp;
            undelegatedQuota -= botRequest.amount;
            coveredAmount += botRequest.amount;
            coveredSlisBnbAmount += botRequest.amountInSnBnb;
            ++nextConfirmedRequestUUID;
        }

        // new logic
        for (uint256 i = nextConfirmedRequestUUID; i <= requestUUID; ++i) {
            UserRequest storage req = withdrawalQueue[requestIndexMap[i]];
            if (req.uuid == 0 || req.amount > undelegatedQuota) {
                break;
            }
            undelegatedQuota -= req.amount;
            coveredAmount += req.amount;
            coveredSlisBnbAmount += req.amountInSlisBnb;
            ++nextConfirmedRequestUUID;
        }

        totalDelegated -= coveredAmount;
        if (coveredSlisBnbAmount > 0) {
            ISLisBNB(slisBnb).burn(address(this), coveredSlisBnbAmount);
        }

        _uuid = nextConfirmedRequestUUID;
        _amount = undelegatedAmount;

        emit ClaimUndelegatedFrom(_validator, _uuid, _amount);
    }

    /**
     * @dev Deposit reserved funds to the contract
     */
    function depositReserve() external payable override whenNotPaused onlyRedirectAddress{
        uint256 amount = msg.value;
        require(amount > 0, "Invalid Amount");

        totalReserveAmount += amount;
    }

    function withdrawReserve(uint256 amount) external override whenNotPaused onlyRedirectAddress{
        require(amount <= totalReserveAmount, "Insufficient Balance");
        totalReserveAmount -= amount;
        AddressUpgradeable.sendValue(payable(msg.sender), amount);
    }

    function setReserveAmount(uint256 amount) external override onlyManager {
        reserveAmount = amount;
        emit SetReserveAmount(amount);
    }

    function proposeNewManager(address _address) external override onlyManager {
        require(manager != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        proposedManager = _address;

        emit ProposeManager(_address);
    }

    function acceptNewManager() external override {
        require(
            msg.sender == proposedManager,
            "Accessible only by Proposed Manager"
        );

        manager = proposedManager;
        proposedManager = address(0);

        emit SetManager(manager);
    }

    function setBotRole(address _address) external override {
        require(_address != address(0), "zero address provided");

        grantRole(BOT, _address);
    }

    function revokeBotRole(address _address) external override {
        require(_address != address(0), "zero address provided");

        revokeRole(BOT, _address);
    }

    /**
     * @dev Syncs the credit contract of the validator to store in the contract
     * @param _validator - the operator address of the validator
     * @param toRemove - if true, remove the credit contract; false to add if non-existent
     */
    function syncCredits(address _validator, bool toRemove) internal {
        address credit = IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator);
        if (toRemove) {
            delete creditStates[credit];

            for (uint256 i = 0; i < creditContracts.length; i++) {
                if (creditContracts[i] == credit) {
                    creditContracts[i] = creditContracts[creditContracts.length - 1];
                    creditContracts.pop();
                    break;
                }
            }
            emit SyncCreditContract(_validator, credit, toRemove);
            return;
        } else if (creditStates[credit]) {
            // do nothing if credit already exists
            return;
        }

        creditStates[credit] = true;
        creditContracts.push(credit);

        emit SyncCreditContract(_validator, credit, toRemove);
    }

    /**
     * @dev Sets the operator address of the BSC validator initially delegated to. Call this function after 2nd upgrade done
     * @param _address - the operator address of BSC validator
     */
    function setBSCValidator(address _address)
        external
        override
        onlyManager
    {
        require(bscValidator != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        bscValidator = _address;
        syncCredits(bscValidator, false);

        emit SetBSCValidator(_address);
    }

    /**
     * @dev Sets the protocol fee to be charged on rewards
     * @param _synFee - the fee to be charged on rewards; 10_000 (100%)
     */
    function setSynFee(uint256 _synFee)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_synFee <= TEN_DECIMALS, "_synFee must not exceed 10000 (100%)");
        synFee = _synFee;

        emit SetSynFee(_synFee);
    }

    function setRedirectAddress(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(redirectAddress != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        redirectAddress = _address;

        emit SetRedirectAddress(_address);
    }


    function setRevenuePool(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(revenuePool != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        revenuePool = _address;

        emit SetRevenuePool(_address);
    }

    function whitelistValidator(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!validators[_address], "Validator should be inactive");
        require(_address != address(0), "zero address provided");

        validators[_address] = true;
        syncCredits(_address, false);

        emit WhitelistValidator(_address);
    }

    /**
     * @dev Disables the validator from the contract.
     *      Upon disabled, bot can only undelegete the funds, delegation is not allowed
     * @param _address - the operator address of the validator
     */
    function disableValidator(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(validators[_address], "Validator is not active");

        validators[_address] = false;

        emit DisableValidator(_address);
    }

    function removeValidator(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!validators[_address], "Validator is should be inactive");
        require(getDelegated(_address) == 0, "Balance is not zero");

        syncCredits(_address, true);
        delete validators[_address];

        emit RemoveValidator(_address);
    }

    function getTotalPooledBnb() public view override returns (uint256) {
        return (amountToDelegate + totalDelegated);
    }

    function getContracts()
        external
        view
        override
        returns (
            address _manager,
            address _slisBnb,
            address _bscValidator
        )
    {
        _manager = manager;
        _slisBnb = slisBnb;
        _bscValidator = bscValidator;
    }


    function getBotUndelegateRequest(uint256 _uuid)
        external
        view
        override
        returns (BotUndelegateRequest memory)
    {
        return uuidToBotUndelegateRequestMap[_uuid];
    }

    /**
     * @dev Retrieves all withdrawal requests initiated by the given address
     * @param _address - Address of an user
     * @return userWithdrawalRequests array of user withdrawal requests
     */
    function getUserWithdrawalRequests(address _address)
        external
        view
        override
        returns (WithdrawalRequest[] memory)
    {
        return userWithdrawalRequests[_address];
    }

    /**
     * @dev Checks if the withdrawRequest is ready to claim
     * @param _user - Address of the user who raised WithdrawRequest
     * @param _idx - index of request in UserWithdrawls Array
     * @return _isClaimable - if the withdraw is ready to claim yet
     * @return _amount - Amount of BNB user would receive on withdraw claim
     * @notice Use `getUserWithdrawalRequests` to get the userWithdrawlRequests Array
     */
    function getUserRequestStatus(address _user, uint256 _idx)
        external
        view
        override
        returns (bool _isClaimable, uint256 _amount)
    {
        WithdrawalRequest[] storage userRequests = userWithdrawalRequests[
            _user
        ];

        require(_idx < userRequests.length, "Invalid index");

        WithdrawalRequest storage withdrawRequest = userRequests[_idx];
        uint256 uuid = withdrawRequest.uuid;

        if (withdrawalQueue.length != 0 && uuid >= withdrawalQueue[0].uuid) {
            // new logic
            UserRequest storage request = withdrawalQueue[requestIndexMap[uuid]];
            _isClaimable = uuid < nextConfirmedRequestUUID;
            _amount = request.amount;
        } else {
            // old logic
            uint256 amountInSnBnb = withdrawRequest.amountInSnBnb;
            BotUndelegateRequest storage botUndelegateRequest = uuidToBotUndelegateRequestMap[uuid];

            // bot has triggered startUndelegation
            if (botUndelegateRequest.amount > 0) {
                uint256 totalBnbToWithdraw_ = botUndelegateRequest.amount;
                uint256 totalSnBnbToBurn_ = botUndelegateRequest.amountInSnBnb;
                _amount = (totalBnbToWithdraw_ * amountInSnBnb) / totalSnBnbToBurn_;
            } else {
                _amount = convertSnBnbToBnb(amountInSnBnb);
            }
            _isClaimable = (botUndelegateRequest.endTime != 0);
        }
    }

    function getSlisBnbWithdrawLimit()
        external
        view
        override
        returns (uint256 _slisBnbWithdrawLimit)
    {
        uint256 amountToUndelegate = getAmountToUndelegate();

        _slisBnbWithdrawLimit =
            convertBnbToSnBnb(totalDelegated - amountToUndelegate - unbondingBnb) - totalSnBnbToBurn;
    }

    /**
     * @return the total amount of BNB staked and reward
     */
    function getDelegated(address _validator) public view override returns (uint256) {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator);
        return IStakeCredit(creditContract).getPooledBNB(address(this));
    }

    /**
     * @dev Bot use this method to get the amount of BNB to call undelegateFrom
     * @return _amountToUndelegate Bnb amount to be undelegated by bot
     */
    function getAmountToUndelegate() public view override returns (uint256 _amountToUndelegate) {
        uint256 nextIndex = requestIndexMap[nextConfirmedRequestUUID];
        uint256 totalAmountToWithdraw = 0;
        for (uint256 i = nextIndex; i < withdrawalQueue.length; ++i) {
            UserRequest storage req = withdrawalQueue[i];
            uint256 amount = req.amount;
            totalAmountToWithdraw += amount;
        }

        _amountToUndelegate = totalAmountToWithdraw - unbondingBnb;

        return _amountToUndelegate >= undelegatedQuota ? _amountToUndelegate - undelegatedQuota : 0;
    }

    /**
     * @dev Query the claimable amount of BNB of a validator
     * @return _amount - the amount of BNB claimable
     */
    function getClaimableAmount(address _validator)
        public
        view
        override
        returns (uint256 _amount)
    {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_validator);
        uint256 count = IStakeCredit(creditContract).claimableUnbondRequest(address(this));
        uint256 index = 0;

        while(count != 0) {
            IStakeCredit.UnbondRequest memory req = IStakeCredit(creditContract).unbondRequest(address(this), index);
            _amount += req.bnbAmount;
            --count;
            ++index;
        }
    }

    function convertSharesToBnb(address _operator, uint256 _shares)
        public
        view
        override
        returns (uint256)
    {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_operator);
        return IStakeCredit(creditContract).getPooledBNBByShares(_shares);
    }

    function convertBnbToShares(address _operator, uint256 _bnbAmount)
        public
        view
        override
        returns (uint256)
    {
        address creditContract = IStakeHub(STAKE_HUB).getValidatorCreditContract(_operator);
        return IStakeCredit(creditContract).getSharesByPooledBNB(_bnbAmount);
    }

    /**
     * @dev Calculates amount of SlisBnb for `_amount` Bnb
     */
    function convertBnbToSnBnb(uint256 _amount)
        public
        view
        override
        returns (uint256)
    {
        uint256 totalShares = ISLisBNB(slisBnb).totalSupply();
        totalShares = totalShares == 0 ? 1 : totalShares;

        uint256 totalPooledBnb = getTotalPooledBnb();
        totalPooledBnb = totalPooledBnb == 0 ? 1 : totalPooledBnb;

        uint256 amountInSlisBnb = (_amount * totalShares) / totalPooledBnb;

        return amountInSlisBnb;
    }

    /**
     * @dev Calculates amount of Bnb for `_amountInSlisBnb` SlisBnb
     */
    function convertSnBnbToBnb(uint256 _amountInSlisBnb)
        public
        view
        override
        returns (uint256)
    {
        uint256 totalShares = ISLisBNB(slisBnb).totalSupply();
        totalShares = totalShares == 0 ? 1 : totalShares;

        uint256 totalPooledBnb = getTotalPooledBnb();
        totalPooledBnb = totalPooledBnb == 0 ? 1 : totalPooledBnb;

        uint256 amountInBnb = (_amountInSlisBnb * totalPooledBnb) / totalShares;

        return amountInBnb;
    }

    function getRedelegateFee(uint256 _amount)
        public
        view
        override
        returns (uint256)
    {
        IStakeHub stakeHub = IStakeHub(STAKE_HUB);
        return _amount * stakeHub.redelegateFeeRate() / stakeHub.REDELEGATE_FEE_RATE_BASE();
    }

    /**
     * @dev Flips the pause state
     */
    function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused() ? _unpause() : _pause();
    }

    /**
     * @dev Flips the vote power flag
     */
    function toggleVote() external onlyRole(DEFAULT_ADMIN_ROLE) {
        delegateVotePower = !delegateVotePower;
    }

    receive() external payable {
        if ((!creditStates[msg.sender]) && msg.sender != redirectAddress) {
            AddressUpgradeable.sendValue(payable(redirectAddress), msg.value);
        }
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Accessible only by Manager");
        _;
    }

    modifier onlyRedirectAddress() {
        require(msg.sender == redirectAddress, "Accessible only by RedirectAddress");
        _;
    }

    /**
     * @dev Allows bot to compound rewards
     */
    function compoundRewards()
    external
    override
    whenNotPaused
    onlyRole(BOT)
    {
        require(totalDelegated > 0, "No funds delegated");

        uint256 totalBNBInValidators = getTotalBnbInValidators();
        require(totalBNBInValidators >= totalDelegated && totalBNBInValidators - totalDelegated > totalFee, "No new fee to compound");
        uint256 totalProfit = totalBNBInValidators - totalDelegated - totalFee;
        uint256 fee = 0;
        if (synFee > 0) {
            fee = totalProfit * synFee / TEN_DECIMALS;
            totalFee += fee;
        }
        uint256 totalUserProfit = totalProfit - fee;

        totalDelegated += totalUserProfit;

        emit RewardsCompounded(fee);
    }

    /**
     * @dev Allows bot to claim fee
     */
    function claimFee() external override whenNotPaused onlyRole(BOT) {
        require(totalFee > 0, "No fee to claim");
        require(revenuePool != address(0x0), "revenue pool not set");

        uint256 slisBNBAmount = convertBnbToSnBnb(totalFee);
        require(slisBNBAmount > 0, "Invalid slisBnb Amount");
        totalDelegated += totalFee;
        totalFee = 0;

        ISLisBNB(slisBnb).mint(revenuePool, slisBNBAmount);
    }

    /**
     * @dev Returns the total amount of BNB in all validators
     */
    function getTotalBnbInValidators() public view override returns (uint256) {
        uint256 totalBnb = 0;
        for (uint256 i = 0; i < creditContracts.length; i++) {
            IStakeCredit credit = IStakeCredit(creditContracts[i]);
            if (creditStates[address(credit)]) {
                totalBnb += credit.getPooledBNB(address(this)) + credit.lockedBNBs(address(this), 0);
            }
        }
        return totalBnb;
    }
}
