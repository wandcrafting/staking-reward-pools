pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/*
    The totalRewardPerShare is an accumulating pool of "balance". Every unit of this balance represents the reward of 1 staked wei.
    Every time there is a deposit, withdraw, or claim event - the balance is updated by calling updateRewards().

    updateRewards() will update the rewards based on the time passed from the last update and the total staked wei.
    Essentially, totalRewardPerShare = totalRewardPerShare + (seconds since last update) * (rewards per second) / (total tokens staked)

    The amount of reward claimed by each user so far is tracked. Hence, we can calculate a user's reward by:
    userRewards = totalRewardPerShare * (user's currently staked tokens) - (user's rewards already claimed) 
*/

contract Staker is Ownable {
    using SafeMath for uint256;

    struct UserInfo {
        uint256 deposited;
        uint256 rewardsPending;
        uint256 initialDepositTimestamp; //for timelocking
    }

    mapping (address => UserInfo) users;
    
    IERC20 public LPToken;
    IERC20 public rewardToken;

    uint256 public totalStaked;

    uint256 public rewardEndTime;
    uint256 public rewardRate; 
    uint246 public minDepositDuration;

    uint256 public lastRewardTimestamp;
    uint256 public totalRewardPerShare;

    event AddRewards(uint256 amount, uint256 lengthInDays);
    event ClaimReward(address indexed user, uint256 amount);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    
    constructor(address _LPToken, address _rewardToken) {
        LPToken = IERC20(_LPToken);
        rewardToken = IERC20(_rewardToken);
    }

    function addRewards(uint256 _rewardsAmount, uint256 _lengthInDays, uint256 _minDepositDurationInDays)
    external onlyOwner {
        require(block.timestamp > rewardEndTime, "Staker: can't add rewards before period finished");
        updateRewards();
        rewardEndTime = block.timestamp.add(_lengthInDays.mul(24*60*60));
        rewardRate = _rewardsAmount.mul(1e7).div(_lengthInDays).div(24*60*60);
        minDepositduration = _minDepositDurationInDays.mul(24*60*60);
        require(rewardToken.transferFrom(msg.sender, address(this), _rewardsAmount), "Staker: transfer failed");
        emit AddRewards(_rewardsAmount, _lengthInDays);
    }

    function updateRewards()
    public {
        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }
        if ((totalStaked == 0) || lastRewardTimestamp > rewardEndTime) {
            lastRewardTimestamp = block.timestamp;
            return;
        }

        uint256 endingTime;
        if (block.timestamp > rewardEndTime) {
            endingTime = rewardEndTime;
        } else {
            endingTime = block.timestamp;
        }
        uint256 secondsSinceLastRewardUpdate = endingTime.sub(lastRewardTimestamp);
        uint256 totalNewReward = secondsSinceLastRewardUpdate.mul(rewardRate); 
 
        totalRewardPerShare = totalRewardPerShare.add(totalNewReward.mul(1e12).div(totalStaked));
        lastRewardTimestamp = block.timestamp;
        if (block.timestamp > rewardEndTime) {
            rewardRate = 0;
        }
    }

    function deposit(uint256 _amount)
    external {
        UserInfo storage user = users[msg.sender];
        updateRewards();
        if (user.deposited > 0) {
            uint256 pending = user.deposited.mul(totalRewardPerShare).div(1e12).div(1e7).sub(user.rewardsPending);
            require(rewardToken.transfer(msg.sender, pending), "Staker: transfer failed");
            emit ClaimReward(msg.sender, pending);
        }
        user.deposited = user.deposited.add(_amount);
        totalStaked = totalStaked.add(_amount);
        user.rewardsPending = user.deposited.mul(totalRewardPerShare).div(1e12).div(1e7);
        require(LPToken.transferFrom(msg.sender, address(this), _amount), "Staker: transferFrom failed");
        emit Deposit(msg.sender, _amount);
        user.initialDepositTimestamp = block.timestamp; //for timelocking
    }
    
    function withdraw(uint256 _amount)
    external {
        UserInfo storage user = users[msg.sender];
        require(block.timestamp.sub(user.initialDepositTimestamp) > minDepositDuration, "Staker: can't withdraw before minDepositDuration days have passed");
        require(user.deposited >= _amount, "Staker: balance not enough");
        updateRewards();
        uint256 pending = user.deposited.mul(totalRewardPerShare).div(1e12).div(1e7).sub(user.rewardsPending);
        require(rewardToken.transfer(msg.sender, pending), "Staker: reward transfer failed");
        emit ClaimReward(msg.sender, pending);
        user.deposited = user.deposited.sub(_amount);
        totalStaked = totalStaked.sub(_amount);
        user.rewardsPending = user.deposited.mul(totalRewardPerShare).div(1e12).div(1e7);
        require(LPToken.transfer(msg.sender, _amount), "Staker: deposit withdrawal failed");
        emit Withdraw(msg.sender, _amount);
    }

    function claim()
    external {
        UserInfo storage user = users[msg.sender];
        if (user.deposited == 0)
            return;
        updateRewards();
        uint256 pending = user.deposited.mul(totalRewardPerShare).div(1e12).div(1e7).sub(user.rewardsPending);
        require(rewardToken.transfer(msg.sender, pending), "Staker: transfer failed");
        emit ClaimReward(msg.sender, pending);
        user.rewardsPending = user.deposited.mul(totalRewardPerShare).div(1e12).div(1e7);
    }

    function pendingRewards(address _user)
    public view returns (uint256) {
        UserInfo storage user = users[_user];
        uint256 accumulated = totalRewardPerShare;
        if (block.timestamp > lastRewardTimestamp && lastRewardTimestamp <= rewardEndTime && totalStaked != 0) {
            uint256 endingTime;
            if (block.timestamp > rewardEndTime) {
                endingTime = rewardEndTime;
            } else {
                endingTime = block.timestamp;
            }
            uint256 secondsSinceLastRewardUpdate = endingTime.sub(lastRewardTimestamp);
            uint256 totalNewReward = secondsSinceLastRewardUpdate.mul(rewardRate);
            accumulated = accumulated.add(totalNewReward.mul(1e12).div(totalStaked));
        }
        return user.deposited.mul(accumulated).div(1e12).div(1e7).sub(user.rewardsPending);
    }

    function userDetailGetter()
    external view returns (uint256 _rewardRate, uint256 _secondsLeft, uint256 _deposited, uint256 _pending) {
        if (block.timestamp <= rewardEndTime) {
            _secondsLeft = rewardEndTime.sub(block.timestamp); 
            _rewardRate = rewardRate.div(1e7);
        }
        _deposited = users[msg.sender].deposited;
        _pending = pendingRewards(msg.sender);
    }
}