
//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract UTToken is ERC20, Ownable, Pausable, ReentrancyGuard {
    mapping(address => bool) public blackListedAddress;

    uint256 public rewardRate = 10;
    uint16 public txnTaxRateBasisPoints;
    address public txnTaxWallet;
    uint8 private _decimals;
    IUniswapV2Router02 public uniswapRouter;

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
    struct Stake {
        uint256 amount;
        uint256 lockPeriod;
        uint256 stakeTimestamp;
        bool isRewarded;
    }

    mapping(address => Stake[]) public userStakes;
    mapping(address => uint256) public totalStaked;

    smartContractActions public actions;
    event LogApproval(
        address indexed owner,
        address indexed spender,
        uint256 value
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

    function stake(uint256 _amount, uint256 _lockPeriodMonths)
        external
        nonReentrant
    {
        require(
            balanceOf(msg.sender) >= _amount,
            "Insufficient token balance to stake"
        );
        require(
            _lockPeriodMonths >= 1 && _lockPeriodMonths <= 12,
            "Lock period must be between 1 and 12 months"
        );

        uint256 lockPeriodInSeconds = _lockPeriodMonths * 30 days;

        // Transfer tokens from the user to the contract
        _transfer(msg.sender, address(this), _amount);

        // Add a new stake to the user's stake array
        userStakes[msg.sender].push(
            Stake({
                amount: _amount,
                lockPeriod: lockPeriodInSeconds,
                stakeTimestamp: block.timestamp,
                isRewarded: false
            })
        );

        totalStaked[msg.sender] += _amount;
    }

    // Unstake a specific amount, prioritizing the most recent stakes
    function unstake(uint256 _amount) external nonReentrant {
        require(
            totalStaked[msg.sender] >= _amount,
            "Insufficient staked balance to unstake"
        );

        uint256 remainingAmount = _amount;
        uint256 rewardAmount = 0;

        for (
            uint256 i = userStakes[msg.sender].length;
            i > 0 && remainingAmount > 0;
            i--
        ) {
            Stake storage stakeEntry = userStakes[msg.sender][i - 1];

            if (stakeEntry.amount == 0) continue; // Skip fully unstaked entries

            uint256 unstakeAmount = remainingAmount < stakeEntry.amount
                ? remainingAmount
                : stakeEntry.amount;
            remainingAmount -= unstakeAmount;
            stakeEntry.amount -= unstakeAmount;
            totalStaked[msg.sender] -= unstakeAmount;

            // Check if stake has completed its lock period and is eligible for reward
            if (
                !stakeEntry.isRewarded &&
                block.timestamp >=
                stakeEntry.stakeTimestamp + stakeEntry.lockPeriod
            ) {
                uint256 reward = (unstakeAmount * rewardRate) / 100;
                rewardAmount += reward;
                stakeEntry.isRewarded = true; // Mark as rewarded
            }
        }

        // Transfer the unstaked amount and reward, if any, back to the user
        _transfer(address(this), msg.sender, _amount + rewardAmount);
    }
   

    // Unstake all tokens, calculate rewards based on completion of lock periods
    function unstakeAll() external nonReentrant {
        uint256 totalUnstaked = 0;
        uint256 rewardAmount = 0;

        for (uint256 i = 0; i < userStakes[msg.sender].length; i++) {
            Stake storage stakeEntry = userStakes[msg.sender][i];

            if (stakeEntry.amount == 0) continue; // Skip fully unstaked entries

            totalUnstaked += stakeEntry.amount;

            // Check if lock period is completed for reward eligibility
            if (
                !stakeEntry.isRewarded &&
                block.timestamp >=
                stakeEntry.stakeTimestamp + stakeEntry.lockPeriod
            ) {
                uint256 reward = (stakeEntry.amount * rewardRate) / 100;
                rewardAmount += reward;
                stakeEntry.isRewarded = true;
            }

            stakeEntry.amount = 0; // Mark stake as fully unstaked
        }

        totalStaked[msg.sender] = 0;

        // Transfer total unstaked amount and reward, if any, back to the user
        _transfer(address(this), msg.sender, totalUnstaked + rewardAmount);
    }

    function claimReward() external nonReentrant {
        uint256 _totalReward = 0;

        for (uint256 i = 0; i < userStakes[msg.sender].length; i++) {
            Stake storage stakeEntry = userStakes[msg.sender][i];

            // Check if the stake is eligible for rewards
            if (
                !stakeEntry.isRewarded &&
                block.timestamp >=
                stakeEntry.stakeTimestamp + stakeEntry.lockPeriod
            ) {
                uint256 reward = (stakeEntry.amount * rewardRate) / 100;
                _totalReward += reward;
                stakeEntry.isRewarded = true; // Mark as rewarded
            }
        }

        require(_totalReward > 0, "No rewards available to claim");

        // Transfer the total reward to the user
        _transfer(address(this), msg.sender, _totalReward);
    }

    function totalReward(address _user) external view returns (uint256) {
        uint256 totalRewardAmount = 0;

        for (uint256 i = 0; i < userStakes[_user].length; i++) {
            Stake memory stakeEntry = userStakes[_user][i];

            // Check if the stake is eligible for rewards
            if (
                !stakeEntry.isRewarded &&
                block.timestamp >=
                stakeEntry.stakeTimestamp + stakeEntry.lockPeriod
            ) {
                uint256 reward = (stakeEntry.amount * rewardRate) / 100;
                totalRewardAmount += reward;
            }
        }

        return totalRewardAmount;
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

    function transferTokensToUser(
        address user,
        uint256 amount,
        uint256 _duration
    ) public onlyOwner whenNotPaused {
        require(
            balanceOf(address(this)) >= amount,
            "Contract does not have enough tokens"
        );
        require(!blackListedAddress[user], "User is blacklisted");
        require(amount > 0, "Transfer amount must be greater than zero");

        // Monthly burn calculation = amount divided by the duration (in months).
        // Assume _duration is in days and calculate how many months (_duration).
        uint256 transferAmount = amount;
        uint256 monthlyBurnLimit = transferAmount / (_duration);

        // Calculate tax if transactions tax is enabled
        if (actions.canTxTax) {
            // Calculate the tax in basis points (1% = 1000 basis points)
            uint256 taxAmount = (transferAmount * txnTaxRateBasisPoints) /
                (100 * 1000);
            // Dividing by 100,000 because 1% = 1000 basis points
            // 100*1000 => percent * basisPoints
            transferAmount = transferAmount - taxAmount;
            // Transfer tax to tax wallet
            _transfer(address(this), txnTaxWallet, taxAmount);
        }
        _transfer(address(this), user, transferAmount);
        _approve(user, owner(), monthlyBurnLimit);
    }

    function blackListUser(address _user)
        public
        canBlacklistModifier
        onlyOwner
        whenNotPaused
    {
        require(
            !blackListedAddress[_user],
            "User Address is already blacklisted"
        );
        blackListedAddress[_user] = true;
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

    function buyBackTokens(uint256 amountOutMin)
        external
        payable
        canBuyBackModifier
        whenNotPaused
    {
        address[] memory path = new address[](2);
        path[0] = uniswapRouter.WETH(); //uniswapRouter.WETH(); //Weth contract address
        path[1] = address(this); // erc20 address of this contract

        uniswapRouter.swapExactETHForTokens{value: msg.value}(
            amountOutMin, //amount of tokens wants to buy back from market
            path, //
            address(this), // Tokens bought will be sent to the contract
            block.timestamp + 300 // Deadline
        );
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
