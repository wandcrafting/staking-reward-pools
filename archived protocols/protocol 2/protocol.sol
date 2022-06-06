contract CakeLP is ERC20 {

    constructor() ERC20("Pancake LPs", "Cake-LP") {
        _mint(msg.sender, 100 * (10 ** decimals()));
    }
}

contract ETB is ERC20 {

    constructor() ERC20("Eat The Blocks Token", "ETB") {
        _mint(msg.sender, 1000000 * (10 ** decimals()));
    }
}

contract Wallet is Ownable {

    using SafeMath for uint256;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);


    IERC20 internal cakeLP;

    // CakeLP token balances
    mapping (address => uint256) public balances;

    // users that deposited CakeLP tokens into their balances 
    address[] internal usersArray;
    mapping (address => bool) internal users;


    constructor(address _cakeLPTokenAddress) {
        cakeLP = IERC20(_cakeLPTokenAddress);
    }


    function getBalance() external view returns (uint256) {
        return balances[msg.sender];
    }


    function deposit(uint256 amount) public {
        require(amount > 0, "Deposit amount should not be 0");
        require(cakeLP.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");

        balances[msg.sender] = balances[msg.sender].add(amount);

        // remember addresses that deposited tokens
        if (!users[msg.sender]) {
            users[msg.sender] = true;
            usersArray.push(msg.sender);
        }
        
        cakeLP.transferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) public {
        require(balances[msg.sender] >= amount, "Insufficient token balance");

        balances[msg.sender] = balances[msg.sender].sub(amount);
        cakeLP.transfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }
}

contract StakingPool is Wallet  {

    using SafeMath for uint256;

    event Staked(address indexed user, uint amount);
    event UnStaked(address indexed user, uint256 amount);

    address[] public stakers; // addresses that have active stakes
    mapping (address => uint) public stakes;
    uint public totalStakes;
 
    constructor(address _rewardTokenAddress, address _lpTokenAddress) Wallet(_lpTokenAddress) {}


    function depositAndStartStake(uint256 amount) public {
        deposit(amount);
        startStake(amount);
    }


    function endStakeAndWithdraw(uint amount) public {
        endStake(amount);
        withdraw(amount);
    }


    function startStake(uint amount) virtual public {
        require(amount > 0, "Stake must be a positive amount greater than 0");
        require(balances[msg.sender] >= amount, "Not enough tokens to stake");

        // move tokens from lp token balance to the staked balance
        balances[msg.sender] = balances[msg.sender].sub(amount);
        stakes[msg.sender] = stakes[msg.sender].add(amount); 
       
        totalStakes = totalStakes.add(amount);

        emit Staked(msg.sender, amount);
    }


    function endStake(uint amount) virtual public {
        require(stakes[msg.sender] >= amount, "Not enough tokens staked");

        // return lp tokens to lp token balance
        balances[msg.sender] = balances[msg.sender].add(amount);
        stakes[msg.sender] = stakes[msg.sender].sub(amount); 

        totalStakes = totalStakes.sub(amount);

        emit UnStaked(msg.sender, amount);
    }


    function getStakedBalance() public view returns (uint) {
        return stakes[msg.sender];
    }


    function reset() public virtual onlyOwner {
        // reset user balances and stakes
        for (uint i=0; i < usersArray.length; i++) {
            balances[usersArray[i]] = 0;
            stakes[usersArray[i]] = 0;
        }
        totalStakes = 0;
    }
}

contract StakingRewardPool is StakingPool  {

    using SafeMath for uint256;

    event RewardPaid(address indexed user, uint256 reward);

    struct RewardPeriod {
        uint id;
        uint reward;
        uint from;
        uint to;
        uint lastUpdated; // when the totalStakedWeight was last updated (after last stake was ended)
        uint totalStaked; // T: sum of all active stake deposits
        uint rewardPerTokenStaked; // S: SUM(reward/T) - sum of all rewards distributed divided all active stakes
        uint totalRewardsPaid; 
    }

    struct UserInfo {
        uint userRewardPerTokenStaked;
        uint pendingRewards;
        uint rewardsPaid;
    }

    struct RewardsStats {
        // user stats
        uint claimableRewards;
        uint rewardsPaid;
        // general stats
        uint rewardRate;
        uint totalRewardsPaid;
    }


    IERC20 internal rewardToken;
    RewardPeriod[] public rewardPeriods;
    uint rewardPeriodsCount = 0;


    mapping(address => UserInfo) userInfos;

    // mapping(address => uint) userRewardPerTokenStaked;
    // mapping (address => uint) pendingRewards;

    uint constant rewardPrecision = 1e9;


    constructor(address _rewardTokenAddress, address _lpTokenAddress) StakingPool(_rewardTokenAddress, _lpTokenAddress) {
        rewardToken = IERC20(_rewardTokenAddress);
    }


    function newRewardPeriod(uint reward, uint from, uint to) public onlyOwner {
        require(reward > 0, "Invalid reward period amount");
        require(to > from && to > block.timestamp, "Invalid reward period interval");
        require(rewardPeriods.length == 0 || from > rewardPeriods[rewardPeriods.length-1].to, "Invalid period start time");

        rewardPeriods.push(RewardPeriod(rewardPeriods.length+1, reward, from, to, block.timestamp, 0, 0, 0));
        rewardPeriodsCount = rewardPeriods.length;
        depositReward(reward);
    }


    function getRewardPeriodsCount() public view returns(uint) {
        return rewardPeriodsCount;
    }


    function deleteRewardPeriod(uint index) public onlyOwner {
        require(rewardPeriods.length > index, "Invalid reward phase index");
        for (uint i=index; i<rewardPeriods.length-1; i++) {
            rewardPeriods[i] = rewardPeriods[i+1];
        }
        rewardPeriods.pop();
        rewardPeriodsCount = rewardPeriods.length;
    }


    function rewardBalance() public view returns (uint) {
        return rewardToken.balanceOf(address(this));
    }


    // Deposit ETB token rewards into this contract
    function depositReward(uint amount) internal onlyOwner {
        rewardToken.transferFrom(msg.sender, address(this), amount);
    }


    function startStake(uint amount) public override {
        uint periodId = getCurrentRewardPeriodId();
        require(periodId > 0, "No active reward period found");
        update();

        super.startStake(amount);

        // update total tokens staked
        RewardPeriod storage period = rewardPeriods[periodId-1];
        period.totalStaked = period.totalStaked.add(amount);
    }

    function endStake(uint amount) public override {
        update();
        super.endStake(amount);

        // update total tokens staked
        uint periodId = getCurrentRewardPeriodId();
        RewardPeriod storage period = rewardPeriods[periodId-1];
        period.totalStaked = period.totalStaked.sub(amount);
        
        claim();
    }

    function claimableReward() view public returns (uint) {
        uint periodId = getCurrentRewardPeriodId();
        if (periodId == 0) return 0;

        RewardPeriod memory period = rewardPeriods[periodId-1];
        uint newRewardDistribution = calculateRewardDistribution(period);
        uint reward = calculateReward(newRewardDistribution);

        UserInfo memory userInfo = userInfos[msg.sender];
        uint pending = userInfo.pendingRewards;

        return pending.add(reward);
    }
 
    function claimReward() public {
        update();
        claim();
    }

    function claim() internal {
        UserInfo storage userInfo = userInfos[msg.sender];
        uint rewards = userInfo.pendingRewards;
        if (rewards != 0) {
            userInfo.pendingRewards = 0;

            uint periodId = getCurrentRewardPeriodId();
            RewardPeriod storage period = rewardPeriods[periodId-1];
            period.totalRewardsPaid = period.totalRewardsPaid.add(rewards);

            payReward(msg.sender, rewards);
        }
    }

    function getCurrentRewardPeriodId() public view returns (uint) {
        if (rewardPeriodsCount == 0) return 0;
        for (uint i=rewardPeriods.length; i>0; i--) {
            RewardPeriod memory period = rewardPeriods[i-1];
            if (period.from <= block.timestamp && period.to >= block.timestamp) {
                return period.id;
            }
        }
        return 0;
    }


    function getRewardsStats() public view returns (RewardsStats memory) {
        UserInfo memory userInfo = userInfos[msg.sender];

        RewardsStats memory stats = RewardsStats(0, 0, 0, 0);
        // user stats
        stats.claimableRewards = claimableReward();
        stats.rewardsPaid = userInfo.rewardsPaid;

        // reward period stats
        uint periodId = getCurrentRewardPeriodId();
        if (periodId > 0) {
            RewardPeriod memory period = rewardPeriods[periodId-1];
            stats.rewardRate = rewardRate(period);
            stats.totalRewardsPaid = period.totalRewardsPaid;
        }

        return stats;
    }


    function rewardRate(RewardPeriod memory period) internal pure returns (uint) {
        uint duration = period.to.sub(period.from);
        return period.reward.div(duration);
    }

    function payReward(address account, uint reward) internal {
        UserInfo storage userInfo = userInfos[msg.sender];
        userInfo.rewardsPaid = userInfo.rewardsPaid.add(reward);
        rewardToken.transfer(account, reward);

        emit RewardPaid(account, reward);
    }


    /// Reward calcualtion logic

    function update() internal {
        uint periodId = getCurrentRewardPeriodId();
        require(periodId > 0, "No active reward period found");

        RewardPeriod storage period = rewardPeriods[periodId-1];
        uint rewardDistribuedPerToken = calculateRewardDistribution(period);

        // update pending rewards reward since rewardPerTokenStaked was updated
        uint reward = calculateReward(rewardDistribuedPerToken);
        UserInfo storage userInfo = userInfos[msg.sender];
        userInfo.pendingRewards = userInfo.pendingRewards.add(reward);
        userInfo.userRewardPerTokenStaked = rewardDistribuedPerToken;

        require(rewardDistribuedPerToken >= period.rewardPerTokenStaked, "Reward distribution should be monotonic increasing");

        period.rewardPerTokenStaked = rewardDistribuedPerToken;
        period.lastUpdated = block.timestamp;
    }


    function calculateRewardDistribution(RewardPeriod memory period) view internal returns (uint) {

        // calculate total reward to be distributed since period.lastUpdated
        uint rate = rewardRate(period);
        uint deltaTime = block.timestamp.sub(period.lastUpdated);
        uint reward = deltaTime.mul(rate);

        uint newRewardPerTokenStaked = period.rewardPerTokenStaked;  // 0
        if (period.totalStaked != 0) {
            // S = S + r / T
            newRewardPerTokenStaked = period.rewardPerTokenStaked.add( 
                reward.mul(rewardPrecision).div(period.totalStaked)
            );
        }

        return newRewardPerTokenStaked;
    }


    function calculateReward(uint rewardDistribution) internal view returns (uint) {
        if (rewardDistribution == 0) return 0;

        uint staked = stakes[msg.sender];
        UserInfo memory userInfo = userInfos[msg.sender];
        uint reward = staked.mul(
            rewardDistribution.sub(userInfo.userRewardPerTokenStaked)
        ).div(rewardPrecision);

        return reward;
    }


    // HELPERS - Used in tests

    function reset() public override onlyOwner {
        for (uint i=0; i<rewardPeriods.length; i++) {
            delete rewardPeriods[i];
        }
        rewardPeriodsCount = 0;
        for (uint i=0; i<usersArray.length; i++) {
            delete userInfos[usersArray[i]];
        }
        // return leftover rewards to owner
        uint leftover = rewardBalance();
        rewardToken.transfer(msg.sender, leftover);
        super.reset();
    }

}