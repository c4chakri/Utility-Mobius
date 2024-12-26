//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract UTtoken is ERC20, Ownable, Pausable, ReentrancyGuard {
    mapping(address => bool) public blackListedAddress;
    mapping(address => uint256) public restrictedBalances;
    mapping(address => uint256) public restrictedUntil;

    mapping(address => mapping(uint256 => StakeInfo)) public userStakes; // User -> StakeId -> StakeInfo
    mapping(address => uint256) public nextStakeId; // Tracks the next stake ID for each user

    uint16 public txnTaxRateBasisPoints;
    address public txnTaxWallet;
    uint8 private _decimals;
    // IUniswapV2Router02 public uniswapRouter;

    struct smartContractActions {
        bool canMint;
        bool canBurn;
        bool canPause;
        bool canBlacklist;
        bool canChangeOwner;
        bool canTxTax;
        bool canBuyBack;
        bool canStake;
    }

    struct StakeInfo {
        uint256 amount; // Amount staked
        uint256 lockUntil; // Lock period end timestamp
        uint256 startTime; // Staking start timestamp
        bool isActive; // Status of the stake
        bool isRewarded;
    }

    smartContractActions public actions;
    event LogApproval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    event TokensStaked(
        address indexed user,
        uint256 stakeId,
        uint256 amount,
        uint256 startTime,
        uint256 lockUntil
    );

    event TokensUnstaked(
        address indexed user,
        uint256 stakeId,
        uint256 amount,
        uint256 unstakeTime
    );

    event LogTotalSupply(uint256 totalSupply, uint256 decimals);

    modifier canMintModifier() {
        require(
            actions.canMint,
            "Minting Functionality is not enabled in this smart contract!"
        );
        _;
    }

    modifier canBurnModifier() {
        require(
            actions.canBurn,
            "Burning Functionality is not enabled in this smart contract!"
        );
        _;
    }

    modifier canPauseModifier() {
        require(
            actions.canPause,
            "Pause/Unpause Functionality is not enabled in this smart contract!"
        );
        _;
    }

    modifier canBlacklistModifier() {
        require(
            actions.canBlacklist,
            "Blacklist Address Functionality is not enabled in this smart contract!"
        );
        _;
    }

    modifier canChangeOwnerModifier() {
        require(
            actions.canChangeOwner,
            "Change Owner Functionality is not enabled in this smart contract!"
        );
        _;
    }

    modifier canBuyBackModifier() {
        require(
            actions.canBuyBack,
            "Buyback Token Functionality is not enabled in this smart contract!"
        );
        _;
    }

    modifier canStakeModifier() {
        require(
            actions.canStake,
            "Staking reward Functionality is not enabled in this smart contract!"
        );
        _;
    }

    modifier canTxTaxModifier() {
        require(
            actions.canTxTax,
            "Txn Tax Functionality is not enabled in this smart contract!"
        );
        _;
    }
    modifier isBlackListed() {
        require(!blackListedAddress[msg.sender], "User is blacklisted!");
        _;
    }

    constructor(
        uint256 preMintValue,
        string memory _tokenTicker,
        string memory _tokenName,
        address _initialAddress,
        smartContractActions memory _actions,
        uint16 _txnTaxRateBasisPoints,
        address _txnTaxWallet,
        uint8 decimals_
    ) ERC20(_tokenName, _tokenTicker) Ownable(_initialAddress) {
        _decimals = decimals_;
        initializeToken(preMintValue);
        initializeTaxSettings(_txnTaxRateBasisPoints, _txnTaxWallet);
        initializeFeatures(_actions);
    }

    function initializeToken(uint256 preMintValue) internal {
        uint256 convertedValue = convertDecimals(preMintValue);
        _mint(address(this), convertedValue);
        approve(owner(), convertedValue);
        emit LogTotalSupply(totalSupply(), decimals());
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function setBasisPoints(uint8 percentage) public pure returns (uint256) {
        require(percentage > 0, "Percentage must be greater than 0");
        // Convert the percentage to basis points (1% = 1000 basis points)
        uint256 basisPoints = uint256(percentage) * 1000;
        return basisPoints;
    }

    function initializeTaxSettings(uint16 _txnTaxRate, address _txnTaxWallet)
        internal
    {
        require(_txnTaxWallet != address(0), "TxnTax Wallet can't be empty");
        require(_txnTaxRate > 0, "Transaction rate must be grater than 0");
        txnTaxWallet = _txnTaxWallet;
        txnTaxRateBasisPoints = _txnTaxRate;
    }

    function isEligible(address _staker)
        public
        view
        returns (StakeInfo[] memory eligibleStakes)
    {
        uint256 stakeCount = nextStakeId[_staker];
        uint256 index = 0;

        // Create a temporary array with a size equal to the total stake count
        StakeInfo[] memory tempStakes = new StakeInfo[](stakeCount);

        // Single pass: Filter eligible stakes
        for (uint256 i = 0; i < stakeCount; ) {
            StakeInfo memory stake = userStakes[_staker][i];
            if ( block.timestamp >= stake.lockUntil) {
                tempStakes[index] = stake;
                index++;
            }
            unchecked {
                i++;
            } // Use unchecked to save gas
        }

        // Create the final array with the exact size of eligible stakes
        eligibleStakes = new StakeInfo[](index);
        for (uint256 i = 0; i < index; ) {
            eligibleStakes[i] = tempStakes[i];
            unchecked {
                i++;
            } // Use unchecked to save gas
        }
    }

    function initializeFeatures(smartContractActions memory _actions) private {
        actions.canStake = _actions.canStake;
        actions.canBurn = _actions.canBurn;
        actions.canMint = _actions.canMint;
        actions.canPause = _actions.canPause;
        actions.canBlacklist = _actions.canBlacklist;
        actions.canChangeOwner = _actions.canChangeOwner;
        actions.canTxTax = _actions.canTxTax;
        actions.canBuyBack = _actions.canBuyBack;
    }

    function pauseTokenTransfers() public canPauseModifier onlyOwner {
        require(!paused(), "Contract is already paused.");
        _pause();
    }

    function unPauseTokenTransfers() public canPauseModifier onlyOwner {
        require(paused(), "Contract is not paused.");
        _unpause();
    }

    function transferOwnership(address newOwner)
        public
        override
        canChangeOwnerModifier
        onlyOwner
    {
        _transferOwnership(newOwner);
    }

    function convertDecimals(uint256 _amount) private view returns (uint256) {
        return _amount * 10**decimals();
    }

    function transferToOwner(uint256 transferAmount) public onlyOwner {
        _transfer(address(this), msg.sender, transferAmount);
    }

    function transferTokensToUser(
        address user,
        uint256 amount,
        uint256 lockDurationInMonths
    ) public onlyOwner whenNotPaused {
        require(
            balanceOf(address(this)) >= amount,
            "Contract does not have enough tokens"
        );
        require(!blackListedAddress[user], "User is blacklisted");
        require(amount > 0, "Transfer amount must be greater than zero");

        _transfer(address(this), user, amount);

        // Restrict tokens until the specified lock duration
        restrictedBalances[user] += amount;
        restrictedUntil[user] =
            block.timestamp +
            (lockDurationInMonths * 30 days);
    }

    function transferUnrestrictedTokens(address user, uint256 amount)
        public
        onlyOwner
        whenNotPaused
    {
        require(
            balanceOf(address(this)) >= amount,
            "Contract does not have enough tokens"
        );
        require(!blackListedAddress[user], "User is blacklisted");
        require(amount > 0, "Transfer amount must be greater than zero");

        _transfer(address(this), user, amount);
    }

    function burnExpiredTokens(address user) internal {
        if (
            restrictedBalances[user] > 0 &&
            block.timestamp > restrictedUntil[user]
        ) {
            uint256 amountToBurn = restrictedBalances[user];
            restrictedBalances[user] = 0;
            _burn(user, amountToBurn);
        }
    }

    function transfer(address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        // Burn expired restricted tokens before allowing transfer
        burnExpiredTokens(msg.sender);

        // Calculate unrestricted balance
        uint256 unrestrictedBalance = balanceOf(msg.sender) -
            restrictedBalances[msg.sender];

        require(
            amount <= unrestrictedBalance,
            "Transfer exceeds unrestricted token balance"
        );

        if (actions.canTxTax) {
            uint256 taxAmount = (amount * txnTaxRateBasisPoints) / (100 * 1000);
            uint256 netAmount = amount - taxAmount;

            // Transfer tax to tax wallet
            super.transfer(txnTaxWallet, taxAmount);
            // Transfer remaining tokens to the recipient
            return super.transfer(recipient, netAmount);
        } else {
            return super.transfer(recipient, amount);
        }
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        // Burn expired restricted tokens before allowing transfer
        burnExpiredTokens(sender);

        // Calculate unrestricted balance
        uint256 unrestrictedBalance = balanceOf(sender) -
            restrictedBalances[sender];

        require(
            amount <= unrestrictedBalance,
            "Transfer exceeds unrestricted token balance"
        );

        if (actions.canTxTax) {
            uint256 taxAmount = (amount * txnTaxRateBasisPoints) / (100 * 1000);
            uint256 netAmount = amount - taxAmount;

            // Transfer tax to tax wallet
            super.transferFrom(sender, txnTaxWallet, taxAmount);
            // Transfer remaining tokens to the recipient
            return super.transferFrom(sender, recipient, netAmount);
        } else {
            return super.transferFrom(sender, recipient, amount);
        }
    }

    function whiteListUser(address _user)
        public
        canBlacklistModifier
        onlyOwner
        whenNotPaused
    {
        require(blackListedAddress[_user], "User Address is not blacklisted");
        blackListedAddress[_user] = false;
    }

    function setTxnTaxRateBasisPoints(uint8 _rateValue)
        public
        canTxTaxModifier
        onlyOwner
        whenNotPaused
    {
        require(_rateValue > 0, "Rate must be grater than 0");
        txnTaxRateBasisPoints = _rateValue;
    }

    function setTxnTaxWallet(address _txnTaxWallet)
        public
        canTxTaxModifier
        onlyOwner
        whenNotPaused
    {
        require(_txnTaxWallet != address(0), "Txn tax wallet can't be empty");
        txnTaxWallet = _txnTaxWallet;
    }

    function mintSupply(uint256 _amount)
        public
        canMintModifier
        onlyOwner
        whenNotPaused
    {
        require(_amount > 0, "Mint more than Zero");
        _mint(address(this), convertDecimals(_amount));
    }

    function blackListUsers(address[] calldata _users)
        public
        canBlacklistModifier
        onlyOwner
        whenNotPaused
    {
        for (uint256 i = 0; i < _users.length; i++) {
            require(
                !blackListedAddress[_users[i]],
                "User Address is already blacklisted"
            );
            blackListedAddress[_users[i]] = true;
        }
    }

    function whiteListUsers(address[] calldata _users)
        public
        canBlacklistModifier
        onlyOwner
        whenNotPaused
    {
        for (uint256 i = 0; i < _users.length; i++) {
            require(
                blackListedAddress[_users[i]],
                "User Address is not blacklisted"
            );
            blackListedAddress[_users[i]] = false;
        }
    }

    function burnSupply(uint256 _amount)
        public
        canBurnModifier
        onlyOwner
        whenNotPaused
    {
        require(_amount > 0, "Burn more than Zero");
        _burn(address(this), convertDecimals(_amount));
    }

    function stakeToken(uint256 _amount, uint256 lockPeriod)
        public
        canStakeModifier
        nonReentrant
        whenNotPaused
        isBlackListed
    {
        // Burn expired restricted tokens before staking
        burnExpiredTokens(msg.sender);

        // Calculate unrestricted balance
        // uint256 unrestrictedBalance = balanceOf(msg.sender) -
        //     restrictedBalances[msg.sender];
        // require(
        //     _amount <= unrestrictedBalance,
        //     "Insufficient unrestricted token balance to stake"
        // );
        require(
            lockPeriod >= 1 && lockPeriod <= 12,
            "Lock period must be between 1 and 12 months"
        );

        // Generate new stake ID for the user
        uint256 stakeId = nextStakeId[msg.sender];
        nextStakeId[msg.sender]++; // Increment stake ID for next stake

        // Create new stake record
        uint256 lockUntil = block.timestamp + lockPeriod * 30 days;
        userStakes[msg.sender][stakeId] = StakeInfo({
            amount: _amount,
            lockUntil: lockUntil,
            startTime: block.timestamp,
            isActive: true,
            isRewarded: false
        });

        // Transfer tokens to the contract
        _transfer(msg.sender, address(this), _amount);

        // Emit event for staking
        emit TokensStaked(
            msg.sender,
            stakeId,
            _amount,
            block.timestamp,
            lockUntil
        );
    }

    function stakeT(uint256 _amount, uint256 _lockDuration)
        external
        canStakeModifier
        nonReentrant
        whenNotPaused
        isBlackListed
    {
        require(_amount > 0, "Amount must be greater than zero");
        require(
            _lockDuration >= 1 && _lockDuration <= 12,
            "Lock period must be between 1 and 12 months"
        );
        uint256 stakeId = nextStakeId[msg.sender];
        nextStakeId[msg.sender]++;
        userStakes[msg.sender][stakeId] = StakeInfo({
            amount: _amount,
            startTime: block.timestamp,
            lockUntil: block.timestamp + (_lockDuration ),
            isActive: true,
            isRewarded: false
        });

        _transfer(msg.sender, address(this), _amount);
        emit TokensStaked(
            msg.sender,
            stakeId,
            _amount,
            block.timestamp,
            block.timestamp + (_lockDuration * 30 days)
        );
    }

    function unstakeToken(uint256 stakeId)
        public
        canStakeModifier
        nonReentrant
        whenNotPaused
        isBlackListed
    {
        StakeInfo storage stake = userStakes[msg.sender][stakeId];
        require(stake.isActive, "Stake is already unstaked or does not exist");
        require(block.timestamp >= stake.lockUntil, "Tokens are still locked");
        require(stake.amount > 0, "Stake amount must be greater than zero");

        uint256 amountToUnstake = stake.amount;

        // Mark stake as inactive
        stake.isActive = false;
        stake.amount = 0;

        // Transfer tokens back to the user
        _transfer(address(this), msg.sender, amountToUnstake);

        // Emit event for unstaking
        emit TokensUnstaked(
            msg.sender,
            stakeId,
            amountToUnstake,
            block.timestamp
        );
    }

    function unstakeT(uint256 _amount)
        external
        canStakeModifier
        nonReentrant
        whenNotPaused
        isBlackListed
    {
        require(_amount > 0, "Amount must be greater than zero");
        uint256 remainingAmountToUnstake = _amount;
        uint256 totalUnstakedAmount = 0;
        uint256 stakeCount = nextStakeId[msg.sender];

        for (uint256 i = stakeCount; i > 0; i--) {
            StakeInfo storage userStake = userStakes[msg.sender][i - 1];

            // Only consider active and unrewarded stakes
            if ( !userStake.isRewarded) {
                if (userStake.amount <= remainingAmountToUnstake) {
                    remainingAmountToUnstake -= userStake.amount;
                    totalUnstakedAmount += userStake.amount;
                    userStake.amount = 0;
                    userStake.isRewarded = true;

                    // Deactivate stake if the lock period has expired
                    if (block.timestamp >= userStake.lockUntil) {
                        userStake.isActive = false;
                    }
                } else {
                    totalUnstakedAmount += remainingAmountToUnstake;
                    userStake.amount -= remainingAmountToUnstake;
                    remainingAmountToUnstake = 0;
                }

                // Exit loop if the required amount is fully unstaked
                if (remainingAmountToUnstake == 0) {
                    break;
                }
            }
        }

        require(
            totalUnstakedAmount == _amount,
            "Not enough staked balance to unstake the requested amount"
        );

        // Transfer tokens back to the user
        _transfer(address(this), msg.sender, totalUnstakedAmount);

        // emit TokensUnstaked(msg.sender, _amount, block.timestamp);
    }

    function burnFrom(address _user, uint256 _amount) public onlyOwner {
        uint256 currentAllowance = allowance(_user, owner()); //100
        require(currentAllowance >= _amount, "Burn amount exceeds allowance");
        uint256 userBalance = balanceOf(_user);
        if (userBalance == 0) {
            _approve(_user, owner(), 0);
        }
        _burn(_user, _amount);
    }
}
