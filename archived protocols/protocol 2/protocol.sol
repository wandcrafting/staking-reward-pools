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