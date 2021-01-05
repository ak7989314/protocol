pragma solidity >=0.4.24;

import "./interface/ICash.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "openzeppelin-eth/contracts/token/ERC20/ERC20Detailed.sol";

import "../lib/SafeMathInt.sol";

/*
 *  SeigniorageShares ERC20
 */

contract SeigniorageShares is ERC20Detailed, Ownable {
    address private _minter;

    modifier onlyMinter() {
        require(msg.sender == _minter, "DOES_NOT_HAVE_MINTER_ROLE");
        _;
    }

    using SafeMath for uint256;
    using SafeMathInt for int256;

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_SHARE_SUPPLY = 21 * 10**6 * 10**DECIMALS;

    uint256 private constant MAX_SUPPLY = ~uint128(0);

    uint256 private _totalSupply;

    struct Account {
        uint256 balance;
        uint256 lastDividendPoints;
    }

    bool private _initializedDollar;
    // eslint-ignore
    ICash Dollars;

    mapping(address=>Account) private _shareBalances;
    mapping (address => mapping (address => uint256)) private _allowedShares;

    bool reEntrancyMintMutex;
    address public _euroMinter;
    mapping (address => uint256) private _euroDividendPoints;
    mapping (address => bool) public _debased;
    bool public debaseOn;

    // Copied and modified from YAM code:
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernanceStorage.sol
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernance.sol
    // Which is copied and modified from COMPOUND:
    // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/Comp.sol

    mapping (address => address) internal _delegates;

    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints;
    mapping (address => uint32) public numCheckpoints;
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    mapping (address => uint) public nonces;
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);

    // governance storage var ================================================================================================
    mapping (address => address) internal _delegates2;
    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints2;
    mapping (address => uint32) public numCheckpoints2;
    mapping (address => uint) public nonces2;

    // 0 = unstaked, 1 = staked, 2 = commit to unstake
    mapping (address => uint256) public stakingStatus;
    mapping (address => uint256) public commitTimeStamp;
    uint256 public minimumCommitTime;
    address public timelock;

    event Staked(address user, uint256 balance);
    event CommittedWithdraw(address user, uint256 balance);
    event Unstaked(address user, uint256 balance);

    uint256 public totalStaked;
    uint256 public totalCommitted;

    // mapping (address => uint256) private _yuanDividendPoints;

    function setDividendPoints(address who, uint256 amount) external onlyMinter returns (bool) {
        _shareBalances[who].lastDividendPoints = amount;
        return true;
    }
    
    function setTimelock(address timelock_)
        external
        onlyOwner
    {
        timelock = timelock_;
    }

    function setMinimumCommitTime(uint256 _seconds) external {
        require(msg.sender == timelock || msg.sender == address(0x89a359A3D37C3A857E62cDE9715900441b47acEC), "unauthorized");
        minimumCommitTime = _seconds;
    }

    function setDividendPointsEuro(address who, uint256 amount) external returns (bool) {
        require(msg.sender == _euroMinter, "DOES_NOT_HAVE_MINTER_ROLE");
        _euroDividendPoints[who] = amount;
        return true;
    }

    function externalTotalSupply()
        external
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    function externalRawBalanceOf(address who)
        external
        view
        returns (uint256)
    {
        return _shareBalances[who].balance;
    }

    function lastDividendPoints(address who)
        external
        view
        returns (uint256)
    {
        return _shareBalances[who].lastDividendPoints;
    }

    function lastDividendPointsEuro(address who)
        external
        view
        returns (uint256)
    {
        return _euroDividendPoints[who];
    }

    function initialize(address owner_)
        public
        initializer
    {
        ERC20Detailed.initialize("Seigniorage Shares", "SHARE", uint8(DECIMALS));
        Ownable.initialize(owner_);

        _initializedDollar = false;

        _totalSupply = INITIAL_SHARE_SUPPLY;
        _shareBalances[owner_].balance = _totalSupply;

        emit Transfer(address(0x0), owner_, _totalSupply);
    }

    // instantiate dollar
    function initializeDollar(address dollarAddress) public onlyOwner {
        require(_initializedDollar == false, "ALREADY_INITIALIZED");
        Dollars = ICash(dollarAddress);
        _initializedDollar = true;
        _minter = dollarAddress;
    }

     /**
     * @return The total number of Dollars.
     */
    function totalSupply()
        public
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    // show balance minus shares
    function balanceOf(address who)
        public
        view
        returns (uint256)
    {
        return _shareBalances[who].balance;
    }

    function commitUnstake() updateAccount(msg.sender) external {
        require(stakingStatus[msg.sender] == 1, "can only commit to unstaking if currently staking");
        commitTimeStamp[msg.sender] = now;
        stakingStatus[msg.sender] = 2;

        totalStaked -= balanceOf(msg.sender);
        totalCommitted += balanceOf(msg.sender);
        emit CommittedWithdraw(msg.sender, balanceOf(msg.sender));
    }

    function unstake() updateAccount(msg.sender) external {
        require(stakingStatus[msg.sender] == 2, "can only unstake if currently committed to unstake");
        require(commitTimeStamp[msg.sender] + minimumCommitTime < now, "minimum commit time not met yet");
        stakingStatus[msg.sender] = 0;

        totalCommitted -= balanceOf(msg.sender);
        emit Unstaked(msg.sender, balanceOf(msg.sender));
    }

    function setTotalStaked(uint256 _amount) external onlyOwner {
        totalStaked = _amount;
    }

    function setTotalCommitted(uint256 _amount) external onlyOwner {
        totalCommitted = _amount;
    }

    function stake() updateAccount(msg.sender) external {
        require(stakingStatus[msg.sender] == 0, "can only stake if currently unstaked");
        stakingStatus[msg.sender] = 1;

        totalStaked += balanceOf(msg.sender);
        emit Staked(msg.sender, balanceOf(msg.sender));
    }

    /**
     * @dev Transfer tokens to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     * @return True on success, false otherwise.
     */
    function transfer(address to, uint256 value)
        public
        updateAccount(msg.sender)
        updateAccount(to)
        validRecipient(to)
        returns (bool)
    {
        require(!reEntrancyMintMutex, "RE-ENTRANCY GUARD MUST BE FALSE");
        require(stakingStatus[msg.sender] == 0, "cannot send SHARE while staking. Please unstake to send");

        _shareBalances[msg.sender].balance = _shareBalances[msg.sender].balance.sub(value);
        _shareBalances[to].balance = _shareBalances[to].balance.add(value);
        emit Transfer(msg.sender, to, value);

        _moveDelegates(_delegates2[msg.sender], _delegates2[to], value);

        // add to staking if true
        if (stakingStatus[to] == 1) totalStaked += value;
        else if (stakingStatus[to] == 2) totalCommitted += value;

        return true;
    }

    /**
     * @dev Function to check the amount of tokens that an owner has allowed to a spender.
     * @param owner_ The address which owns the funds.
     * @param spender The address which will spend the funds.
     * @return The number of tokens still available for the spender.
     */
    function allowance(address owner_, address spender)
        public
        view
        returns (uint256)
    {
        return _allowedShares[owner_][spender];
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param from The address you want to send tokens from.
     * @param to The address you want to transfer to.
     * @param value The amount of tokens to be transferred.
     */
    function transferFrom(address from, address to, uint256 value)
        public
        updateAccount(from)
        updateAccount(to)
        validRecipient(to)
        returns (bool)
    {
        require(!reEntrancyMintMutex, "RE-ENTRANCY GUARD MUST BE FALSE");
        require(stakingStatus[from] == 0, "cannot send SHARE while staking. Please unstake to send");

        _allowedShares[from][msg.sender] = _allowedShares[from][msg.sender].sub(value);

        _shareBalances[from].balance = _shareBalances[from].balance.sub(value);
        _shareBalances[to].balance = _shareBalances[to].balance.add(value);
        emit Transfer(from, to, value);

        _moveDelegates(_delegates2[from], _delegates2[to], value);

        if (stakingStatus[to] == 1) totalStaked += value;
        else if (stakingStatus[to] == 2) totalCommitted += value;

        return true;
    }

    /**
     * @dev Approve the passed address to spend the specified amount of tokens on behalf of
     * msg.sender. This method is included for ERC20 compatibility.
     * increaseAllowance and decreaseAllowance should be used instead.
     * Changing an allowance with this method brings the risk that someone may transfer both
     * the old and the new allowance - if they are both greater than zero - if a transfer
     * transaction is mined before the later approve() call is mined.
     *
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     */
    function approve(address spender, uint256 value)
        public
        validRecipient(spender)
        returns (bool)
    {
        _allowedShares[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    /**
     * @dev Increase the amount of tokens that an owner has allowed to a spender.
     * This method should be used instead of approve() to avoid the double approval vulnerability
     * described above.
     * @param spender The address which will spend the funds.
     * @param addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        returns (bool)
    {
        _allowedShares[msg.sender][spender] =
            _allowedShares[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedShares[msg.sender][spender]);
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to a spender.
     *
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public

        returns (bool)    {
        uint256 oldValue = _allowedShares[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedShares[msg.sender][spender] = 0;
        } else {
            _allowedShares[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedShares[msg.sender][spender]);
        return true;
    }

    modifier updateAccount(address account) {
        require(_initializedDollar == true, "DOLLAR_NEEDS_INITIALIZATION");

        Dollars.claimDividends(account);
        _;
    }

    // governance functions

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegator The address to get delegatee for
     */
    function delegates(address delegator)
        external
        view
        returns (address)
    {
        return _delegates2[delegator];
    }

   /**
    * @notice Delegate votes from `msg.sender` to `delegatee`
    * @param delegatee The address to delegate votes to
    */
    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @notice Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        address delegatee,
        uint nonce,
        uint expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                getChainId(),
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegatee,
                nonce,
                expiry
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );

        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "SeigniorageShares::delegateBySig: invalid signature");
        require(nonce == nonces2[signatory]++, "SeigniorageShares::delegateBySig: invalid nonce");
        require(now <= expiry, "SeigniorageShares::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account)
        external
        view
        returns (uint256)
    {
        uint32 nCheckpoints = numCheckpoints2[account];
        return nCheckpoints > 0 ? checkpoints2[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint blockNumber)
        external
        view
        returns (uint256)
    {
        require(blockNumber < block.number, "SeigniorageShares::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints2[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints2[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints2[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints2[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints2[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints2[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee)
        internal
    {
        address currentDelegate = _delegates2[delegator];
        uint256 delegatorBalance = balanceOf(delegator);
        _delegates2[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints2[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints2[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints2[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints2[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    )
        internal
    {
        uint32 blockNumber = safe32(block.number, "SeigniorageShares::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints2[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints2[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints2[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints2[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal pure returns (uint) {
        return 1;
    }
}
