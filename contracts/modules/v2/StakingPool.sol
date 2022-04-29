// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.9;

import "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
// TODO: consider using solmate ERC721 implementation
import "@openzeppelin/contracts-v4/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import "../../interfaces/IStakingPool.sol";

// total stake = active stake + expired stake
// product stake = active stake * product weight
// product stake = allocated product stake + free product stake
// on cover buys we allocate the free product stake and it becomes allocated.
// on expiration we deallocate the stake and it becomes free again

// ╭───────╼ Active stake ╾────────╮
// │                               │
// │     product weight            │
// │<────────────────────────>     │
// ├────╼ Product stake ╾────╮     │
// │                         │     │
// │ Allocated product stake │     │
// │   (used by covers)      │     │
// │                         │     │
// ├─────────────────────────┤     │
// │                         │     │
// │    Free product stake   │     │
// │                         │     │
// ╰─────────────────────────┴─────╯
//
// ╭───────╼ Expired stake ╾───────╮
// │                               │
// ╰───────────────────────────────╯

contract StakingPool is IStakingPool, ERC721 {
  using SafeCast for uint;

  /* storage */

  // currently active staked nxm amount
  uint public activeStake;

  // supply of pool stake shares used by groups
  uint public stakeSharesSupply;

  // supply of pool rewards shares used by groups
  uint public rewardsSharesSupply;

  // current nxm reward per second for the entire pool
  // applies to active stake only and does not need update on deposits
  uint public rewardPerSecond;

  // TODO: this should be allowed to overflow (similar to uniswapv2 twap)
  // accumulated rewarded nxm per reward share
  uint public accNxmPerRewardsShare;

  // timestamp when accNxmPerRewardsShare was last updated
  uint public lastAccNxmUpdate;

  uint public firstActiveGroupId;
  uint public lastActiveGroupId;

  uint public firstActiveBucketId;

  // erc721 supply
  uint public totalSupply;

  // group id => amount
  mapping(uint => StakeGroup) public stakeGroups;

  // pool bucket id => PoolBucket
  mapping(uint => PoolBucket) public poolBuckets;

  // product id => pool bucket id => ProductBucket
  mapping(uint => mapping(uint => ProductBucket)) public productBuckets;

  // product id => Product
  mapping(uint => Product) public products;

  // nft id => group id => position data
  mapping(uint => mapping(uint => PositionData)) public positionData;

  address public manager;

  /* immutables */

  IERC20 public immutable nxm;
  address public immutable coverContract;

  /* constants */

  // 7 * 13 = 91
  uint constant BUCKET_SIZE = 7 days;
  uint constant GROUP_SIZE = 91 days;
  uint constant MAX_GROUPS = 9; // 8 whole quarters + 1 partial quarter

  uint constant REWARDS_SHARES_RATIO = 125;
  uint constant REWARDS_SHARES_DENOMINATOR = 100;
  uint constant WEIGHT_DENOMINATOR = 100;
  uint constant REWARDS_DENOMINATOR = 100;

  // product params flags
  uint constant FLAG_PRODUCT_WEIGHT = 1;
  uint constant FLAG_PRODUCT_PRICE = 2;

  // withdraw flags
  uint constant FLAG_WITHDRAW_DEPOSIT = 1;
  uint constant FLAG_WITHDRAW_REWARDS = 2;

  modifier onlyCoverContract {
    require(msg.sender == coverContract, "StakingPool: Only Cover contract can call this function");
    _;
  }

  modifier onlyManager {
    require(msg.sender == manager, "StakingPool: Only pool manager can call this function");
    _;
  }

  constructor (
    string memory _name,
    string memory _symbol,
    IERC20 _token,
    address _coverContract
  ) ERC721(_name, _symbol) {
    nxm = _token;
    coverContract = _coverContract;
  }

  function initialize(
    address _manager,
    ProductInitializationParams[] calldata params
  ) external onlyCoverContract {
    manager = _manager;
    // TODO: initialize products
    params;
  }

  function operatorTransfer(
    address from,
    address to,
    uint[] calldata tokenIds
  ) external onlyCoverContract {
    uint length = tokenIds.length;
    for (uint i = 0; i < length; ++i) {
      _safeTransfer(from, to, tokenIds[i], "");
    }
  }

  function updateGroups() public {

    uint _firstActiveBucketId = firstActiveBucketId;
    uint currentBucketId = block.timestamp / BUCKET_SIZE;

    if (_firstActiveBucketId == currentBucketId) {
      return;
    }

    // SLOAD
    uint _activeStake = activeStake;
    uint _rewardPerSecond = rewardPerSecond;
    uint _stakeSharesSupply = stakeSharesSupply;
    uint _rewardsSharesSupply = rewardsSharesSupply;
    uint _accNxmPerRewardsShare = accNxmPerRewardsShare;
    uint _lastAccNxmUpdate = lastAccNxmUpdate;
    uint _firstActiveGroupId = firstActiveGroupId;

    // first group for the current timestamp
    uint targetGroupId = block.timestamp / GROUP_SIZE;

    while (_firstActiveBucketId < currentBucketId) {

      ++_firstActiveBucketId;
      uint bucketEndTime = _firstActiveBucketId * BUCKET_SIZE;
      uint elapsed = bucketEndTime - _lastAccNxmUpdate;

      // todo: should be allowed to overflow?
      _accNxmPerRewardsShare += elapsed * _rewardPerSecond / _rewardsSharesSupply;
      _lastAccNxmUpdate = bucketEndTime;
      _rewardPerSecond -= poolBuckets[_firstActiveBucketId].rewardPerSecondCut;

      // should we expire a group?
      if (
        bucketEndTime % GROUP_SIZE != 0 ||
        _firstActiveGroupId == targetGroupId
      ) {
        continue;
      }

      // SLOAD
      StakeGroup memory group = stakeGroups[_firstActiveGroupId];

      uint expiredStake = _activeStake * group.stakeShares / _stakeSharesSupply;
      _activeStake -= expiredStake;

      group.stakeAmountAtExpiry = expiredStake;
      group.accNxmPerRewardShareAtExpiry = _accNxmPerRewardsShare;
      group.stakeShareSupplyAtExpiry = _stakeSharesSupply;

      _stakeSharesSupply -= group.stakeShares;
      _rewardsSharesSupply -= group.rewardsShares;

      // SSTORE
      stakeGroups[_firstActiveGroupId] = group;

      // advance to the next group
      _firstActiveGroupId++;
    }

    firstActiveGroupId = _firstActiveGroupId;
    firstActiveBucketId = _firstActiveBucketId;

    activeStake = _activeStake;
    rewardPerSecond = _rewardPerSecond;
    accNxmPerRewardsShare = _accNxmPerRewardsShare;
    stakeSharesSupply = _stakeSharesSupply;
    rewardsSharesSupply = _rewardsSharesSupply;
    lastAccNxmUpdate = _lastAccNxmUpdate;
  }

  function deposit(
    uint amount,
    uint groupId,
    uint _positionId
  ) external returns (uint positionId) {

    updateGroups();

    // require groupId not to be expired
    require(groupId >= firstActiveGroupId, "StakingPool: Requested group has expired");
    require(amount > 0, "StakingPool: Insufficient deposit amount");

    // deposit to position id = 0 is not allowed
    // we treat it as a flag to create a new position
    if (_positionId == 0) {
      positionId = ++totalSupply;
      _mint(msg.sender, positionId);
    } else {
      positionId = _positionId;
    }

    // transfer nxm from staker
    // TODO: use TokenController.operatorTransfer instead and transfer to TC
    nxm.transferFrom(msg.sender, address(this), amount);

    // SLOAD
    uint _activeStake = activeStake;
    uint _stakeSharesSupply = stakeSharesSupply;
    uint _rewardsSharesSupply = rewardsSharesSupply;

    uint newStakeShares = _stakeSharesSupply == 0
      ? amount
      : _stakeSharesSupply * amount / _activeStake;

    uint newRewardsShares;
    {
      uint lockDuration = (groupId + 1) * GROUP_SIZE - block.timestamp;
      uint maxLockDuration = GROUP_SIZE * 8;

      // TODO: determine extra rewards formula
      newRewardsShares =
        newStakeShares
        * REWARDS_SHARES_RATIO
        * lockDuration
        / REWARDS_SHARES_DENOMINATOR
        / maxLockDuration;
    }

    /* update reward streaming */

    // SLOAD
    PositionData memory position = positionData[positionId][groupId];
    StakeGroup memory group = stakeGroups[groupId];

    uint _accNxmPerRewardsShare = accNxmPerRewardsShare;
    uint earnedPerShareSinceLastUpdate = 0;
    uint elapsed = position.lastAccNxmUpdate == 0
      ? block.timestamp - position.lastAccNxmUpdate
      : 0;

    if (elapsed > 0) {
      earnedPerShareSinceLastUpdate = elapsed * rewardPerSecond / _rewardsSharesSupply;
      _accNxmPerRewardsShare += earnedPerShareSinceLastUpdate;
    }

    /* update group and position */

    // MSTORE
    position.rewardEarned += earnedPerShareSinceLastUpdate * position.rewardsShares;
    position.lastAccNxmPerRewardShare = _accNxmPerRewardsShare;
    position.lastAccNxmUpdate = block.timestamp;
    position.stakeShares += newStakeShares;
    position.rewardsShares += newRewardsShares;

    group.stakeShares += newStakeShares;
    group.rewardsShares += newRewardsShares;

    // SSTORE
    positionData[positionId][groupId] = position;
    stakeGroups[groupId] = group;

    /* update globals */

    // SSTORE
    activeStake = _activeStake + amount;
    stakeSharesSupply = _stakeSharesSupply + newStakeShares;
    rewardsSharesSupply = _rewardsSharesSupply + newRewardsShares;

    if (elapsed > 0) {
      accNxmPerRewardsShare = _accNxmPerRewardsShare;
      lastAccNxmUpdate = block.timestamp;
    }
  }

/*
  struct WithdrawParams {
    uint positionId;
    uint groupId;
    uint flags;
  }
*/

  function withdraw(WithdrawParams[] calldata params) external {

    updateGroups();

    uint _firstActiveGroupId = block.timestamp / GROUP_SIZE;
    uint _accNxmPerRewardsShare = accNxmPerRewardsShare;
    uint withdrawable;

    for (uint i = 0; i < params.length; i++) {

      uint positionId = params[i].positionId;
      uint groupId = params[i].groupId;

      // check ownership or approval
      require(_isApprovedOrOwner(msg.sender, positionId), "StakingPool: Not owner or approved");

      if (params[i].flags & FLAG_WITHDRAW_DEPOSIT != 0) {

        // make sure the group is expired
        require(groupId < _firstActiveGroupId, "StakingPool: Group is still active");

        // calculate the amount of nxm for this position
        uint groupStake = stakeGroups[groupId].stakeAmountAtExpiry;
        uint groupShares = stakeGroups[groupId].stakeShareSupplyAtExpiry;
        uint positionShares = positionData[positionId][groupId].stakeShares;

        withdrawable += groupStake * positionShares / groupShares;

        // mark as withdrawn
        positionData[positionId][groupId].stakeShares = 0;
      }

      if (params[i].flags & FLAG_WITHDRAW_REWARDS != 0) {

        // TODO: additional accumulator?
        /*
        // if the group is expired, used stored accumulated rewards value
        uint accRewards = groupId < _firstActiveGroupId
          ? stakeGroups[groupId].accNxmPerRewardsShare
          : _accNxmPerRewardsShare;

        // expired case
        if (groupId < _firstActiveGroupId) {
          //
        }
        */

      }

    }

    // 1. check nft ownership / allowance
    // 2. loop through each group:
    // 2.1. check group expiration if the deposit flag is set
    // 2.2. calculate the reward amount if the reward flag is set
    // 3. sum up nxm amount of each group
    // 4. transfer nxm to staker
  }

  function allocateStake(
    uint productId,
    uint period,
    uint gracePeriod,
    uint productStakeAmount,
    uint rewardRatio
  ) external onlyCoverContract returns (uint newAllocation, uint premium) {

    updateGroups();

    Product memory product = products[productId];
    uint allocatedProductStake = product.allocatedStake;
    uint currentBucket = block.timestamp / BUCKET_SIZE;

    {
      uint lastBucket = product.lastBucket;

      // process expirations
      while (lastBucket < currentBucket) {
        ++lastBucket;
        allocatedProductStake -= productBuckets[productId][lastBucket].allocationCut;
      }
    }

    uint freeProductStake;
    {
      // group expiration must exceed the cover period
      uint _firstAvailableGroupId = (block.timestamp + period + gracePeriod) / GROUP_SIZE;
      uint _firstActiveGroupId = block.timestamp / GROUP_SIZE;

      // start with the entire supply and subtract unavailable groups
      uint _stakeSharesSupply = stakeSharesSupply;
      uint availableShares = _stakeSharesSupply;

      for (uint i = _firstActiveGroupId; i < _firstAvailableGroupId; ++i) {
        availableShares -= stakeGroups[i].stakeShares;
      }

      // total stake available without applying product weight
      freeProductStake =
        activeStake * availableShares * product.weight / _stakeSharesSupply / WEIGHT_DENOMINATOR;
    }

    // could happen if is 100% in-use or if the product weight was changed
    if (allocatedProductStake >= freeProductStake) {
      // store expirations
      products[productId].allocatedStake = allocatedProductStake;
      products[productId].lastBucket = currentBucket;
      return (0, 0);
    }

    {
      uint usableStake = freeProductStake - allocatedProductStake;
      newAllocation = min(productStakeAmount, usableStake);

      premium = calculatePremium(
        productId,
        allocatedProductStake,
        usableStake,
        newAllocation,
        period
      );
    }

    // 1 SSTORE
    products[productId].allocatedStake = allocatedProductStake + newAllocation;
    products[productId].lastBucket = currentBucket;

    {
      require(rewardRatio <= REWARDS_DENOMINATOR, "StakingPool: reward ratio exceeds denominator");

      // divCeil = fn(a, b) => (a + b - 1) / b
      uint expireAtBucket = (block.timestamp + period + BUCKET_SIZE - 1) / BUCKET_SIZE;
      uint _rewardPerSecond =
        premium * rewardRatio / REWARDS_DENOMINATOR
        / (expireAtBucket * BUCKET_SIZE - block.timestamp);

      // 2 SLOAD + 2 SSTORE
      productBuckets[productId][expireAtBucket].allocationCut += newAllocation;
      poolBuckets[expireAtBucket].rewardPerSecondCut += _rewardPerSecond;
    }
  }

  function calculatePremium(
    uint productId,
    uint allocatedStake,
    uint usableStake,
    uint newAllocation,
    uint period
  ) public returns (uint) {

    // silence compiler warnings
    allocatedStake;
    usableStake;
    newAllocation;
    period;
    block.timestamp;
    uint nextPrice = 0;
    products[productId].lastPrice = nextPrice;

    return 0;
  }

  function deallocateStake(
    uint productId,
    uint start,
    uint period,
    uint amount,
    uint premium
  ) external onlyCoverContract {

    // silence compiler warnings
    productId;
    start;
    period;
    amount;
    premium;
    activeStake = activeStake;
  }

  // O(1)
  function burnStake(uint productId, uint start, uint period, uint amount) external onlyCoverContract {

    productId;
    start;
    period;

    // TODO: free up the stake used by the corresponding cover
    // TODO: check if it's worth restricting the burn to 99% of the active stake

    updateGroups();

    uint _activeStake = activeStake;
    activeStake = _activeStake > amount ? _activeStake - amount : 0;
  }

  /* pool management */

  function setProductDetails(ProductParams[] memory params) external onlyManager {
    // silence compiler warnings
    params;
    activeStake = activeStake;
    // [todo] Implement
  }

  /* views */

  function getActiveStake() external view returns (uint) {
    block.timestamp; // prevents warning about function being pure
    return 0;
  }

  function getProductStake(
    uint productId, uint coverExpirationDate
  ) external view returns (uint) {
    productId;
    coverExpirationDate;
    block.timestamp;
    return 0;
  }

  function getAllocatedProductStake(uint productId) external view returns (uint) {
    productId;
    block.timestamp;
    return 0;
  }

  function getFreeProductStake(
    uint productId, uint coverExpirationDate
  ) external view returns (uint) {
    productId;
    coverExpirationDate;
    block.timestamp;
    return 0;
  }

  function addProducts(ProductParams[] memory params) external onlyManager {
    params;
  }

  function removeProducts(uint[] memory productIds) external onlyManager {
    productIds;
  }

  /* utils */

  function min(uint a, uint b) internal pure returns (uint) {
    return a < b ? a : b;
  }

  function max(uint a, uint b) internal pure returns (uint) {
    return a > b ? a : b;
  }

}
